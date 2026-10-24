# frozen_string_literal: true

require "json"
require "socket"

# A tiny HTTP server on 127.0.0.1 for specs whose requests come from a child process
# (WebMock cannot see those) or that need a real socket that hangs or trickles.
class FakeRaider
  attr_reader :requests

  def self.with_quarantine(keys)
    body = JSON.generate("quarantined" => keys.map { |key| { "test_key" => key, "expires_at" => "2026-11-07T12:00:00Z" } })
    server = new { |method, _path| method == "GET" ? [200, body] : [201, "{}"] }
    yield({ "RAIDER_TOKEN" => "tok", "RAIDER_ENDPOINT" => server.url, "RAIDER_QUARANTINE" => "1" }, server)
  ensure
    server&.close
  end

  def initialize(&handler)
    @handler = handler
    @requests = []
    @threads = []
    @server = TCPServer.new("127.0.0.1", 0)
    @threads << Thread.new { serve }
  end

  def url = "http://127.0.0.1:#{@server.addr[1]}"

  def close
    @threads.each(&:kill)
    @server.close unless @server.closed?
  end

  private

  def serve
    loop do
      client = @server.accept
      @threads << Thread.new(client) { |socket| handle(socket) }
    end
  rescue IOError, SystemCallError
    nil
  end

  def handle(socket)
    method, path = socket.gets.to_s.split
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.to_s.strip
    end
    socket.read(headers["content-length"].to_i) if headers["content-length"]
    @requests << { method: method, path: path, headers: headers }
    status, body = @handler.call(method, path)
    respond(socket, status, body.to_s)
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close unless socket.closed?
  end

  def respond(socket, status, body)
    case status
    when :hang then sleep
    when :trickle
      socket.write("HTTP/1.1 200 OK\r\n")
      loop do
        socket.write("X")
        socket.flush
        sleep 0.1
      end
    else
      socket.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: close\r\n\r\n#{body}")
    end
  end
end
