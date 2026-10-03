module ServerX
  # Experimental nginx-style server: one buffer per connection, zero heap
  # allocations per request. HTTP/1.1 keep-alive and pipelining, case-insensitive
  # `Connection` and `Content-Length` handling — everything parsed by offsets
  # into the connection buffer, no per-request strings or objects.
  #
  # Known limitations (fine for the benchmark, documented on purpose):
  #   * headers must fit in BUF_SIZE (64 KiB), otherwise 431 + close;
  #   * `Transfer-Encoding: chunked` request bodies are not supported
  #     (responds as if the body were empty);
  #   * a request whose body exceeds BUF_SIZE drains the body through the
  #     buffer, so pipelined bytes after such a body are discarded.
  class PooledServer
    BUF_SIZE = 64 * 1024

    RESP_431 = "HTTP/1.1 431 Request Header Fields Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_slice

    @keep_resp : Bytes
    @close_resp : Bytes

    def initialize(@host : String, @port : Int32, @stats : Stats)
      @keep_resp = build_response("keep-alive")
      @close_resp = build_response("close")
    end

    def listen : Nil
      server = TCPServer.new(@host, @port, reuse_port: true)
      loop do
        io = server.accept?
        break unless io
        spawn handle(io)
      end
    end

    private def build_response(connection : String) : Bytes
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

    # Per connection: one buffer + a few integers, then pure offsets until the
    # connection dies. The fiber per connection is the same cost the stdlib
    # server pays; everything below it is allocation-free.
    private def handle(io : TCPSocket) : Nil
      buf = Slice(UInt8).new(BUF_SIZE)
      filled = 0

      loop do
        # 1. Ensure the complete header section is buffered.
        head = header_end(buf, filled)
        while head == -1
          if filled == buf.size
            io.write(RESP_431)
            io.flush
            return
          end
          n = io.read(buf + filled)
          return if n == 0
          filled += n
          head = header_end(buf, filled)
        end

        # 2. Parse what we need straight from the buffer.
        http11 = request_is_http11?(buf, head)
        connection = parse_connection(buf, head)
        content_length = parse_content_length(buf, head)

        keep =
          case connection
          when Conn::Close     then false
          when Conn::KeepAlive then true
          else                      http11
          end

        # 3. Ensure/consume the request body.
        req_end = head + 4 + content_length
        if req_end <= buf.size
          while filled < req_end
            n = io.read(buf + filled)
            return if n == 0
            filled += n
          end
        else
          # Body larger than the buffer: stream-discard the rest.
          remaining = req_end - filled
          while remaining > 0
            n = io.read(buf[0, Math.min(remaining, buf.size)])
            return if n == 0
            remaining -= n
          end
          filled = 0
        end

        # 4. Respond with the precomputed bytes.
        io.write(keep ? @keep_resp : @close_resp)
        io.flush
        @stats.requests.add(1)

        # 5. Keep any pipelined leftover and loop.
        leftover = filled - req_end
        move_left(buf, req_end, leftover) if leftover > 0
        filled = leftover

        return unless keep
      end
    rescue IO::Error
      # client hung up / reset — nothing to clean up beyond the socket
    ensure
      io.close rescue nil
    end

    # Index of the '\r' of the terminating "\r\n\r\n", or -1.
    private def header_end(buf : Slice(UInt8), filled : Int32) : Int32
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

    # Request line is `METHOD SP PATH SP HTTP/x.y CRLF`; version after 2nd space.
    private def request_is_http11?(buf : Slice(UInt8), head : Int32) : Bool
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
      v = i + 1
      return false unless head - v >= 8
      ptr = "HTTP/1.1".to_unsafe
      j = 0
      while j < 8
        return false if buf.unsafe_fetch(v + j) != ptr[j]
        j += 1
      end
      true
    end

    private enum Conn
      Default
      KeepAlive
      Close
    end

    # Walks header lines, matches `connection` (case-insensitive), classifies
    # its value. `head` is the offset of the terminating "\r\n\r\n".
    private def parse_connection(buf : Slice(UInt8), head : Int32) : Conn
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

        if colon < line_end &&
           eq_ignore_case?(buf, line_start, colon - line_start, "connection")
          v = colon + 1
          while v < line_end && buf.unsafe_fetch(v) == 32 # ' '
            v += 1
          end
          vend = line_end
          vend -= 1 if vend > v && buf.unsafe_fetch(vend - 1) == 13 # '\r'
          len = vend - v
          return Conn::Close if len > 0 && eq_ignore_case?(buf, v, len, "close")
          return Conn::KeepAlive if len > 0 && eq_ignore_case?(buf, v, len, "keep-alive")
          return Conn::Default
        end
        line_start = line_end + 1
      end
      Conn::Default
    end

    # Same walk for `content-length`; 0 when absent or malformed.
    private def parse_content_length(buf : Slice(UInt8), head : Int32) : Int64
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

        if colon < line_end &&
           eq_ignore_case?(buf, line_start, colon - line_start, "content-length")
          v = colon + 1
          while v < line_end && buf.unsafe_fetch(v) == 32 # ' '
            v += 1
          end
          vend = line_end
          vend -= 1 if vend > v && buf.unsafe_fetch(vend - 1) == 13 # '\r'
          value = 0_i64
          while v < vend
            d = buf.unsafe_fetch(v)
            return 0_i64 if d < 48 || d > 57 # non-digit
            value = value * 10 + (d - 48)
            v += 1
          end
          return value
        end
        line_start = line_end + 1
      end
      0_i64
    end

    private def eq_ignore_case?(buf : Slice(UInt8), from : Int32, len : Int32, s : String) : Bool
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

    private def move_left(buf : Slice(UInt8), from : Int32, len : Int32) : Nil
      i = 0
      while i < len
        buf[i] = buf.unsafe_fetch(from + i)
        i += 1
      end
    end
  end
end
