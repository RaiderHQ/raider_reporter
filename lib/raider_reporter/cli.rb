# frozen_string_literal: true

require "raider_reporter"

module RaiderReporter
  # `raider-reporter comment`: posts the build summary as a PR comment and sets a commit status.
  # Fail-open: #run always returns 0, notices go to stderr, nothing goes to stdout.
  class CLI
    MARKER = "<!-- raider-reporter:build-comment -->"
    CONTEXT = "raider/tests"
    REQUIRED_ENV = %w[GITHUB_TOKEN GITHUB_REPOSITORY GITHUB_EVENT_PATH RAIDER_TOKEN RAIDER_ENDPOINT].freeze
    STATUS_STATES = { "passed" => "success", "failed" => "failure", "incomplete" => "pending" }.freeze
    FALLBACK_DESCRIPTIONS = {
      "passed" => "Raider: tests passed",
      "failed" => "Raider: tests failed",
      "incomplete" => "Raider: build incomplete"
    }.freeze
    DEFAULT_API_URL = "https://api.github.com"
    USAGE = <<~TEXT
      Usage: raider-reporter comment

      Posts (or updates) the Raider build summary as a comment on the current pull request
      and sets the "#{CONTEXT}" commit status. Intended for GitHub Actions; always exits 0.

      Environment: #{REQUIRED_ENV.join(', ')} (GITHUB_API_URL optional).
    TEXT

    def initialize(argv, env: ENV, out: $stdout, err: $stderr)
      @argv = argv
      @env = env
      @out = out
      @err = err
    end

    def run
      command = @argv.first
      if command == "comment" && !@argv.include?("--help") && !@argv.include?("-h")
        comment
      else
        @err.puts(USAGE)
      end
      0
    rescue StandardError => e
      notice("comment failed: #{e.class}: #{e.message}")
      0
    end

    private

    def comment
      missing = REQUIRED_ENV.select { |name| @env[name].to_s.strip.empty? }
      return notice("skipped: missing #{missing.join(', ')}") unless missing.empty?

      event = GithubEvent.load(@env)
      detector = CiDetector.new(env: @env, event_reader: -> { event })
      pr = detector.git&.dig("pr")
      return notice("skipped: not a pull request event") unless pr

      build_key = detector.ci&.dig("build_key")
      return notice("skipped: could not determine the build key") unless build_key

      publish(pr, build_key)
    rescue Comment::GithubClient::Forbidden
      notice("skipped: token cannot write to this PR")
    rescue StandardError => e
      notice("comment failed: #{e.class}: #{e.message}")
    end

    def publish(pr, build_key)
      summaries = Comment::SummaryClient.new(endpoint: @env["RAIDER_ENDPOINT"], token: @env["RAIDER_TOKEN"])
      summary = summaries.fetch(build_key)
      return notice("summary unavailable: #{summaries.last_error}") unless summary

      github = Comment::GithubClient.new(token: @env["GITHUB_TOKEN"], repository: @env["GITHUB_REPOSITORY"],
                                         api_url: api_url)
      html_url = github.upsert_comment(pr["number"], summary.markdown, MARKER)
      github.set_status(pr["head_sha"], state: STATUS_STATES.fetch(summary.state, "pending"),
                                        target_url: summary.url, description: description(summary),
                                        context: CONTEXT)
      notice("PR comment updated: #{html_url}")
    end

    def api_url
      url = @env["GITHUB_API_URL"].to_s.strip
      url.empty? ? DEFAULT_API_URL : url
    end

    # "Raider: 2 failed, 148 passed, 3 skipped (4/4 shards) — 1m 12s" -> "2 failed, 148 passed, 3 skipped".
    # Falls back to a fixed text per state when the Markdown carries no headline counts.
    def description(summary)
      counts = headline_counts(summary.markdown)
      text = counts || FALLBACK_DESCRIPTIONS.fetch(summary.state, FALLBACK_DESCRIPTIONS["incomplete"])
      text[0, Comment::GithubClient::DESCRIPTION_LIMIT]
    end

    def headline_counts(markdown)
      line = markdown.to_s.lines.map(&:strip).find { |l| l.match?(/\A\W*Raider:\s*\d+ \w+/) }
      return nil unless line

      parts = line.sub(/\A\W*Raider:\s*/, "").split(/\s+[(—–-]/, 2).first.to_s.split(",").map(&:strip)
      parts = parts.grep(/\A\d+ [a-z]+\z/i)
      parts.empty? ? nil : parts.join(", ")
    end

    def notice(message)
      @err.puts("[raider_reporter] #{message}")
      nil
    end
  end
end
