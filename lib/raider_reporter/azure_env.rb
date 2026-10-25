# frozen_string_literal: true

module RaiderReporter
  # Reads Azure Pipelines variables. An undefined macro is left literal by Azure
  # ("$(System.AccessToken)"), so such values count as missing.
  module AzureEnv
    MACRO = /\A\$\(.+\)\z/

    module_function

    def value(env, name)
      raw = env[name].to_s.strip
      raw.empty? || raw.match?(MACRO) ? nil : raw
    end

    def azure?(env)
      env["GITHUB_ACTIONS"] != "true" && value(env, "TF_BUILD")&.casecmp?("true") == true
    end

    def collection_base(env)
      uri = value(env, "SYSTEM_COLLECTIONURI")
      uri && "#{uri.sub(%r{/+\z}, '')}/"
    end

    def azure_repos_pr?(env)
      value(env, "BUILD_REASON") == "PullRequest" && value(env, "BUILD_REPOSITORY_PROVIDER") == "TfsGit"
    end

    # The REST base of a pull request (threads, statuses), or nil when a part is unknown.
    def pull_request_api_url(env, number)
      base = collection_base(env)
      project = value(env, "SYSTEM_TEAMPROJECTID")
      repo = value(env, "BUILD_REPOSITORY_ID")
      return nil unless base && project && repo && number

      "#{base}#{project}/_apis/git/repositories/#{repo}/pullRequests/#{number}"
    end

    def strip_heads(ref)
      return nil if ref.nil?
      return ref.delete_prefix("refs/heads/") if ref.start_with?("refs/heads/")

      ref.start_with?("refs/") ? nil : ref
    end
  end
end
