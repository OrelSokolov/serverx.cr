# serverx — 410-serverx: пуловый zero-alloc сервер ✅ (2026-10-03)

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

**Статус: сделано.** Server X — экспериментальный HTTP-сервер по nginx-модели:
один буфер на соединение, offset-парсер без per-request аллокаций,
master/worker через `SO_REUSEPORT`. Сравнение со stdlib `HTTP::Server` —
в `RESULTS.md` и `~/rails.cr/bench/results/410-serverx.md` (ST/MT/nginx, churn-метрика).

Итог: +15–50% RPS, аллокации 691 → 2–9 байт/запрос, GC фактически не работает.

## Состав

```
src/serverx.cr          CLI + master (fork, supervise, restart) + stats printer
src/serverx/pooled.cr   пуловый сервер: буфер 64 KiB на соединение, парсер
                        по оффсетам, keep-alive, пайплайнинг, Connection/
                        Content-Length (case-insensitive), 431 на переполнение
src/serverx/stdlib.cr   базлайн: голый HTTP::Server с тем же payload
src/serverx/stats.cr    счётчики (Atomic) для строки "# stats"
bench.sh                матрица замеров (impl × workers × conns), медиана 3
bin/serverx             бинарник (сборка: crystal build --release -Dwithout_mt)
```

## Запуск

```sh
./bin/serverx --impl pooled --workers 8 --port 4500   # сервер
./bench.sh                                            # полный прогон
```

## Дальше (если продолжать)

- вариант поверх `HTTP::Server` stdlib: подмена RequestProcessor на пуловый —
  чтобы сохранился API хендлеров (совместимость с action_pack)
- sendfile (LibC) для статики
- таймауты на чтение/письмо соединения
- ограничение числа соединений на воркер (как worker_connections в nginx)
- сравнение с nginx (нет в системе на 2026-10-03)
