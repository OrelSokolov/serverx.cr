# Server X

nginx-модель HTTP-сервера для Crystal: один буфер (64 KiB) на соединение,
offset-парсер HTTP/1.1 без per-request аллокаций в транспорте,
master/worker через `SO_REUSEPORT`, совместимый со стандартным
`HTTP::Handler` — то есть с любым Crystal-фреймворком (Kemal, Lucky, Grip,
rails.cr / action_pack, ...).

## Откуда это

Проект начинался как исследовательская попытка ответить на вопрос: **что
можно улучшить в стандартной библиотеке Crystal**, чтобы держать более
сильные цифры на бенчмарках. Триггером послужили слова DHH о том, что Rust
способен обслуживать его приложение HEY на Raspberry Pi — захотелось
выжать максимум из Crystal любыми доступными способами. Для этого брались
топовые решения индустрии: nginx-архитектура (процессы + SO_REUSEPORT,
буфер на соединение, state-machine-парсер по оффсетам), zero-copy и
zero-alloc подходы, переиспользование объектов вместо аллокаций.
Итоги исследования — в [RESULTS.md](RESULTS.md): +15–50% RPS на
транспорте, GC-churn ниже в 70–370 раз, паритет с nginx на динамических
ответах — и главный вывод: решает не экономия байтов в парсере, а
процессная модель (тот же Kemal на 8 fork-воркерах даёт ×4.8 RPS и
в 3–7 раз лучший p99, чем один процесс).

У zero-alloc есть и прикладной смысл — **защита от DDoS на уровне
сервера**: когда на запрос не создаётся мусор, сборщику нечего жать, и
под потоком атакующих запросов GC не уходит в бесконечный цикл
выделений/очисток — сервер продолжает отвечать на честный трафик.
Защиту дополняют лимиты транспорта: `max_conns` (503), `max_body` (413),
таймауты чтения/записи и отброс битых TLS-handshake.

Эксперимент доведён до продакшен-состояния: хендлеры, таймауты, лимиты,
chunked-тела, стриминг uploads, graceful shutdown, TLS, спеки.
Бенчмарки — в [RESULTS.md](RESULTS.md).

## Быстрый старт

```sh
crystal build --release -Dwithout_mt -o bin/serverx src/serverx_cli.cr

./bin/serverx --impl app --workers 8 --port 4500   # сервер с demo-приложением
curl localhost:4500/                                # -> Hello, World!
curl localhost:4500/json                            # -> {"hello":"world"}
```

Режимы `--impl`:

- `app` — **продакшен-режим**: транспорт + стандартный `HTTP::Handler`
  (по умолчанию небольшое demo-приложение);
- `pooled` — чистый транспортный бенчмарк: префиксированный ответ
  `Hello, World!`, ноль аллокаций на запрос (сравнимость с RESULTS.md);
- `stdlib` — базлайн: голый `HTTP::Server` stdlib с тем же payload.

## Подключение своего приложения

Сервер — это библиотека. Бинарник — только demo/бенчмарк.

Как шарда (`shard.yml`):

```yaml
dependencies:
  serverx:
    github: your-fork/serverX.cr
```

```crystal
require "serverx"

handler = MyApp::Router.new  # любой HTTP::Handler (Kemal.run, action_pack, ...)

ServerX.run(ServerX::Config.new.tap do |cfg|
  cfg.impl = "app"            # cfg.host / cfg.port / cfg.workers / cfg.max_body ...
end)
```

или напрямую, без CLI-конфига:

```crystal
server = ServerX::AppServer.new(handler, "0.0.0.0", 4500,
  read_timeout: 30.seconds,   # idle keep-alive + чтение запроса
  write_timeout: 30.seconds,
  max_body: 16_i64 * 1024 * 1024, # больше -> 413
  max_conns: 8192,            # лимит соединений на воркер, больше -> 503
  backlog: 1024)
server.listen                 # блокирует; SIGTERM/SIGINT -> graceful drain
```

