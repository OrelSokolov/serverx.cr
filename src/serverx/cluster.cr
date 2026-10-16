require "signal"

module ServerX
  # Master process: forks N workers, each binding with SO_REUSEPORT (the
  # kernel load-balances), supervises and restarts dead children. On
  # SIGTERM/SIGINT it forwards the signal, waits for the workers to drain
  # their in-flight requests (up to `shutdown_timeout`), then kills
  # stragglers and exits 0 — the nginx master model.
  #
  # Liveness is tracked with one blocking `Process#wait` monitor fiber per
  # child. (The Crystal runtime reaps all children itself via SIGCHLD +
  # `waitpid(-1, WNOHANG)`, so polling `waitpid`/`#exists?` from the master
  # cannot see a dead child — zombies never surface.)
  #
  # Multithreaded builds (Crystal's default since 1.21) cannot fork at all —
  # `Process.fork` does not compile there. Shard flags do not propagate to
  # the app build, so the cluster cannot "require" -Dwithout_mt; instead it
  # degrades to a single in-process worker with a warning, and the app keeps
  # compiling and serving (build with -Dwithout_mt for the fork cluster).
  module Cluster
    def self.run(host : String, port : Int32, workers : Int32,
                 worker_block : Proc(Nil),
                 shutdown_timeout : Time::Span = 15.seconds) : Nil
      {% if flag?(:without_mt) %}
        supervisor = Supervisor.new(worker_block)
        supervisor.start(workers)

        shutdown = ->do
          supervisor.shutdown
          exit 0
        end
        Signal::INT.trap { shutdown.call }
        Signal::TERM.trap { shutdown.call }

        # The supervisor monitors do the work; park the master.
        loop do
          sleep 1.hour
        end
      {% else %}
        STDERR.puts "\e[1;33mServerX::Cluster — cluster mode is off:\e[0m \e[33mmultithreaded " \
                    "build cannot fork, running a single worker in-process. " \
                    "Compile with \e[1m-Dwithout_mt\e[0m\e[33m for the fork/SO_REUSEPORT cluster\e[0m"
        worker_block.call
      {% end %}
    end

    # Forks the workers, watches each with a blocking `Process#wait` monitor
    # fiber and restarts the dead ones until shutdown. (The Crystal runtime
    # reaps all children itself via SIGCHLD + `waitpid(-1, WNOHANG)`, so
    # polling `waitpid`/`#exists?` from the master cannot see a dead child —
    # zombies never surface.)
    private class Supervisor
      def initialize(@worker_block : Proc(Nil),
                     @shutdown_timeout : Time::Span = 15.seconds)
        @mutex = Mutex.new
        @children = Array(Process).new
        @shutting_down = false
      end

      def start(count : Int32) : Nil
        count.times { spawn_monitor(fork_worker) }
      end

      def shutdown : Nil
        @mutex.synchronize { @shutting_down = true }
        @mutex.synchronize { @children.dup }.each do |c|
          c.terminate rescue nil # SIGTERM: workers drain and exit
        end
        deadline = Time.monotonic + @shutdown_timeout
        until @mutex.synchronize { @children.all? { |c| c.terminated? rescue true } }
          break if Time.monotonic >= deadline
          sleep 100.milliseconds
        end
        @mutex.synchronize { @children.dup }.each do |c|
          c.terminate(graceful: false) rescue nil
        end
      end

      private def fork_worker : Process
        Process.fork { @worker_block.call }.not_nil!
      end

      private def spawn_monitor(child : Process) : Nil
        child = @mutex.synchronize { @children << child; child }
        spawn do
          begin
            child.wait
          rescue
            next
          end
          replacement = @mutex.synchronize do
            next nil if @shutting_down
            fork_worker
          end
          if replacement
            STDERR.puts "worker pid=#{child.pid} died, restarted"
            spawn_monitor(replacement)
          end
        end
      end
    end

    # Prints cumulative totals plus per-window deltas. `gc_win_kb` is the GC
    # churn metric: how much garbage the run allocated in the last window
    # while serving `reqs_win` requests.
    def self.stats_printer(stats : Stats, interval : Int32) : Nil
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
end
