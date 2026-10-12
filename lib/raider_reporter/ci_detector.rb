# frozen_string_literal: true

require "erb"
require "open3"
require "raider_reporter/azure_env"
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
      return azure_ci if AzureEnv.azure?(@env)
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

    def azure_ci
      v = ->(name) { AzureEnv.value(@env, name) }
      base = AzureEnv.collection_base(@env)
      project = v.("SYSTEM_TEAMPROJECT")
      build_id = v.("BUILD_BUILDID")
      attempt = v.("SYSTEM_STAGEATTEMPT") || "1"
      build_url = ("#{base}#{ERB::Util.url_encode(project)}/_build/results?buildId=#{build_id}" if base && project && build_id)
      ids = [base&.sub(%r{\Ahttps?://}i, "")&.chomp("/"), v.("SYSTEM_TEAMPROJECTID"), v.("BUILD_REPOSITORY_ID")]
      build_key = ("azure_pipelines:#{ids.join('/')}:#{build_id}:#{attempt}" if ids.all? && build_id)
      repo = v.("BUILD_REPOSITORY_NAME")
      { "provider" => "azure_pipelines", "build_url" => build_url, "build_id" => build_id, "attempt" => attempt,
        "job" => v.("SYSTEM_JOBDISPLAYNAME"), "build_key" => build_key,
        "repository" => (project && repo ? "#{project}/#{repo}" : nil) }.compact
    end

    def azure_pull_request
      return nil unless AzureEnv.azure_repos_pr?(@env)

      v = ->(name) { AzureEnv.value(@env, name) }
      number = Integer(v.("SYSTEM_PULLREQUEST_PULLREQUESTID").to_s, exception: false)
      base = AzureEnv.strip_heads(v.("SYSTEM_PULLREQUEST_TARGETBRANCH"))
      head = AzureEnv.strip_heads(v.("SYSTEM_PULLREQUEST_SOURCEBRANCH"))
      sha = v.("SYSTEM_PULLREQUEST_SOURCECOMMITID")
      return nil unless number&.positive? && [base, head, sha].all? { |s| s.is_a?(String) && !s.empty? }

      collection = AzureEnv.collection_base(@env)
      project = v.("SYSTEM_TEAMPROJECT")
      repo = v.("BUILD_REPOSITORY_NAME")
      url = if collection && project && repo
              "#{collection}#{ERB::Util.url_encode(project)}/_git/#{ERB::Util.url_encode(repo)}/pullrequest/#{number}"
            end
      { "number" => number, "base_branch" => base, "head_branch" => head, "head_sha" => sha, "url" => url }.compact
    end

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
      return azure_pull_request if AzureEnv.azure?(@env)
      return nil unless event && PR_EVENTS.include?(@env["GITHUB_EVENT_NAME"])

      pr = event["pull_request"]
      return nil unless pr.is_a?(Hash)

      number = pr["number"] || event["number"]
      base = pr.dig("base", "ref")
      head = pr.dig("head", "ref")
      sha = pr.dig("head", "sha")
      return nil unless number.is_a?(Integer) && number >= 1
      return nil unless [base, head, sha].all? { |v| v.is_a?(String) && !v.empty? }

      server = @env["GITHUB_SERVER_URL"].to_s
      repo = @env["GITHUB_REPOSITORY"].to_s
      url = ("#{server}/#{repo}/pull/#{number}" unless server.empty? || repo.empty?)
      { "number" => number, "base_branch" => base, "head_branch" => head, "head_sha" => sha, "url" => url }.compact
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
      return azure_branch if AzureEnv.azure?(@env)

      head_ref = @env["GITHUB_HEAD_REF"].to_s
      return head_ref unless head_ref.empty?

      return @env["GITHUB_REF_NAME"] if @env["GITHUB_REF_NAME"]

      local = @git.call("rev-parse", "--abbrev-ref", "HEAD")
      local == "HEAD" ? nil : local # "HEAD" means detached, not a branch name
    end

    def azure_branch
      pr = pull_request
      name = pr ? pr["head_branch"] : AzureEnv.strip_heads(AzureEnv.value(@env, "BUILD_SOURCEBRANCH"))
      return name if name

      local = @git.call("rev-parse", "--abbrev-ref", "HEAD")
      local == "HEAD" ? nil : local
    end

    def sha
      return AzureEnv.value(@env, "BUILD_SOURCEVERSION") || @git.call("rev-parse", "HEAD") if AzureEnv.azure?(@env)

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
