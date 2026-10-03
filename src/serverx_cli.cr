# Server X — CLI / binary entry.
#
#   ./bin/serverx --impl pooled|app|stdlib --workers N --port P
#
# The library itself lives in `src/serverx.cr` + `src/serverx/`; this file
# only parses arguments and hands over to `ServerX.run`.
require "option_parser"
require "./serverx"

cfg = ServerX::Config.new

OptionParser.parse do |op|
  op.on("--host H", "bind host (default 127.0.0.1)") { |v| cfg.host = v }
  op.on("--port P", "bind port (default 4500)") { |v| cfg.port = v.to_i }
  op.on("--impl IMPL", "pooled | app | stdlib (default pooled)") { |v| cfg.impl = v }
  op.on("--workers N", "process count, SO_REUSEPORT (default 1)") { |v| cfg.workers = v.to_i }
  op.on("--stats-interval S", "seconds between # stats lines (default 5)") { |v| cfg.stats_interval = v.to_i }
  op.on("--timeout-read S", "per-read timeout in seconds, 0 to disable (default 30)") do |v|
    cfg.read_timeout = v.to_f == 0 ? nil : v.to_f.seconds
  end
  op.on("--timeout-write S", "per-write timeout in seconds, 0 to disable (default 30)") do |v|
    cfg.write_timeout = v.to_f == 0 ? nil : v.to_f.seconds
  end
  op.on("--max-body BYTES", "max request body in bytes (default 16 MiB)") { |v| cfg.max_body = v.to_i64 }
  op.on("--max-conns N", "max concurrent connections per worker (default 8192)") { |v| cfg.max_conns = v.to_i }
  op.on("--backlog N", "listen backlog (default 1024)") { |v| cfg.backlog = v.to_i }
  op.on("--tls-cert FILE", "PEM certificate chain; enables TLS") { |v| cfg.tls_cert = v }
  op.on("--tls-key FILE", "PEM private key") { |v| cfg.tls_key = v }
  op.on("-h", "--help", "Show this help") do
    puts op
    exit
  end
end

ServerX.run(cfg)