Мастер-процессы (fork + `SO_REUSEPORT`, supervise + restart + graceful
shutdown) — `ServerX::Cluster.run` (требует сборки `-Dwithout_mt`).
`--workers N` в CLI делает ровно это.

### TLS

Автономный режим без фронта:

```sh
./bin/serverx --impl app --port 443 --tls-cert cert.pem --tls-key key.pem --workers 8
```

Клиенты с брошенным handshake отбрасываются (счётчик `tls_drops` в Stats).
Частая альтернатива — терминировать TLS на nginx/LB, serverx за фронтом.

## Что transport делает за хендлер

- keep-alive и пайплайнинг (регистронезависимые заголовки);
- `Content-Length` и `Transfer-Encoding: chunked` тела: до буфера — из
  буфера, больше — стримингом из сокета (uploads любого размера до
  `max_body`); пайплайн-байты после тела сохраняются;
- `Expect: 100-continue` — интерим-ответ до чтения тела;
- тело хендлера не дочитано — транспорт дренит его сам, соединение живо;
- жёсткие ответы: 400 (битая request line / Content-Length, CL+TE вместе —
  антисмугглинг RFC 9112 §6.1), 431 (заголовки > 64 KiB), 413 (тело >
  `max_body`), 501 (не-chunked `Transfer-Encoding`), 503 (лимит соединений),
  500 (исключение в хендлере + лог в STDERR);
- HEAD: заголовки без тела — строго по RFC (stdlib, для сравнения, тело
  пишет);
- upgrade (websockets): `response.upgrade` передаёт соединение блоку.

## Архитектура

- **Транспорт (`src/serverx/pooled.cr`)** — единственный буфер на соединение,
  offset-парсер (один проход по заголовкам), framing без аллокаций.
  Быстрый путь (`--impl pooled`) — префиксированный ответ, GC фактически не
  работает.
- **Compat-слой (`src/serverx/app_server.cr`)** — сборка `HTTP::Request` из
  оффсетов, переиспользуемый `HTTP::Server::Response` на keep-alive
  соединении (`Response#reset`, как в stdlib `RequestProcessor`), body-IO
  поверх буфера + стриминг + chunked-декодер на лету. Словарь HTTP
  (методы, частые имена заголовков) интернирован — литералы вместо
  аллокаций; заголовки заполняются в `request.headers` напрямую, без
  временного хеша и stdlib-dup; `BodyReader` пулится на соединении.
  ~640 Б мусора на запрос — пол stdlib API (см. RESULTS.md).
- **Мастер (`src/serverx/cluster.cr`)** — fork/SO_REUSEPORT, supervise
  (блокирующий `Process#wait` на воркера; рантайм Crystal сам жнёт детей по
  SIGCHLD, поллинг `waitpid` не работает), рестарт погибших, TERM → drain →
  KILL по таймауту.

## Запуск тестов и бенчей

```sh
crystal spec            # 24 интеграционных спека (транспорт, app, TLS, лимиты)
./bench.sh              # полный прогон (~12 мин, включает nginx в docker)
```

Зависимостей нет — только stdlib (socket, openssl, http). nginx-сравнение
нуждается в docker.

## Ограничения (осознанные)

- HTTP/1.1 only: нет HTTP/2 — для него в любом случае нужен фронт.
- Заголовки должны влезать в буфер 64 KiB (иначе 431 + close).
- `--workers > 1` требует сборки `-Dwithout_mt` (fork несовместим с
  MT-режимом Crystal 1.21); MT-режим — сборка без флага + `CRYSTAL_WORKERS`.
- `Expect` + chunked: 100-continue отправляется до тела любой длины.
- При переполнении `max_body` для chunked-тел ответ может уйти уже начатым —
  соединение закрывается.

## Лицензия

MIT. Проект родился как сценарий `410-serverx` бенчмарк-цикла `rails.cr`
(Crystal-реализация Rails).
