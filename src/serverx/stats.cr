module ServerX
  # Shared counters for the periodic stats line. The stats printer itself
  # allocates a little (a string every interval); that cost shows up in the
  # reported gc_kb and is negligible next to any real request traffic.
  class Stats
    getter requests : Atomic(Int64)
    getter tls_drops : Atomic(Int64)

    def initialize
      @requests = Atomic(Int64).new(0)
      @tls_drops = Atomic(Int64).new(0)
    end
  end
end
