require "./spec_helper"

describe "AppServer (compat layer over HTTP::Handler)" do
  it "runs a stock handler and passes method/path/headers" do
    boot_server(EchoHandler.new) do |port|
      c = RawConn.new(port)
      c.send("GET /info HTTP/1.1\r\nHost: x\r\nX-Test: hello\r\n\r\n")
      head, body = c.response
      head.should contain("HTTP/1.1 200 OK")
      body.should eq(%(GET /info "hello"))
      c.close
    end
  end

  it "exposes a Content-Length body to the handler" do
    boot_server(EchoHandler.new) do |port|
      c = RawConn.new(port)
      c.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world")
      _, body = c.response
      body.should eq("hello world")
      c.close
    end
  end

  it "decodes chunked bodies with extensions and trailers" do
    boot_server(EchoHandler.new) do |port|
      c = RawConn.new(port)
      c.send("POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" \
             "5;ext=1\r\nhello\r\n6\r\n world\r\n0\r\nX-Tr: v\r\n\r\n")
      _, body = c.response
      body.should eq("hello world")
      # connection stays framed after trailers: reuse it
      c.send("GET /info HTTP/1.1\r\nHost: x\r\n\r\n")
      c.response[1].should eq(%(GET /info nil))
      c.close
    end
  end

  it "streams bodies larger than the connection buffer and stays framed" do
    boot_server(EchoHandler.new) do |port|
      c = RawConn.new(port)
      big = "z" * (ServerX::PooledServer::BUF_SIZE * 3)
      c.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: #{big.bytesize}\r\n\r\n")
      c.send(big)
      # echo response is large: read it fully
      data = String.new(c.buf)
      loop do
        chunk = read_chunk(c.sock)
        break if chunk.empty?
        data += String.new(chunk)
      end
      data.should start_with("HTTP/1.1 200 OK")
      data.should end_with(big)
      c.close

      # and a pipelined follow-up after a big body works too
      c2 = RawConn.new(port)
      c2.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: #{big.bytesize}\r\n\r\n#{big}" \
              "GET /info HTTP/1.1\r\nHost: x\r\n\r\n")
      data2 = String.new(read_chunk_loop(c2))
      data2.should end_with("GET /info nil") # echoed body + info body
      c2.close
    end
  end

  it "responds 413 when the body exceeds max_body" do
    boot_server(EchoHandler.new, max_body: 1000_i64) do |port|
      c = RawConn.new(port)
      c.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 100000\r\n\r\n")
      c.status_line.should start_with("HTTP/1.1 413")
    end
  end

  it "responds 501 to an unsupported Transfer-Encoding" do
    boot_server(EchoHandler.new) do |port|
      c = RawConn.new(port)
      c.send("POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n")
      c.status_line.should start_with("HTTP/1.1 501")
    end
  end

  it "responds 400 to Content-Length + Transfer-Encoding (smuggling)" do
    boot_server(EchoHandler.new) do |port|
      c = RawConn.new(port)
      c.send("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
      c.status_line.should start_with("HTTP/1.1 400")
    end
  end

  it "responds 500 and closes when the handler raises" do
    handler = EchoHandler.new
    boot_server(handler) do |port|
      c = RawConn.new(port)
      handler.boom = true
      c.send("GET /info HTTP/1.1\r\nHost: x\r\n\r\n")
      c.status_line.should start_with("HTTP/1.1 500")
    end
  end

  it "honors a handler-set Connection: close" do
    boot_server(EchoHandler.new) do |port|
      c = RawConn.new(port)
      c.send("GET /close HTTP/1.1\r\nHost: x\r\n\r\n")
      _, body = c.response
      body.should eq("bye")
      c.closed?.should be_true
    end
  end

  it "fills request.remote_address and local_address (stdlib contract)" do
    boot_server(EchoHandler.new) do |port|
      c = RawConn.new(port)
      c.send("GET /addr HTTP/1.1\r\nHost: x\r\n\r\n")
      _, body = c.response
      body.should start_with("127.0.0.1:")
      body.should contain(" | 127.0.0.1:")
      # same object cached across keep-alive requests
      c.send("GET /addr HTTP/1.1\r\nHost: x\r\n\r\n")
      _, body2 = c.response
      body2.should eq(body)
      c.close
    end
  end

  it "pipelines requests" do
    boot_server(EchoHandler.new) do |port|
      c = RawConn.new(port)
      c.send("GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /info HTTP/1.1\r\nHost: x\r\n\r\n")
      c.response[1].should eq("ok")
      c.response[1].should eq(%(GET /info nil))
      c.close
    end
  end

  it "works via HTTP::Client (keep-alive, HEAD, queries)" do
    boot_server(EchoHandler.new) do |port|
      HTTP::Client.new("127.0.0.1", port) do |client|
        # stdlib semantics: request.path excludes the query string
        client.get("/info?x=1").body.should eq(%(GET /info nil))
        client.post("/echo", body: "abc").body.should eq("abc")
        client.head("/info").status.ok?.should be_true
        client.get("/info", headers: HTTP::Headers{"X-Test" => "1"}).body.should eq(%(GET /info "1"))
      end
    end
  end

  it "serves TLS with a client over an insecure context" do
    cert = File.tempfile("sx_cert", ".pem")
    key = File.tempfile("sx_key", ".pem")
    sys = Process.new("openssl", ["req", "-x509", "-newkey", "rsa:2048",
      "-keyout", key.path, "-out", cert.path, "-days", "2", "-nodes",
      "-subj", "/CN=localhost"], output: Process::Redirect::Close)
    sys.wait.success?.should be_true
    ctx = OpenSSL::SSL::Context::Server.new
    ctx.certificate_chain = cert.path
    ctx.private_key = key.path
    boot_server(EchoHandler.new, tls: ctx) do |port|
      client = HTTP::Client.new("127.0.0.1", port, tls: OpenSSL::SSL::Context::Client.insecure)
      client.get("/info").body.should eq(%(GET /info nil))
      client.close
    end
  ensure
    cert.try(&.delete)
    key.try(&.delete)
  end
end

private def read_chunk_loop(conn : RawConn) : Bytes
  buf = Bytes.new(0)
  loop do
    chunk = read_chunk(conn.sock)
    break if chunk.empty?
    buf += chunk
  end
  buf
end
