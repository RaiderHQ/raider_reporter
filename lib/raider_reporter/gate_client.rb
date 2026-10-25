# frozen_string_literal: true

require "cgi/escape"
require "json"
require "net/http"
require "openssl"
require "timeout"
require "uri"
require "raider_reporter/version"

module RaiderReporter
  # One GET /api/v1/builds/gate call for `raider-reporter gate` (spec §5), classified
  # so the caller can decide: a verdict, retry (429, 5xx, network), or stop.
  class GateClient
    class InvalidResponse < StandardError; end

    PATH = "/api/v1/builds/gate"
    TIMEOUT = 10
    STATES = %w[pending none passed failed].freeze
    NETWORK_ERRORS = [Timeout::Error, SystemCallError, SocketError, IOError, OpenSSL::SSL::SSLError,
                      Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError].freeze

    # kind: :verdict, :retry, :rejected, :not_found or :error.
    Response = Data.define(:kind, :data, :code, :reason)

    def initialize(endpoint:, token:)
      @endpoint = endpoint
      @token = token
    end

    def fetch(build_key)
      classify(request(build_key))
    rescue *NETWORK_ERRORS => e
      Response.new(kind: :retry, data: nil, code: nil, reason: redact("#{e.class}: #{e.message}"))
    end

    private

    def request(build_key)
      uri = URI.parse("#{@endpoint.to_s.strip.chomp('/')}#{PATH}?build_key=#{CGI.escape(build_key.to_s)}")
      raise ArgumentError, "RAIDER_ENDPOINT must start with http:// or https://" unless uri.is_a?(URI::HTTP)

      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@token}"
      req["Accept"] = "application/json"
      req["User-Agent"] = "raider_reporter/#{VERSION}"
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT,
                                          read_timeout: TIMEOUT, max_retries: 0) { |http| http.request(req) }
    end

    def classify(response)
      code = response.code.to_i
      case code
      when 200 then parse(response.body)
      when 401, 403 then Response.new(kind: :rejected, data: nil, code: code, reason: nil)
      when 404 then Response.new(kind: :not_found, data: nil, code: code, reason: nil)
      when 429, 500..599 then Response.new(kind: :retry, data: nil, code: code, reason: "HTTP #{code}")
      else error_response(code, "unexpected HTTP #{code}")
      end
    end

    def parse(body)
      data = JSON.parse(body.to_s)
      return error_response(200, "invalid gate response") unless valid?(data)

      Response.new(kind: :verdict, data: data, code: 200, reason: nil)
    rescue JSON::ParserError => e
      Response.new(kind: :error, data: nil, code: 200, reason: redact("#{e.class}: #{e.message}"))
    end

    def valid?(data)
      data.is_a?(Hash) && STATES.include?(data["state"]) && data["rules"].is_a?(Array)
    end

    # Spec §5 "other error" form: <class>: <message>.
    def error_response(code, message)
      Response.new(kind: :error, data: nil, code: code, reason: "#{InvalidResponse}: #{message}")
    end

    def redact(text)
      @token.to_s.empty? ? text : text.gsub(@token.to_s, "[REDACTED]")
    end
  end
end
