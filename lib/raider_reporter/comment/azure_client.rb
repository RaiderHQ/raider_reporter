# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module RaiderReporter
  module Comment
    # Minimal Azure DevOps REST client: one Raider thread per pull request, plus a PR status.
    class AzureClient
      class Error < StandardError; end
      # 401/403/404: the build service identity cannot write to this PR.
      class Forbidden < Error; end

      API_VERSION = "7.1"
      STATUS_API_VERSION = "7.1" # confirmed in the 7.1 Pull Request Statuses doc; see spec header
      PROPERTY = "Raider.BuildComment"
      DESCRIPTION_LIMIT = 140

      def initialize(token:, base_url:, timeout: 30)
        @token = token
        @base_url = base_url.to_s.sub(%r{/+\z}, "")
        @timeout = timeout
      end

      def upsert_thread(markdown, marker, status:)
        thread = find_thread(marker)
        if thread
          comment_id = thread["comments"].first["id"]
          request(:patch, "/threads/#{thread['id']}/comments/#{comment_id}", { content: markdown })
          request(:patch, "/threads/#{thread['id']}", { status: status })
          :updated
        else
          request(:post, "/threads", { comments: [{ parentCommentId: 0, content: markdown, commentType: 1 }],
                                       status: status,
                                       properties: { PROPERTY => { "$type" => "System.Int32", "$value" => 1 } } })
          :created
        end
      end

      def set_status(state:, description:, target_url:)
        request(:post, "/statuses", { state: state, description: description.to_s[0, DESCRIPTION_LIMIT],
                                      targetUrl: target_url, context: { genre: "raider", name: "tests" } },
                version: STATUS_API_VERSION)
        nil
      end

      private

      def find_thread(marker)
        list = request(:get, "/threads")
        threads = list.is_a?(Hash) ? list["value"] : nil
        raise Error, "unexpected threads response" unless threads.is_a?(Array)

        threads.find { |t| ours?(t, marker) }
      end

      # Only a property-tagged thread whose live first comment starts with the marker is ours.
      def ours?(thread, marker)
        return false unless thread.is_a?(Hash) && thread["properties"].is_a?(Hash) && thread["properties"].key?(PROPERTY)
        return false unless thread["comments"].is_a?(Array)

        first = thread["comments"].first
        first.is_a?(Hash) && !first["isDeleted"] && first["content"].to_s.start_with?(marker)
      end

      def redact(text)
        @token.to_s.empty? ? text.to_s : text.to_s.gsub(@token.to_s, "[REDACTED]")
      end

      def request(verb, path, payload = nil, version: nil)
        uri = URI.parse("#{@base_url}#{path}?api-version=#{version || API_VERSION}")
        raise Error, "Azure DevOps URL must start with http:// or https://" unless uri.is_a?(URI::HTTP)

        req = build_request(verb, uri, payload)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: @timeout, read_timeout: @timeout,
                                                       write_timeout: @timeout) { |http| http.request(req) }
        handle(response)
      rescue Error
        raise
      rescue StandardError => e
        raise Error, redact("#{e.class}: #{e.message}")
      end

      def build_request(verb, uri, json)
        klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch }.fetch(verb)
        req = klass.new(uri)
        req["Authorization"] = "Bearer #{@token}"
        req["Accept"] = "application/json"
        req["User-Agent"] = "raider_reporter/#{VERSION}"
        if json
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(json)
        end
        req
      end

      def handle(response)
        code = response.code.to_i
        raise Forbidden, "HTTP #{code}" if [401, 403, 404].include?(code)
        raise Error, redact("HTTP #{code}: #{response.body.to_s[0, 200]}") unless (200..299).cover?(code)

        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        raise Error, "Azure DevOps returned invalid JSON"
      end
    end
  end
end
