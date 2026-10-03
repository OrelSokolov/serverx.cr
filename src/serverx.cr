# Server X — experimental nginx-style HTTP server for Crystal.
#
#   ./bin/serverx --impl pooled|stdlib --workers N --port P
#
# `pooled`  — custom accept loop, fiber per connection (same as stdlib), but a
#             single reusable buffer per connection and an offset-based HTTP
#             parser: zero heap allocations per request in steady state.
# `stdlib`  — the stock HTTP::Server baseline with the same payload.
#
# `--workers N` forks N processes, each binding with SO_REUSEPORT (the kernel
# load-balances), master supervises and restarts dead children.
require "option_parser"
require "http/server"
require "./serverx/*"

module ServerX
  VERSION = "0.1.0"

  def self.run(host : String, port : Int32, impl : String, workers : Int32, stats_interval : Int32) : Nil
    if workers > 1
      {% if flag?(:without_mt) %}
        run_master(host, port, impl, workers, stats_interval)
      {% else %}
        abort "--workers > 1 requires the -Dwithout_mt build (fork is unsupported in multithreaded mode). For MT use --workers 1 and CRYSTAL_WORKERS."
      {% end %}
    else
      run_worker(host, port, impl, stats_interval)
    end
  end

  private def self.run_master(host, port, impl, workers, stats_interval) : Nil
    children = Array(Process).new(workers)
    workers.times do
      child = Process.fork { run_worker(host, port, impl, stats_interval) }
      children << child.not_nil!
    end

    shutdown = ->do
      children.each do |c|
        c.terminate rescue nil
      end
      exit 0
    end
    Signal::INT.trap { shutdown.call }
    Signal::TERM.trap { shutdown.call }

    # Supervise: restart dead workers.
    loop do
      sleep 1.second
      children.each_with_index do |c, i|
        unless c.exists?
          children[i] = Process.fork { run_worker(host, port, impl, stats_interval) }.not_nil!
          STDERR.puts "worker restarted"
        end
      end
    end
  end

  private def self.run_worker(host, port, impl, stats_interval) : Nil
    stats = Stats.new
    spawn stats_printer(stats, stats_interval)
    case impl
    when "pooled" then PooledServer.new(host, port, stats).listen
    when "stdlib" then StdlibServer.new(host, port, stats).listen
    else               abort "unknown impl: #{impl} (pooled|stdlib)"
    end
  end

  # Prints cumulative totals plus per-window deltas. `gc_win_kb` is the GC
  # churn metric: how much garbage the run allocated in the last window while
  # serving `reqs_win` requests. Under load this shows the allocator running
  # hot; for the pooled server it stays near the cost of this very line.
  private def self.stats_printer(stats : Stats, interval : Int32) : Nil
    prev_reqs = 0_i64
    prev_gc = 0_u64
    loop do
      sleep interval.seconds
      reqs = stats.requests.get
      gc = GC.stats.total_bytes
      puts "# stats t=#{Time.utc.to_unix_ms} pid=#{Process.pid} reqs=#{reqs} reqs_win=#{reqs - prev_reqs} gc_kb=#{gc // 1024} gc_win_kb=#{(gc - prev_gc) // 1024} rss_kb=#{rss_kb}"
      STDOUT.flush
      prev_reqs = reqs
      prev_gc = gc
    end
  end

  private def self.rss_kb : Int64
    File.read("/proc/self/status").each_line do |line|
      return line.split[1].to_i64 if line.starts_with?("VmRSS:")
    end
    0_i64
  rescue
    0_i64
  end
end

host = "127.0.0.1"
port = 4500
impl = "pooled"
workers = 1
stats_interval = 5

OptionParser.parse do |op|
  op.on("--host H", "bind host (default 127.0.0.1)") { |v| host = v }
  op.on("--port P", "bind port (default 4500)") { |v| port = v.to_i }
  op.on("--impl IMPL", "pooled | stdlib (default pooled)") { |v| impl = v }
  op.on("--workers N", "process count, SO_REUSEPORT (default 1)") { |v| workers = v.to_i }
  op.on("--stats-interval S", "seconds between # stats lines (default 5)") { |v| stats_interval = v.to_i }
  op.on("-h", "--help", "Show this help") do
    puts op
    exit
  end
end

ServerX.run(host, port, impl, workers, stats_interval)
