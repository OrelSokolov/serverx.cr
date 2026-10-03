require "spec"
require "../src/serverx"

def free_port : Int32
  srv = TCPServer.new("127.0.0.1", 0)
  port = srv.local_address.port.to_i32
  srv.close
  port
end

def read_chunk(sock : IO) : Bytes
  buf = Bytes.new(65536)
  n = sock.read(buf)
  n > 0 ? buf[0, n] : Bytes.new(0)
end

# Boots a server on a free port, waits until it accepts, yields the port.
def boot_server(handler : HTTP::Handler? = nil, **opts, &)
  port = free_port
  stats = ServerX::Stats.new
  opts = {read_timeout: 2.seconds, write_timeout: 2.seconds, install_signals: false}.merge(opts)
  server = if handler
    ServerX::AppServer.new(handler, "127.0.0.1", port, stats, **opts)
  else
    ServerX::PooledServer.new("127.0.0.1", port, stats, **opts)
  end
  spawn { server.listen }
  50.times do
    begin
      TCPSocket.new("127.0.0.1", port).close
      break
    rescue Socket::Error | IO::Error
      sleep 50.milliseconds
    end
  end
  yield port
ensure
  server.try(&.stop)
end

# Raw-socket client that buffers leftover bytes (pipelining-safe reads).
class RawConn
  getter sock : TCPSocket
  property buf : Bytes

  def initialize(port : Int32)
    @sock = TCPSocket.new("127.0.0.1", port)
    @sock.read_timeout = 2.seconds
    @buf = Bytes.new(0)
  end

  def send(data : String) : Nil
    @sock.write(data.to_slice)
    @sock.flush
  end

  # Reads one full response (status line + headers + Content-Length body).
  def response : {String, String}
    data = String.new(@buf)
    while (data.index("\r\n\r\n")).nil?
      chunk = read_chunk(@sock)
      raise "EOF while reading headers" if chunk.empty?
      data += String.new(chunk)
    end
    head = data[0, data.index("\r\n\r\n").not_nil!]
    body_start = head.bytesize + 4
    cl = 0
    head.each_line do |line|
      if m = line.match(/^[Cc]ontent-[Ll]ength: (\d+)$/)
        cl = m[1].to_i
      end
    end
    while data.bytesize - body_start < cl
      chunk = read_chunk(@sock)
      raise "EOF while reading body" if chunk.empty?
      data += String.new(chunk)
    end
    consumed = body_start + cl
    @buf = data.to_slice[consumed..]
    {head, data[body_start, cl]}
  end

  def status_line : String
    response[0].lines.first
  end

  def read_all : String
    data = String.new(@buf)
    @buf = Bytes.new(0)
    loop do
      chunk = read_chunk(@sock)
      break if chunk.empty?
      data += String.new(chunk)
    end
    data
  end

  # True when the server closes the connection (EOF or reset) within `timeout`.
  def closed?(timeout : Time::Span = 2.seconds) : Bool
    @sock.read_timeout = timeout
    begin
      read_chunk(@sock).empty?
    rescue IO::Error
      true # e.g. ECONNRESET when the server closed with our data in flight
    end
  end

  def close : Nil
    @sock.close rescue nil
  end
end

# A simple app handler for the compat-layer specs.
class EchoHandler
  include HTTP::Handler
  property boom : Bool = false

  def call(context : HTTP::Server::Context) : Nil
    return context.response.respond_with_status(500) if @boom
    case context.request.path
    when "/echo"
      body = IO::Memory.new
      IO.copy(context.request.body.not_nil!, body)
      context.response.content_type = "application/octet-stream"
      context.response.headers["Content-Length"] = body.bytesize.to_s
      context.response.print body
    when "/info"
      body = String.build do |io|
        io << context.request.method << " "
        io << context.request.path << " "
        io << context.request.headers["X-Test"]?.inspect
      end
      context.response.content_type = "text/plain"
      context.response.print body
    when "/addr"
      body = "#{context.request.remote_address} | #{context.request.local_address}"
      context.response.content_type = "text/plain"
      context.response.print body
    when "/close"
      context.response.headers["Connection"] = "close"
      context.response.print "bye"
    else
      context.response.print "ok"
    end
  end
end
