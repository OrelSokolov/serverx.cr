module ServerX
  # Baseline: the stock stdlib `HTTP::Server` with the same payload. This is
  # what every Crystal framework (Kemal, Lucky, Grip, ...) actually runs on —
  # the numbers below it are the framework floor.
  class StdlibServer
    def initialize(@host : String, @port : Int32, @stats : Stats)
    end

    def listen : Nil
      server = HTTP::Server.new do |context|
        @stats.requests.add(1)
        context.response.content_type = "text/plain"
        context.response.print "Hello, World!"
      end
      server.bind_tcp(@host, @port, reuse_port: true)
      Signal::TERM.trap { server.close rescue nil }
      Signal::INT.trap { server.close rescue nil }
      server.listen
    end
  end
end
