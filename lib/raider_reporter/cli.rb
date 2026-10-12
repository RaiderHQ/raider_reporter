# frozen_string_literal: true

require "raider_reporter"

module RaiderReporter
  # `raider-reporter comment`: posts the build summary as a PR comment and sets a commit status.
  # Fail-open: #run always returns 0, notices go to stderr, nothing goes to stdout.
  class CLI
    MARKER = "<!-- raider-reporter:build-comment -->"
    CONTEXT = "raider/tests"
    GITHUB_REQUIRED_ENV = %w[GITHUB_TOKEN GITHUB_REPOSITORY GITHUB_EVENT_PATH RAIDER_TOKEN RAIDER_ENDPOINT].freeze
    REQUIRED_ENV = GITHUB_REQUIRED_ENV
    AZURE_REQUIRED_ENV = %w[SYSTEM_ACCESSTOKEN SYSTEM_COLLECTIONURI SYSTEM_TEAMPROJECTID BUILD_REPOSITORY_ID
                            RAIDER_TOKEN RAIDER_ENDPOINT].freeze
    THREAD_STATUS = { "passed" => "closed" }.freeze
    AZURE_STATES = { "passed" => "succeeded", "failed" => "failed", "incomplete" => "pending" }.freeze
    TOKEN_HINT = "map it with env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)"
    STATUS_STATES = { "passed" => "success", "failed" => "failure", "incomplete" => "pending" }.freeze
    FALLBACK_DESCRIPTIONS = {
      "passed" => "Raider: tests passed",
      "failed" => "Raider: tests failed",
      "incomplete" => "Raider: build incomplete"
    }.freeze
    DEFAULT_API_URL = "https://api.github.com"
    USAGE = <<~TEXT
      Usage: raider-reporter comment

      Posts (or updates) the Raider build summary on the current pull request and sets a status.
      Intended for GitHub Actions and Azure Pipelines (Azure Repos); always exits 0.

      GitHub Actions: comment + "#{CONTEXT}" commit status.
        Environment: #{GITHUB_REQUIRED_ENV.join(', ')} (GITHUB_API_URL optional).
      Azure Pipelines: one PR thread updated in place + a "raider/tests" PR status.
        Environment: #{AZURE_REQUIRED_ENV.join(', ')}.
        Map the token in the pipeline: env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)
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
      if @env["GITHUB_ACTIONS"] == "true"
        github_comment
      elsif AzureEnv.azure?(@env)
        azure_comment
      else
        notice("skipped: unsupported CI")
      end
    end

    def github_comment
      missing = GITHUB_REQUIRED_ENV.select { |name| @env[name].to_s.strip.empty? }
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

    def azure_comment
      missing = AZURE_REQUIRED_ENV.select { |name| AzureEnv.value(@env, name).nil? }
      return notice(azure_missing_message(missing)) unless missing.empty?

      detector = CiDetector.new(env: @env, git: ->(*) {})
      pr = detector.git&.dig("pr")
      return notice("skipped: not an Azure Repos pull request") unless pr

      build_key = detector.ci&.dig("build_key")
      return notice("skipped: could not determine the build key") unless build_key

      publish_azure(pr, build_key)
    rescue Comment::AzureClient::Forbidden
      notice(azure_forbidden_message)
    rescue StandardError => e
      notice("comment failed: #{e.class}: #{e.message}")
    end

    def azure_missing_message(missing)
      message = "skipped: missing #{missing.join(', ')}"
      message += "; #{TOKEN_HINT}" if missing.include?("SYSTEM_ACCESSTOKEN")
      message
    end

    def publish_azure(pr, build_key)
      summaries = Comment::SummaryClient.new(endpoint: AzureEnv.value(@env, "RAIDER_ENDPOINT"),
                                             token: AzureEnv.value(@env, "RAIDER_TOKEN"))
      summary = summaries.fetch(build_key)
      return notice("summary unavailable: #{summaries.last_error}") unless summary

      azure = Comment::AzureClient.new(token: AzureEnv.value(@env, "SYSTEM_ACCESSTOKEN"), base_url: azure_pr_url(pr))
      result = azure.upsert_thread(summary.markdown, MARKER, status: THREAD_STATUS.fetch(summary.state, "active"))
      azure.set_status(state: AZURE_STATES.fetch(summary.state, "pending"), description: description(summary),
                       target_url: summary.url)
      notice("PR thread #{result}: #{pr['url'] || "PR ##{pr['number']}"}")
    end

    def azure_pr_url(pr)
      "#{AzureEnv.collection_base(@env)}#{AzureEnv.value(@env, 'SYSTEM_TEAMPROJECTID')}/_apis/git/repositories/" \
        "#{AzureEnv.value(@env, 'BUILD_REPOSITORY_ID')}/pullRequests/#{pr['number']}"
    end

    def azure_forbidden_message
      project = AzureEnv.value(@env, "SYSTEM_TEAMPROJECT") || "<project>"
      "skipped: the build service cannot write to this PR — grant \"Contribute to pull requests\" to " \
        "\"#{project} Build Service (#{azure_org})\""
    end

    def azure_org
      uri = URI.parse(AzureEnv.collection_base(@env).to_s)
      uri.host.to_s.end_with?("visualstudio.com") ? uri.host.split(".").first : uri.path.split("/").reject(&:empty?).first
    rescue URI::InvalidURIError
      nil
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

    # "**Raider: failed** - 2 failed, 148 passed, 3 skipped (1m 12s)" -> "2 failed, 148 passed, 3 skipped".
    # Falls back to a fixed text per state when the Markdown carries no headline counts.
    def description(summary)
      counts = headline_counts(summary.markdown)
      text = counts || FALLBACK_DESCRIPTIONS.fetch(summary.state, FALLBACK_DESCRIPTIONS["incomplete"])
      text[0, Comment::GithubClient::DESCRIPTION_LIMIT]
    end

    def headline_counts(markdown)
      line = markdown.to_s.lines.find { |l| l.include?("Raider:") }
      return nil unless line

      counts = line.scan(/\b\d+ (?:failed|passed|skipped|pending)\b/)
      counts.empty? ? nil : counts.join(", ")
    end

    def notice(message)
      @err.puts("[raider_reporter] #{message}")
      nil
    end
  end
end
