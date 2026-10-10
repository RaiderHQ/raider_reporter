# frozen_string_literal: true

require "open3"

module RaiderReporter
  class CiDetector
    def initialize(env: ENV, git: method(:git_command))
      @env = env
      @git = git
    end

    def ci
      return nil unless @env["GITHUB_ACTIONS"] == "true"

      run_id = @env["GITHUB_RUN_ID"]
      build_url = if @env["GITHUB_SERVER_URL"] && @env["GITHUB_REPOSITORY"] && run_id
                    "#{@env['GITHUB_SERVER_URL']}/#{@env['GITHUB_REPOSITORY']}/actions/runs/#{run_id}"
                  end
      { "provider" => "github_actions", "build_url" => build_url, "build_id" => run_id }.compact
    end

    def git
      info = { "branch" => branch, "commit_sha" => sha, "commit_message" => @git.call("log", "-1", "--pretty=%s") }
      info = info.compact
      info.empty? ? nil : info
    end

    private

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
