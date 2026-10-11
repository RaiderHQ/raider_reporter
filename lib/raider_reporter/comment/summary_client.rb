# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "cgi/escape"

module RaiderReporter
  module Comment
    # Fetches the rendered build summary from the Raider API. Never raises:
    # failures return nil and set #last_error to a printable reason.
    class SummaryClient
      Summary = Data.define(:state, :markdown, :url)

      attr_reader :last_error

      def initialize(endpoint:, token:, timeout: 30)
        @endpoint = endpoint
        @token = token
        @timeout = timeout
        @last_error = nil
      end

      def fetch(build_key)
        @last_error = nil
        uri = summary_uri(build_key)
        request = Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Accept"] = "application/json"
        request["User-Agent"] = "raider_reporter/#{VERSION}"
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: @timeout, read_timeout: @timeout,
                                                       write_timeout: @timeout) { |http| http.request(request) }
        parse(response)
      rescue StandardError => e
        fail_with("#{e.class}: #{e.message}")
      end

      private

      def summary_uri(build_key)
        uri = URI.parse("#{@endpoint.to_s.strip.chomp('/')}/api/v1/builds/summary?build_key=#{CGI.escape(build_key.to_s)}")
        raise ArgumentError, "endpoint must start with http:// or https://" unless uri.is_a?(URI::HTTP)

        uri
      end

      def parse(response)
        case response.code.to_i
        when 200..299 then build_summary(response.body)
        when 401 then fail_with("HTTP 401: unauthorized (check RAIDER_TOKEN)")
        when 404 then fail_with("HTTP 404: build not found for this project")
        else fail_with("HTTP #{response.code}: #{response.body.to_s[0, 200]}")
        end
      end

      def build_summary(text)
        data = JSON.parse(text.to_s)
        unless data.is_a?(Hash) && %w[state markdown url].all? { |k| data[k].is_a?(String) }
          return fail_with("invalid summary response")
        end

        Summary.new(state: data["state"], markdown: data["markdown"], url: data["url"])
      rescue JSON::ParserError
        fail_with("invalid summary response (not JSON)")
      end

      def fail_with(reason)
        @last_error = @token.to_s.empty? ? reason : reason.gsub(@token.to_s, "[REDACTED]")
        nil
      end
    end
  end
end
