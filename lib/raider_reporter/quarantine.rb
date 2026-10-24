# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "set"
require "timeout"
require "uri"

module RaiderReporter
  NUL = "\u0000"
  NUL_REPLACEMENT = "\u{FFFD}"

  # The server's test identity: raider_saas TestCase.key_for over the payload's
  # file_path and full_name, after ingest replaced NUL in each of them.
  def self.test_key(file_path, full_name)
    parts = [file_path, full_name].map { |part| part.to_s.tr(NUL, NUL_REPLACEMENT) }
    Digest::SHA256.hexdigest(parts.join(NUL))
  end

  # Fetches the project's quarantine list (spec §4.2). Fail-open: any problem
  # means one warning and an empty set, never an exception.
  module Quarantine
    PATH = "/api/v1/quarantine"
    TIMEOUT = 3
    EMPTY = Set.new.freeze

    class Unavailable < StandardError; end

    def self.load(config, warn:)
      return EMPTY unless config.quarantine?

      Set.new(fetch(config)).freeze
    rescue StandardError => e
      reason = e.is_a?(Unavailable) ? e.message : "#{e.class}: #{e.message}"
      warn.call(warning(reason, token: config.token))
      EMPTY
    end

    # The one place the fail-open warning text is built (used by load and the Collector).
    def self.warning(reason, token: nil)
      "quarantine list unavailable (#{redact(reason, token)}); no tests quarantined"
    end

    def self.fetch(config)
      uri = URI.parse("#{config.endpoint.to_s.strip.chomp('/')}#{PATH}")
      raise Unavailable, "RAIDER_ENDPOINT must start with http:// or https://" unless uri.is_a?(URI::HTTP)

      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{config.token}"
      request["Accept"] = "application/json"
      request["User-Agent"] = "raider_reporter/#{VERSION}"
      # The per-step timeouts do not bound a server that trickles bytes; the deadline does.
      response = Timeout.timeout(TIMEOUT) do
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: TIMEOUT, read_timeout: TIMEOUT, max_retries: 0) { |http| http.request(request) }
      end
      raise Unavailable, "HTTP #{response.code}" unless response.code == "200"

      keys(response.body)
    end

    def self.keys(body)
      data = JSON.parse(body.to_s)
      list = data.is_a?(Hash) ? data["quarantined"] : nil
      raise Unavailable, "unexpected response" unless list.is_a?(Array)

      list.filter_map { |entry| entry["test_key"] if entry.is_a?(Hash) && entry["test_key"].is_a?(String) }
    rescue JSON::ParserError
      raise Unavailable, "invalid JSON"
    end

    def self.redact(text, token)
      token.to_s.empty? ? text : text.gsub(token.to_s, "[REDACTED]")
    end

    private_class_method :fetch, :keys, :redact
  end
end
