require "socket"
require "openssl"

module ServerX
  # nginx-style transport: one buffer per connection, offset-based HTTP/1.1
  # parser, zero heap allocations per request on the fast path (`handler == nil`,
  # the benchmark payload). With a handler attached (see `AppServer`) the same
  # transport drives a stock `HTTP::Handler` — framing (keep-alive,
  # Content-Length, chunked bodies, pipelining) is decided here, below the
  # handler API.
  #
  # Hardening: read/write timeouts, per-worker connection limit (503), header
  # limit 431, malformed request line / Content-Length 400, unsupported
  # Transfer-Encoding 501, request body cap 413, Expect: 100-continue,
  # graceful shutdown on SIGTERM/SIGINT (stop accepting, drain in-flight).
  class PooledServer
    BUF_SIZE = 64 * 1024

    # Precomputed error responses; always close the connection.
    protected getter keep_resp : Bytes
    protected getter close_resp : Bytes
    protected getter resp_431 : Bytes
    protected getter resp_503 : Bytes
    protected getter resp_100_continue : Bytes

    @listener : TCPServer?
    @active = Atomic(Int32).new(0)
    @stopping = false
    @install_signals : Bool

    def initialize(@host : String, @port : Int32, @stats : Stats = Stats.new,
                   @read_timeout : Time::Span? = 30.seconds,
                   @write_timeout : Time::Span? = 30.seconds,
                   @max_body : Int64 = 16_i64 * 1024 * 1024,
                   @max_conns : Int32 = 8192,
                   @backlog : Int32 = 1024,
                   @tls : OpenSSL::SSL::Context::Server? = nil,
                   @drain_timeout : Time::Span = 10.seconds,
                   install_signals : Bool = true)
      @install_signals = install_signals
      @keep_resp = build_response("keep-alive")
      @close_resp = build_response("close")
      @resp_431 = build_error(431, "Request Header Fields Too Large")
      @resp_503 = build_error(503, "Service Unavailable")
      @resp_100_continue = "HTTP/1.1 100 Continue\r\n\r\n".to_slice
    end

    def listen : Nil
      server = TCPServer.new(@host, @port, @backlog, reuse_port: true)
      @listener = server
      install_signal_handlers

      loop do
        io = begin
          accept_io(server)
        rescue IO::Error
          nil # listener closed (graceful shutdown)
        end
        break if io.nil? || @stopping

        if @max_conns > 0 && @active.get >= @max_conns
          begin
            io.write(@resp_503)
            io.flush
          rescue IO::Error
          end
          io.close rescue nil
          next
        end

        @active.add(1)
        spawn handle_safe(io)
      end

      drain_connections
    end

    # Graceful shutdown: stop accepting, let in-flight requests finish.
    def stop : Nil
      @stopping = true
      @listener.try { |l| l.close rescue nil }
    end

    def drain_connections : Nil
      deadline = Time.monotonic + @drain_timeout
      while @active.get > 0 && Time.monotonic < deadline
        sleep 50.milliseconds
      end
    end

    private def install_signal_handlers : Nil
      return unless @install_signals
      Signal::TERM.trap { stop }
      Signal::INT.trap { stop }
    end

    # Accepts and applies socket options; TLS-wraps when a context is set.
    # Returns nil on listener close, raises IO::Error otherwise. Connections
    # whose TLS handshake fails are dropped and accepting continues.
    protected def accept_io(server : TCPServer) : IO?
      loop do
        tcp = server.accept?
        return nil unless tcp
        begin
          tcp.tcp_nodelay = true
          tcp.read_timeout = @read_timeout if @read_timeout
          tcp.write_timeout = @write_timeout if @write_timeout
        rescue Socket::Error
        end
        if ctx = @tls
          begin
            return OpenSSL::SSL::Socket::Server.new(tcp, ctx, sync_close: true)
          rescue ex : OpenSSL::SSL::Error | IO::Error
            @stats.tls_drops.add(1)
            tcp.close rescue nil
          end
        else
          return tcp
        end
      end
    end

    private def handle_safe(io : IO) : Nil
      handle(io)
    ensure
      @active.sub(1)
      io.close rescue nil
    end

    protected def build_response(connection : String) : Bytes
      body = "Hello, World!"
      String.build do |io|
        io << "HTTP/1.1 200 OK\r\n"
        io << "Content-Type: text/plain\r\n"
        io << "Content-Length: #{body.bytesize}\r\n"
        io << "Connection: #{connection}\r\n"
        io << "\r\n"
        io << body
      end.to_slice
    end

    protected def build_error(status : Int32, reason : String) : Bytes
      body = "#{status} #{reason}\n"
      String.build do |io|
        io << "HTTP/1.1 #{status} #{reason}\r\n"
        io << "Content-Type: text/plain\r\n"
        io << "Content-Length: #{body.bytesize}\r\n"
        io << "Connection: close\r\n"
        io << "\r\n"
        io << body
      end.to_slice
    end

    protected def write_error(io : IO, status : Int32, reason : String) : Nil
      io.write(build_error(status, reason))
      io.flush
    end

    # ------------------------------------------------------------------
    # Fast path: precomputed response, no handler. The benchmark transport.
    # ------------------------------------------------------------------

    protected def handle(io : IO) : Nil
      buf = Slice(UInt8).new(BUF_SIZE)
      filled = 0

      loop do
        # 1. Ensure the complete header section is buffered.
        head = header_end(buf, filled)
        while head == -1
          if filled == buf.size
            io.write(@resp_431)
            io.flush
            return
          end
          n = read_once(io, buf, filled)
          return if n == -1
          filled += n
          head = header_end(buf, filled)
        end

        # 2. Validate the request line and scan the headers in one walk.
        return write_400(io) unless request_line_ok?(buf, head)
        h = scan_headers(buf, head)
        return write_400(io) if h.content_length == -1
        return write_501(io) unless h.te == TE::None # fast path: no body decoder

        http11 = h.http11
        keep =
          case h.connection
          when Conn::Close     then false
          when Conn::KeepAlive then true
          else                      http11
          end

        # 3. Expect: 100-continue — let the client send its body.
        if h.expect_continue && h.content_length > 0
          io.write(@resp_100_continue)
        end

        # 4. Consume the request body.
        content_length = h.content_length
        return write_413(io) if content_length > @max_body
        req_end = head + 4 + content_length
        if req_end <= buf.size
          while filled < req_end
            n = read_once(io, buf, filled)
            return if n == -1
            filled += n
          end
        else
          # Body larger than the buffer: stream-discard the rest. Any bytes
          # pipelined after such a body are discarded with it (documented
          # fast-path limitation), so there is no leftover: reset both.
          remaining = req_end - filled
          while remaining > 0
            n = read_once(io, buf, 0, Math.min(remaining, buf.size).to_i32)
            return if n == -1
            remaining -= n
          end
          filled = 0
          req_end = 0
        end

        # 5. Respond with the precomputed bytes.
        io.write(keep ? @keep_resp : @close_resp)
        io.flush
        @stats.requests.add(1)

        # 6. Keep any pipelined leftover and loop.
        leftover = filled - req_end
        move_left(buf, req_end, leftover) if leftover > 0
        filled = leftover

        return unless keep
      end
    rescue IO::Error | OpenSSL::SSL::Error
      # client hung up / reset / timed out — nothing to clean up
    end

    private def write_400(io : IO) : Nil
      write_error(io, 400, "Bad Request")
    end

    private def write_501(io : IO) : Nil
      write_error(io, 501, "Not Implemented")
    end

    private def write_413(io : IO) : Nil
      write_error(io, 413, "Payload Too Large")
    end

    # Reads once into buf[from...]; returns bytes read or -1 on EOF.
    protected def read_once(io : IO, buf : Slice(UInt8), from : Int32, limit : Int32 = -1) : Int32
      n = io.read(buf[from, limit < 0 ? buf.size - from : {limit, buf.size - from}.min])
      n <= 0 ? -1 : n
    end

    # ------------------------------------------------------------------
    # Offset parser (shared with AppServer)
    # ------------------------------------------------------------------

    def header_end(buf : Slice(UInt8), filled : Int32) : Int32
      limit = filled - 4
      i = 0
      while i <= limit
        if buf.unsafe_fetch(i) == 13 && buf.unsafe_fetch(i + 1) == 10 &&
           buf.unsafe_fetch(i + 2) == 13 && buf.unsafe_fetch(i + 3) == 10
          return i
        end
        i += 1
      end
      -1
    end

    # Request line is `METHOD SP PATH SP HTTP/1.x CRLF`.
    def request_line_ok?(buf : Slice(UInt8), head : Int32) : Bool
      i = 0
      spaces = 0
      while i < head
        if buf.unsafe_fetch(i) == 32 # ' '
          spaces += 1
          break if spaces == 2
        end
        i += 1
      end
      return false unless spaces == 2
      # METHOD: at least 1 char before the first space.
      return false if i == 0 || buf.unsafe_fetch(0) == 32
      v = i + 1
      return false unless head - v >= 8
      ptr = "HTTP/1.".to_unsafe
      j = 0
      while j < 7
        return false if buf.unsafe_fetch(v + j) != ptr[j]
        j += 1
      end
      d = buf.unsafe_fetch(v + 7)
      d == 48 || d == 49 # '0' | '1'
    end

    enum Conn
      Default
      KeepAlive
      Close
    end

    enum TE
      None
      Chunked
      Other
    end

    # Result of the single header walk: connection, content-length (-1 when
    # malformed), transfer-encoding, expect: 100-continue, request version.
    struct HeaderScan
      property connection : Conn = Conn::Default
      property content_length : Int64 = 0_i64
      property has_cl : Bool = false
      property te : TE = TE::None
      property expect_continue : Bool = false
      property http11 : Bool = true
    end

    # One walk over the header block collecting everything the transport
    # needs. `head` is the offset of the terminating "\r\n\r\n".
    def scan_headers(buf : Slice(UInt8), head : Int32) : HeaderScan
      h = HeaderScan.new

      # Request line version.
      i = 0
      spaces = 0
      while i < head
        if buf.unsafe_fetch(i) == 32 # ' '
          spaces += 1
          break if spaces == 2
        end
        i += 1
      end
      if spaces == 2 && head - i >= 9
        h.http11 = buf.unsafe_fetch(i + 8) == 49 # '1'
      end

      # Skip the request line.
      line_start = 0
      while line_start < head && buf.unsafe_fetch(line_start) != 10 # '\n'
        line_start += 1
      end
      line_start += 1

      while line_start < head
        line_end = line_start
        while line_end < head && buf.unsafe_fetch(line_end) != 10 # '\n'
          line_end += 1
        end

        colon = line_start
        while colon < line_end && buf.unsafe_fetch(colon) != 58 # ':'
          colon += 1
        end

        if colon < line_end
          v = colon + 1
          while v < line_end && buf.unsafe_fetch(v) == 32 # ' '
            v += 1
          end
          vend = line_end
          vend -= 1 if vend > v && buf.unsafe_fetch(vend - 1) == 13 # '\r'
          len = vend - v

          case
          when eq_ignore_case?(buf, line_start, colon - line_start, "connection")
            h.connection = Conn::Close if len > 0 && eq_ignore_case?(buf, v, len, "close")
            h.connection = Conn::KeepAlive if len > 0 && eq_ignore_case?(buf, v, len, "keep-alive")
          when eq_ignore_case?(buf, line_start, colon - line_start, "content-length")
            value = 0_i64
            h.has_cl = true
            if len == 0
              h.content_length = -1_i64
            else
              k = v
              while k < vend
                d = buf.unsafe_fetch(k)
                if d < 48 || d > 57
                  h.content_length = -1_i64
                  break
                end
                value = value * 10 + (d - 48)
                k += 1
              end
              h.content_length = value if h.content_length != -1
            end
          when eq_ignore_case?(buf, line_start, colon - line_start, "transfer-encoding")
            h.te = TE::Other
            if len > 0 && eq_ignore_case?(buf, v, len, "chunked")
              h.te = TE::Chunked
            end
          when eq_ignore_case?(buf, line_start, colon - line_start, "expect")
            h.expect_continue = len > 0 && eq_ignore_case?(buf, v, len, "100-continue")
          end
        end
        line_start = line_end + 1
      end
      h
    end

    def eq_ignore_case?(buf : Slice(UInt8), from : Int32, len : Int32, s : String) : Bool
      return false unless s.bytesize == len
      ptr = s.to_unsafe
      i = 0
      while i < len
        a = buf.unsafe_fetch(from + i)
        b = ptr[i]
        a += 32 if a >= 65 && a <= 90 # 'A'..'Z'
        b += 32 if b >= 65 && b <= 90
        return false if a != b
        i += 1
      end
      true
    end

    def move_left(buf : Slice(UInt8), from : Int32, len : Int32) : Nil
      i = 0
      while i < len
        buf[i] = buf.unsafe_fetch(from + i)
        i += 1
      end
    end
  end
end
