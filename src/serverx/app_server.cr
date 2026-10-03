require "http/server"
require "./pooled"

module ServerX
  # The production server: the pooled zero-alloc transport driving a stock
  # `HTTP::Handler`. Framing — keep-alive, pipelining, Content-Length and
  # chunked request bodies, body draining, hard limits — is decided by the
  # transport (see `PooledServer`); the handler sees a standard
  # `HTTP::Server::Context` and any Crystal framework works on top.
  #
  # The `HTTP::Server::Response` is allocated once per connection and reused
  # across keep-alive requests via `Response#reset` (the same trick the
  # stdlib `RequestProcessor` plays). The request body is exposed through a
  # reader that serves straight from the connection buffer and streams from
  # the socket for bodies larger than the buffer.
  class AppServer < PooledServer
    Log = ::Log.for("serverx.app")

    def initialize(@handler : HTTP::Handler, host : String, port : Int32,
                   stats : Stats = Stats.new, **opts)
      super(host, port, stats, **opts)
    end

    # Full request cycle; the response object is reused between keep-alive
    # requests (HEAD requests get their own, filtered one).
    protected def handle(io : IO) : Nil
      # Batch the many small `<<` writes of `Response#write_headers` into a
      # single syscall per response (the stdlib server does the same).
      io.sync = false if io.is_a?(IO::Buffered)
      buf = Slice(UInt8).new(BUF_SIZE)
      filled = 0
      keep_alive_response : HTTP::Server::Response? = nil
      body_reader : BodyReader? = nil

      # Client/server addresses of the connection (cached once; stdlib
      # semantics: `HTTP::Server` fills these, frameworks rely on them for
      # logging, IP filters and rate limits).
      remote_addr = io.remote_address if io.responds_to?(:remote_address)
      local_addr = io.local_address if io.responds_to?(:local_address)

      loop do
        # 1. Ensure the complete header section is buffered.
        head = header_end(buf, filled)
        while head == -1
          if filled == buf.size
            io.write(resp_431)
            io.flush
            return
          end
          n = read_once(io, buf, filled)
          return if n == -1
          filled += n
          head = header_end(buf, filled)
        end

        # 2. Validate the request line, scan headers in one walk.
        unless request_line_ok?(buf, head)
          return write_error(io, 400, "Bad Request")
        end
        h = scan_headers(buf, head)
        if h.content_length == -1 || (h.has_cl && h.te != TE::None)
          # malformed Content-Length, or Content-Length + Transfer-Encoding
          # together (request smuggling, RFC 9112 6.1)
          return write_error(io, 400, "Bad Request")
        end
        if h.te == TE::Other
          return write_error(io, 501, "Not Implemented")
        end

        keep =
          case h.connection
          when Conn::Close     then false
          when Conn::KeepAlive then true
          else                      h.http11
          end

        # 3. Body framing: fixed-length or chunked, capped by max_body.
        # One BodyReader is pooled per connection and reset per request.
        body = nil
        if h.te == TE::Chunked
          body = (body_reader ||= BodyReader.new(io, buf, 0, 0, @max_body, :fixed))
          body.reset(head + 4, filled, :chunked, 0_i64)
        elsif h.content_length > 0
          if h.content_length > @max_body
            return write_error(io, 413, "Payload Too Large")
          end
          body = (body_reader ||= BodyReader.new(io, buf, 0, 0, @max_body, :fixed))
          body.reset(head + 4, filled, :fixed, h.content_length)
        end

        # 4. Expect: 100-continue — green-light the body before the handler.
        if h.expect_continue && body
          io.write(resp_100_continue)
          io.flush
        end

        # 5. Materialize the request from offsets and run the handler.
        request = build_request(buf, head, h, body)
        return write_error(io, 400, "Bad Request") unless request
        request.remote_address = remote_addr
        request.local_address = local_addr

        # A HEAD response carries the same headers but no body (RFC 9110
        # §9.3.2). The stdlib response would happily write the body, so wrap
        # the socket in a filter that swallows bytes after the header block.
        # (One extra allocation, HEAD requests only.)
        head_request = request.method == "HEAD"
        if head_request
          response = HTTP::Server::Response.new(HeadFilterIO.new(io))
        else
          response = (keep_alive_response ||= HTTP::Server::Response.new(io))
        end
        response.reset
        response.version = h.http11 ? "HTTP/1.1" : "HTTP/1.0"
        response.headers["Connection"] = keep ? "keep-alive" : "close"
        context = HTTP::Server::Context.new(request, response)

        begin
          @handler.call(context)
        rescue ex : HTTP::Server::ClientError
          return # client is gone
        rescue ex : IO::Error | OpenSSL::SSL::Error
          return # client hung up mid-handler
        rescue ex
          Log.error(exception: ex) { "unhandled exception in HTTP handler" }
          keep = false
          unless response.closed?
            begin
              response.respond_with_status(:internal_server_error)
            rescue IO::Error | KeyError
              # headers were already written; nothing more we can send
            end
          end
        end

        begin
          response.output.close
          io.flush
        rescue ex : HTTP::Server::ClientError | IO::Error | OpenSSL::SSL::Error
          return
        end

        # Protocol upgrade (e.g. websockets): hand over the connection.
        if upgrade = response.upgrade_handler
          upgrade.call(io)
          return
        end

        # The handler may force the connection closed.
        keep = false if response.headers["Connection"]?.try(&.downcase) == "close"

        # 6. Sync the body to its end (the handler may have left it unread)
        # and learn where the next pipelined request starts in the buffer.
        pos = head + 4
        if body
          body.drain
          filled = body.filled
          pos = body.pos
          if body.overflow? || body.malformed?
            return # framing is unreliable past this point
          end
        end

        leftover = filled - pos
        move_left(buf, pos, leftover) if leftover > 0
        filled = leftover

        @stats.requests.add(1)
        return unless keep
      end
    rescue IO::Error | OpenSSL::SSL::Error
      # client hung up / reset / timed out — nothing to clean up
    end

    # Interned HTTP vocabulary: methods and common header names are a small
    # finite set, so the handler receives shared String literals instead of
    # fresh allocations (Crystal strings are immutable — sharing is safe;
    # `HTTP::Headers` keys are case-insensitive, so canonicalizing the case
    # of a known name is invisible to handlers). Unknown names fall back to
    # a normal allocation.
    METHODS = {"GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "TRACE", "CONNECT"}

    HEADER_NAMES = {
      "Accept", "Accept-Charset", "Accept-Encoding", "Accept-Language",
      "Authorization", "Cache-Control", "Connection", "Content-Disposition",
      "Content-Encoding", "Content-Length", "Content-Range", "Content-Type",
      "Cookie", "Date", "ETag", "Expect", "If-Match", "If-Modified-Since",
      "If-None-Match", "If-Range", "If-Unmodified-Since", "Keep-Alive",
      "Last-Modified", "Location", "Origin", "Proxy-Authorization", "Range",
      "Referer", "Server", "TE", "Transfer-Encoding", "Upgrade",
      "User-Agent", "X-Forwarded-For", "X-Forwarded-Proto", "X-Real-IP",
      "X-Request-Id", "Sec-WebSocket-Key", "Sec-WebSocket-Version",
      "Sec-WebSocket-Protocol", "Sec-WebSocket-Extensions",
    }

    # Methods are case-sensitive tokens: exact byte match only.
    private def intern_method(buf : Slice(UInt8), size : Int32) : String
      METHODS.each do |m|
        next unless m.bytesize == size
        ptr = m.to_unsafe
        i = 0
        ok = true
        while i < size
          if buf.unsafe_fetch(i) != ptr[i]
            ok = false
            break
          end
          i += 1
        end
        return m if ok
      end
      String.new(buf.to_unsafe, size)
    end

    # Header names are case-insensitive: canonical literal on match.
    private def intern_header_name(buf : Slice(UInt8), from : Int32, size : Int32) : String
      HEADER_NAMES.each do |n|
        return n if n.bytesize == size && eq_ignore_case?(buf, from, size, n)
      end
      String.new(buf.to_unsafe + from, size)
    end

    private def build_request(buf : Slice(UInt8), head : Int32, h : HeaderScan,
                              body : BodyReader?) : HTTP::Request?
      # Request line offsets: METHOD SP PATH SP VERSION.
      m_size = 0
      while m_size < head && buf.unsafe_fetch(m_size) != 32 # ' '
        m_size += 1
      end
      p_from = m_size + 1
      p_size = 0
      while p_from + p_size < head && buf.unsafe_fetch(p_from + p_size) != 32 # ' '
        p_size += 1
      end

      # No temp Headers hash and no stdlib `dup`: create the request with
      # empty headers and fill its own hash straight from the buffer. Values
      # still pass through `Headers#add` (invalid-content checks included).
      request = HTTP::Request.new(
        intern_method(buf, m_size),
        String.new(buf.to_unsafe + p_from, p_size),
        nil,
        body,
        h.http11 ? "HTTP/1.1" : "HTTP/1.0"
      )
      headers = request.headers

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
        return nil if colon == line_end # header line without a colon
        return nil if colon == line_start

        name_size = colon - line_start
        v = colon + 1
        while v < line_end && (buf.unsafe_fetch(v) == 32 || buf.unsafe_fetch(v) == 9) # SP | HTAB
          v += 1
        end
        vend = line_end
        vend -= 1 if vend > v && buf.unsafe_fetch(vend - 1) == 13 # '\r'

        headers.add(
          intern_header_name(buf, line_start, name_size),
          String.new(buf.to_unsafe + v, vend - v)
        )
        line_start = line_end + 1
      end

      request
    end

    # IO wrapper for HEAD responses: forwards the status line and headers,
    # then swallows the body bytes (counting them so `Content-Length` set by
    # `HTTP::Server::Response` stays truthful). Chunked responses degrade
    # gracefully: the chunk framing is swallowed along with the body.
    class HeadFilterIO < IO
      def initialize(@io : IO)
        @headers_done = false
        @tail = Bytes.empty # unfinished "\r\n\r\n" candidate carried across writes
      end

      def read(slice : Bytes) : Int32
        raise IO::Error.new("Can't read from a HEAD filter")
      end

      def write(slice : Bytes) : Nil
        return if slice.empty?
        if @headers_done
          return # swallow the body
        end
        # Look for the end of the header block, allowing the terminator to
        # straddle write boundaries.
        window = @tail + slice
        idx = find_terminator(window)
        if idx
          @headers_done = true
          @io.write(window[0, idx + 4])
          @tail = Bytes.empty
        else
          # Keep the last 3 bytes as a candidate for a split terminator.
          keep = Math.min(3, window.size)
          @io.write(window[0, window.size - keep])
          @tail = window[window.size - keep, keep].dup
        end
      end

      def flush : Nil
        @io.flush
      end

      private def find_terminator(b : Bytes) : Int32?
        limit = b.size - 4
        i = 0
        while i <= limit
          if b.unsafe_fetch(i) == 13 && b.unsafe_fetch(i + 1) == 10 &&
             b.unsafe_fetch(i + 2) == 13 && b.unsafe_fetch(i + 3) == 10
            return i
          end
          i += 1
        end
        nil
      end
    end

    # Request body reader: serves from the connection buffer, refilling from
    # the socket for bodies that don't fit; decodes chunked bodies on the fly.
    # Tracks `pos`/`filled` so the transport knows where the next pipelined
    # request begins once the body is consumed.
    class BodyReader < IO
      getter pos : Int32
      getter filled : Int32
      getter? overflow : Bool = false
      getter? malformed : Bool = false

      @total = 0_i64
      @eof = false
      @chunk_remaining = 0_i64
      @need_crlf = false

      def initialize(@io : IO, @buf : Bytes, @pos : Int32, @filled : Int32,
                     @max_body : Int64, @mode : Mode, @remaining : Int64 = 0_i64)
      end

      # Returns the reader to a pristine state for the next request on the
      # same connection (one reader is pooled per connection). Every field
      # that carries per-request state must be reset here — a missed one
      # would corrupt framing (request-smuggling class), so the soak test
      # exercises fixed and chunked bodies back to back.
      def reset(pos : Int32, filled : Int32, mode : Mode, remaining : Int64) : Nil
        @pos = pos
        @filled = filled
        @mode = mode
        @remaining = remaining
        @chunk_remaining = 0_i64
        @need_crlf = false
        @total = 0_i64
        @eof = false
        @overflow = false
        @malformed = false
      end

      enum Mode
        Fixed
        Chunked
      end

      def read(slice : Bytes) : Int32
        return 0 if slice.empty? || @eof
        @mode.fixed? ? read_fixed(slice) : read_chunked(slice)
      end

      def write(slice : Bytes) : Nil
        raise IO::Error.new("Can't write to a request body")
      end

      private def read_fixed(slice : Bytes) : Int32
        if @remaining == 0
          @eof = true
          return 0
        end
        if @pos == @filled
          return 0 unless refill
        end
        take = {@remaining, slice.size.to_i64, (@filled - @pos).to_i64}.min
        slice.copy_from(@buf.to_unsafe + @pos, take)
        @pos += take.to_i32
        @remaining -= take
        take.to_i32
      end

      private def read_chunked(slice : Bytes) : Int32
        loop do
          return 0 if @eof || @malformed || @overflow

          if @chunk_remaining > 0
            if @pos == @filled
              return 0 unless refill
            end
            take = {@chunk_remaining, slice.size.to_i64, (@filled - @pos).to_i64}.min
            slice.copy_from(@buf.to_unsafe + @pos, take)
            @pos += take.to_i32
            @chunk_remaining -= take
            if @chunk_remaining == 0
              @need_crlf = true
            end
            return take.to_i32
          end

          if @need_crlf
            return 0 unless consume_crlf
            @need_crlf = false
          end

          size = parse_size_line
          return 0 if size < 0
          if size == 0
            consume_trailers
            @eof = true
            return 0
          end
          if @total + size > @max_body
            @overflow = true
            @eof = true
            return 0
          end
          @chunk_remaining = size
        end
      end

      # Reads the body to its end so the transport can resume framing.
      def drain : Nil
        scratch = StaticArray(UInt8, 8192).new(0)
        while read(scratch.to_slice) > 0
        end
      end

      private def refill : Bool
        if @pos == @filled
          @pos = 0
          @filled = 0
        elsif @filled == @buf.size
          # Slide the unread window to the front of the buffer.
          move = @filled - @pos
          @buf.copy_from(@buf.to_unsafe + @pos, move) if @pos > 0 && move > 0
          @pos = 0
          @filled = move
        end
        n = @io.read(@buf + @filled)
        if n <= 0
          @eof = true
          return false
        end
        @filled += n
        true
      end

      private def consume_crlf : Bool
        return false unless ensure_filled(2)
        if @buf.unsafe_fetch(@pos) == 13 && @buf.unsafe_fetch(@pos + 1) == 10
          @pos += 2
          true
        else
          @malformed = true
          @eof = true
          false
        end
      end

      # Parses a chunk size line `HEX[;ext] CRLF`; -1 on malformed/EOF.
      private def parse_size_line : Int64
        line_end = find_crlf
        while !line_end && @filled < @buf.size
          break unless refill
          line_end = find_crlf
        end
        unless line_end
          @malformed = true
          @eof = true
          return -1_i64
        end
        size = 0_i64
        i = @pos
        digits = 0
        while i < line_end
          d = @buf.unsafe_fetch(i)
          if d == 59 # ';' — chunk extension follows
            break
          end
          v = hex_value(d)
          if v == -1
            @malformed = true
            @eof = true
            return -1_i64
          end
          size = size * 16 + v
          digits += 1
          i += 1
        end
        if digits == 0
          @malformed = true
          @eof = true
          return -1_i64
        end
        @pos = line_end + 2
        size
      end

      # Trailer section after the 0-chunk: header lines until an empty line.
      private def consume_trailers : Nil
        loop do
          line_end = find_crlf
          while !line_end && @filled < @buf.size
            break unless refill
            line_end = find_crlf
          end
          return unless line_end
          if line_end == @pos # empty line: end of trailers
            @pos += 2
            return
          end
          @pos = line_end + 2
        end
      end

      private def find_crlf : Int32?
        i = @pos
        limit = @filled - 1
        while i < limit
          if @buf.unsafe_fetch(i) == 13 && @buf.unsafe_fetch(i + 1) == 10
            return i
          end
          i += 1
        end
        nil
      end

      private def ensure_filled(n : Int32) : Bool
        while @filled - @pos < n
          return false unless refill
        end
        true
      end

      private def hex_value(d : UInt8) : Int32
        case d
        when 48..57  then (d - 48).to_i32
        when 97..102 then (d - 97 + 10).to_i32
        when 65..70  then (d - 65 + 10).to_i32
        else              -1
        end
      end
    end
  end
end
