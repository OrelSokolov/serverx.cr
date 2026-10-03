require "./spec_helper"

describe "PooledServer (fast transport, no handler)" do
  it "serves the precomputed response" do
    boot_server do |port|
      c = RawConn.new(port)
      c.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      head, body = c.response
      head.should contain("HTTP/1.1 200 OK")
      body.should eq("Hello, World!")
      c.close
    end
  end

  it "keeps the connection alive and pipelines" do
    boot_server do |port|
      c = RawConn.new(port)
      c.send("GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n")
      2.times { c.response[1].should eq("Hello, World!") }
      c.close
    end
  end

  it "honors Connection: close" do
    boot_server do |port|
      c = RawConn.new(port)
      c.send("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
      head, body = c.response
      head.should contain("Connection: close")
      c.closed?.should be_true
    end
  end

  it "keeps HTTP/1.0 alive only when asked" do
    boot_server do |port|
      c = RawConn.new(port)
      c.send("GET / HTTP/1.0\r\nHost: x\r\n\r\n")
      c.response
      c.closed?.should be_true

      c2 = RawConn.new(port)
      c2.send("GET / HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n")
      c2.response
      c2.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      c2.response[1].should eq("Hello, World!")
      c2.close
    end
  end

  it "matches header names case-insensitively" do
    boot_server do |port|
      c = RawConn.new(port)
      c.send("POST / HTTP/1.1\r\nHOST: x\r\nCONTENT-LENGTH: 3\r\nCONNECTION: CLOSE\r\n\r\nabc")
      c.response
      c.closed?.should be_true
    end
  end

  it "responds 431 when headers exceed the buffer" do
    boot_server do |port|
      c = RawConn.new(port)
      c.send("GET / HTTP/1.1\r\nHost: x\r\nX-Big: #{"a" * 70_000}\r\n\r\n")
      c.status_line.should start_with("HTTP/1.1 431")
      c.closed?.should be_true
    end
  end

  it "responds 400 to a malformed request line" do
    boot_server do |port|
      c = RawConn.new(port)
      c.send("GARBAGE\r\n\r\n")
      c.status_line.should start_with("HTTP/1.1 400")
    end
  end

  it "responds 501 to chunked bodies (no decoder on the fast path)" do
    boot_server do |port|
      c = RawConn.new(port)
      c.send("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
      c.status_line.should start_with("HTTP/1.1 501")
    end
  end

  it "responds 413 when Content-Length exceeds max_body" do
    boot_server(max_body: 100_i64) do |port|
      c = RawConn.new(port)
      c.send("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n")
      c.status_line.should start_with("HTTP/1.1 413")
    end
  end

  it "drains bodies larger than the buffer and stays reusable" do
    boot_server do |port|
      big = "q" * (ServerX::PooledServer::BUF_SIZE + 4096)
      2.times do
        c = RawConn.new(port)
        c.send("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: #{big.bytesize}\r\n\r\n")
        c.send(big)
        c.response[1].should eq("Hello, World!")
        c.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        c.response[1].should eq("Hello, World!")
        c.close
      end
    end
  end

  it "responds 503 beyond max_conns" do
    boot_server(max_conns: 2) do |port|
      a = RawConn.new(port)
      b = RawConn.new(port)
      c = RawConn.new(port)
      a.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      b.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      c.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      statuses = {a, b, c}.map &.status_line
      statuses.count { |s| s.starts_with?("HTTP/1.1 200") }.should eq(2)
      statuses.count { |s| s.starts_with?("HTTP/1.1 503") }.should eq(1)
      {a, b, c}.each &.close
    end
  end

  it "sends 100-continue when asked" do
    boot_server do |port|
      c = RawConn.new(port)
      c.send("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n")
      # read exactly the interim response (server is now waiting for the body)
      interim = String.new(read_chunk(c.sock))
      interim.should start_with("HTTP/1.1 100 Continue")
      c.send("abc")
      c.response[1].should eq("Hello, World!")
      c.close
    end
  end

  it "closes idle keep-alive connections after read_timeout" do
    boot_server(read_timeout: 200.milliseconds) do |port|
      c = RawConn.new(port)
      c.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
      c.response
      c.closed?(1.second).should be_true
    end
  end
end
