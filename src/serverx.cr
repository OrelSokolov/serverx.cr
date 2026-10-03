# Server X — nginx-style HTTP server for Crystal (library entry point).
#
# `--impl pooled|app|stdlib` wiring, the CLI and the master process model
# live in `src/serverx_cli.cr` (the binary entry). This file is the library:
# `require "serverx"` gives you `ServerX::AppServer` (pooled transport driven
# by a stock `HTTP::Handler`), `ServerX::PooledServer` (the zero-alloc fast
# transport), `ServerX::Cluster` (fork/SO_REUSEPORT master) and friends.
require "http/server"
require "openssl"
require "./serverx/*"

module ServerX
  VERSION = "0.2.1"

  # Runtime configuration shared by all server implementations.
  class Config
    property host = "127.0.0.1"
    property port = 4500
    property impl = "pooled"
    property workers = 1
    property stats_interval = 5
    property read_timeout : Time::Span? = 30.seconds
    property write_timeout : Time::Span? = 30.seconds
    property max_body : Int64 = 16_i64 * 1024 * 1024
    property max_conns = 8192
    property backlog = 1024
    property tls_cert : String? = nil
    property tls_key : String? = nil

    def tls_context : OpenSSL::SSL::Context::Server?
      return nil unless cert = @tls_cert
      key = @tls_key.not_nil! "--tls-cert requires --tls-key"
      context = OpenSSL::SSL::Context::Server.new
      context.certificate_chain = cert
      context.private_key = key
      context
    end
  end

  # Demo application for `--impl app`: exercises the compat layer with a
  # couple of routes (plain text + JSON) — used in benches and smoke tests.
  class DemoHandler
    include HTTP::Handler

    def call(context : HTTP::Server::Context) : Nil
      case context.request.path
      when "/"
        context.response.content_type = "text/plain"
        context.response.headers["Content-Length"] = "13"
        context.response.print "Hello, World!"
      when "/json"
        body = %({"hello":"world"})
        context.response.content_type = "application/json"
        context.response.headers["Content-Length"] = body.bytesize.to_s
        context.response.print body
      else
        context.response.respond_with_status(404)
      end
    end
  end

  def self.run(cfg : Config) : Nil
    if cfg.workers > 1
      {% if flag?(:without_mt) %}
        Cluster.run(cfg.host, cfg.port, cfg.workers, ->{ run_worker(cfg) })
      {% else %}
        abort "--workers > 1 requires the -Dwithout_mt build (fork is unsupported in multithreaded mode). For MT use --workers 1 and CRYSTAL_WORKERS."
      {% end %}
    else
      run_worker(cfg)
    end
  end

  def self.run_worker(cfg : Config) : Nil
    stats = Stats.new
    spawn Cluster.stats_printer(stats, cfg.stats_interval)
    case cfg.impl
    when "pooled"
      PooledServer.new(cfg.host, cfg.port, stats,
        read_timeout: cfg.read_timeout, write_timeout: cfg.write_timeout,
        max_body: cfg.max_body, max_conns: cfg.max_conns,
        backlog: cfg.backlog, tls: cfg.tls_context).listen
    when "app"
      AppServer.new(DemoHandler.new, cfg.host, cfg.port, stats,
        read_timeout: cfg.read_timeout, write_timeout: cfg.write_timeout,
        max_body: cfg.max_body, max_conns: cfg.max_conns,
        backlog: cfg.backlog, tls: cfg.tls_context).listen
    when "stdlib"
      StdlibServer.new(cfg.host, cfg.port, stats).listen
    else
      abort "unknown impl: #{cfg.impl} (pooled|app|stdlib)"
    end
  end
end
