# serverx — 410-serverx: пуловый zero-alloc сервер → продакшен-сервер ✅ (2026-10-03)

**Статус: v0.2.1 — продакшен-фаза.** Server X — HTTP-сервер по nginx-модели:
один буфер на соединение, offset-парсер без per-request аллокаций в транспорте,
master/worker через `SO_REUSEPORT`. Эксперимент (`410-serverx`) доведён до
состояния «можно ставить в прод»: стандартный `HTTP::Handler` API, таймауты,
лимиты, chunked/стриминг тел, graceful shutdown, TLS, 25 спеков + soak
(768k запросов байт-в-байт). app-путь оптимизирован до пола stdlib API
(~640 Б/req): интернированный словарь, заполнение headers без dup, пул
BodyReader. Сравнение со stdlib `HTTP::Server` и nginx — в `RESULTS.md`.

Итог эксперимента: +15–50% RPS, аллокации 691 → 2–9 байт/запрос, GC фактически
не работает; итог продакшен-фазы — те же цифры на transport-пути (контроль
регрессии), плюс app-режим через `HTTP::Handler` (см. RESULTS). Прикладной
смысл zero-alloc — устойчивость к DDoS: без мусора на запрос GC не уходит
в бесконечные выделения/удаления под потоком атак (лимиты `max_conns`/
`max_body`/таймауты — в транспорте).

## Состав

```
src/serverx.cr           библиотека: Config, DemoHandler, ServerX.run (воркеры)
src/serverx_cli.cr       бинарник: CLI (option_parser) + запуск
src/serverx/pooled.cr    транспорт: буфер 64 KiB на соединение, offset-парсер
                         (один проход по заголовкам), 431/400/413/501/503,
                         100-continue, таймауты, лимит соединений, graceful
src/serverx/app_server.cr compat-слой: HTTP::Handler, переиспользуемый
                         Response#reset, BodyReader (буфер + стриминг +
                         chunked-декодер), HEAD-фильтр, upgrade
src/serverx/cluster.cr   master: fork + supervise (Process#wait-мониторы),
                         рестарт воркеров, TERM → drain → KILL
src/serverx/stdlib.cr    базлайн: голый HTTP::Server с тем же payload
src/serverx/stats.cr     счётчики (Atomic) для строки "# stats"
spec/                    24 интеграционных спека
bench.sh                 матрица замеров (impl × workers × conns), медиана 3
bin/serverx              ST-бинарник (сборка: crystal build -Dwithout_mt
                         src/serverx_cli.cr); bin/serverx-mt — MT-сборка
```

## Запуск

```sh
crystal build --release -Dwithout_mt -o bin/serverx src/serverx_cli.cr
./bin/serverx --impl app --workers 8 --port 4500   # продакшен-режим (demo-приложение)
crystal spec                                        # тесты
./bench.sh                                          # полный бенчмарк
```

## Сделано в продакшен-фазе (v0.2.0)

- compat-слой поверх `HTTP::Handler` (совместимость с action_pack/Kemal/...);
- тела: Content-Length + chunked (декодер на лету), стриминг >64 KiB,
  `max_body` → 413, drain непрочитанного тела с сохранением пайплайнинга;
- `Expect: 100-continue`; 400 на битую request line/CL и на CL+TE (smuggling);
- таймауты чтения/записи, лимит соединений на воркер (503), backlog, TCP_NODELAY;
- graceful shutdown: воркеры дренят, мастер TERM → wait → KILL; supervise
  воркеров починен (рантайм Crystal жнёт детей по SIGCHLD — поллинг waitpid
  не работает, нужны wait-мониторы);
- TLS (`--tls-cert/--tls-key`, OpenSSL из stdlib), отброс битых handshake;
- HEAD без тела (RFC 9110; stdlib, для сравнения, тело пишет);
- 24 интеграционных спека, финальная батарея edge-кейсов (17/17).

## Дальше (если продолжать)

Приоритетные:

- **мульти-доменность**: vhost по `Host` + SNI (`Context#on_server_name`
  — проверено, в stdlib есть), cert на домен; порт 80 — редирект на https
  + `/.well-known/acme-challenge/` из каталога → certbot renew без
  рестарта;
- **статика из памяти**: preload каталогов в RAM (yml: домен/каталог →
  файлы в `Bytes`), отдача без `open/read` — предсобранный заголовочный
  блок + одно `write`; ETag/`If-None-Match` → 304; перезагрузка по
  `SIGHUP`; лимит размера файла/кэша (большее — с диска);
- **rate-limit по IP** (L7-лимит запросов; лимит соединений уже есть);
- **rails.cr-биндинги**: `ServerX.run` поднимается из конфига приложения
  одной строкой (воркеры/таймауты/лимиты из config.application.rb),
  ServerX бандлится в rails.cr как дефолтный app-сервер — роль Puma для
  Rails;
- **restart-throttle в Supervisor**: счётчик рестартов + backoff, чтобы
  crash-looping воркер не форкался бесконечно (alert в STDERR при
  превышении);
- watchdog на зависшие (не упавшие) воркеры: heartbeat из `# stats` или
  `sd_notify`/`WatchdogSec` systemd.

Второстепенные:

- sendfile (LibC) для статики;
- lazy-аллокация 64 KiB-буфера соединения (для MT-режима и мелких VPS);
- access log в формате nginx/combined;
- HTTP/2 — осознанно нет, для него фронт;
- замер на статике и проксировании против nginx.
