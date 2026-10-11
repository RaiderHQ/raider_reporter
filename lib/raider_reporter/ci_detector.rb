# frozen_string_literal: true

require "open3"
require "raider_reporter/github_event"

module RaiderReporter
  class CiDetector
    PR_EVENTS = %w[pull_request pull_request_target].freeze

    def initialize(env: ENV, git: method(:git_command), event_reader: nil)
      @env = env
      @git = git
      @event_reader = event_reader || -> { GithubEvent.load(@env) }
    end

    def ci
      return nil unless @env["GITHUB_ACTIONS"] == "true"

      run_id = @env["GITHUB_RUN_ID"]
      build_url = if @env["GITHUB_SERVER_URL"] && @env["GITHUB_REPOSITORY"] && run_id
                    "#{@env['GITHUB_SERVER_URL']}/#{@env['GITHUB_REPOSITORY']}/actions/runs/#{run_id}"
                  end
      attempt = @env["GITHUB_RUN_ATTEMPT"].to_s.empty? ? "1" : @env["GITHUB_RUN_ATTEMPT"]
      repo = @env["GITHUB_REPOSITORY"]
      build_key = ("github_actions:#{repo}:#{run_id}:#{attempt}" if repo && run_id)
      { "provider" => "github_actions", "build_url" => build_url, "build_id" => run_id,
        "attempt" => attempt, "job" => @env["GITHUB_JOB"], "build_key" => build_key,
        "repository" => (repo unless repo.to_s.empty?) }.compact
    end

    def git
      pr = pull_request
      info = { "branch" => branch, "commit_sha" => pr ? pr["head_sha"] : sha, "commit_message" => commit_message(pr),
               "default_branch" => default_branch, "pr" => pr }
      info = info.compact
      info.empty? ? nil : info
    end

    private

    def event
      return @event if defined?(@event)

      loaded = begin
        @event_reader.call
      rescue StandardError
        nil
      end
      @event = loaded.is_a?(Hash) ? loaded : nil
    end

    def default_branch
      value = event&.dig("repository", "default_branch")
      value.is_a?(String) && !value.empty? ? value : nil
    rescue StandardError
      nil
    end

    def pull_request
      return nil unless event && PR_EVENTS.include?(@env["GITHUB_EVENT_NAME"])

      pr = event["pull_request"]
      return nil unless pr.is_a?(Hash)

      number = pr["number"] || event["number"]
      base = pr.dig("base", "ref")
      head = pr.dig("head", "ref")
      sha = pr.dig("head", "sha")
      return nil unless number.is_a?(Integer) && number >= 1
      return nil unless [base, head, sha].all? { |v| v.is_a?(String) && !v.empty? }

      { "number" => number, "base_branch" => base, "head_branch" => head, "head_sha" => sha }
    rescue StandardError
      nil
    end

    # On a PR, GitHub checks out a synthetic merge commit; its message is not the author's.
    def commit_message(pr)
      if pr && merge_commit?
        message = @git.call("log", "-1", "--format=%s", "HEAD^2")
        return message unless message.to_s.empty?
      end
      @git.call("log", "-1", "--pretty=%s")
    end

    def merge_commit?
      @git.call("rev-list", "--parents", "-n", "1", "HEAD").to_s.split.size == 3
    end

    def branch
      head_ref = @env["GITHUB_HEAD_REF"].to_s
      return head_ref unless head_ref.empty?

      return @env["GITHUB_REF_NAME"] if @env["GITHUB_REF_NAME"]

      local = @git.call("rev-parse", "--abbrev-ref", "HEAD")
      local == "HEAD" ? nil : local # "HEAD" means detached, not a branch name
    end

    def sha
      @env["GITHUB_SHA"] || @git.call("rev-parse", "HEAD")
    end

    def git_command(*args)
      out, _err, status = Open3.capture3("git", *args)
      status.success? ? out.strip : nil
    rescue StandardError
      nil
    end
  end
end
