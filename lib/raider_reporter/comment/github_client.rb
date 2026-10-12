# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module RaiderReporter
  module Comment
    # Minimal GitHub REST client: upsert one marked PR comment and set a commit status.
    class GithubClient
      class Error < StandardError; end
      # 403/404: the token cannot write here (e.g. a fork's read-only token).
      class Forbidden < Error; end

      MAX_PAGES = 10
      PER_PAGE = 100
      DESCRIPTION_LIMIT = 140

      def initialize(token:, repository:, api_url: "https://api.github.com", timeout: 30)
        @token = token
        @repository = repository
        @api_url = api_url.to_s.strip.sub(%r{/+\z}, "")
        @timeout = timeout
      end

      def upsert_comment(pr_number, body, marker)
        existing = find_comment(pr_number, marker)
        response = if existing
                     request(:patch, "/repos/#{@repository}/issues/comments/#{existing['id']}", body: body)
                   else
                     request(:post, "/repos/#{@repository}/issues/#{pr_number}/comments", body: body)
                   end
        html_url = response.is_a?(Hash) ? response["html_url"] : nil
        raise Error, "GitHub response had no html_url" if html_url.to_s.empty?

        html_url
      end

      def set_status(sha, state:, target_url:, description:, context:)
        return nil if sha.to_s.strip.empty?

        payload = { state: state, target_url: target_url, context: context,
                    description: description.to_s[0, DESCRIPTION_LIMIT] }
        request(:post, "/repos/#{@repository}/statuses/#{sha}", payload: payload)
        nil
      end

      private

      def find_comment(pr_number, marker)
        (1..MAX_PAGES).each do |page|
          comments = request(:get, "/repos/#{@repository}/issues/#{pr_number}/comments?per_page=#{PER_PAGE}&page=#{page}")
          raise Error, "unexpected comments response" unless comments.is_a?(Array)

          found = comments.find { |c| ours?(c, marker) }
          return found if found
          return nil if comments.size < PER_PAGE
        end
        nil
      end

      # Only our own (bot-authored) marked comment is ever edited.
      def ours?(comment, marker)
        comment.is_a?(Hash) && comment["body"].to_s.start_with?(marker) &&
          comment.dig("user", "type") == "Bot"
      end

      def redact(text)
        @token.to_s.empty? ? text.to_s : text.to_s.gsub(@token.to_s, "[REDACTED]")
      end

      def request(verb, path, body: nil, payload: nil)
        uri = URI.parse(@api_url + path)
        raise Error, "GITHUB_API_URL must start with http:// or https://" unless uri.is_a?(URI::HTTP)

        req = build_request(verb, uri, payload || ({ body: body } if body))
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
        req["Accept"] = "application/vnd.github+json"
        req["X-GitHub-Api-Version"] = "2022-11-28"
        req["User-Agent"] = "raider_reporter/#{VERSION}"
        if json
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(json)
        end
        req
      end

      def handle(response)
        code = response.code.to_i
        raise Forbidden, "HTTP #{code}" if [403, 404].include?(code)
        raise Error, "HTTP #{code}: #{redact(response.body.to_s)[0, 200]}" unless (200..299).cover?(code)

        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        raise Error, "GitHub returned invalid JSON"
      end
    end
  end
end
