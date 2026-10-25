# frozen_string_literal: true

require "raider_reporter/version"
require "raider_reporter/azure_env"
require "raider_reporter/ci_detector"
require "raider_reporter/comment/github_client"
require "raider_reporter/comment/azure_client"

module RaiderReporter
  # Posts the "raider/gate" status for `raider-reporter gate` (spec §5): a GitHub commit
  # status (PR head SHA on pull_request events, else GITHUB_SHA) or an Azure Repos PR
  # status (genre raider, name gate). Best effort: a failed post warns and never raises.
  class GateStatus
    CONTEXT = "raider/gate"
    AZURE_NAME = "gate"
    TIMEOUT = 10
    GITHUB_STATES = { pending: "pending", success: "success", failure: "failure", error: "error" }.freeze
    AZURE_STATES = { pending: "pending", success: "succeeded", failure: "failed", error: "error" }.freeze

    def initialize(env:, warn:)
      @env = env
      @warn = warn
      @provider = begin
        detect
      rescue StandardError
        nil
      end
    end

    def active?
      !@provider.nil?
    end

    # state: :pending, :success, :failure or :error.
    def post(state, description, target_url: nil)
      case @provider
      when :github
        github_client.set_status(@sha, state: GITHUB_STATES.fetch(state), target_url: target_url,
                                       description: description, context: CONTEXT)
      when :azure
        azure_client.set_status(state: AZURE_STATES.fetch(state), description: description, target_url: target_url,
                                name: AZURE_NAME)
      end
      nil
    rescue StandardError => e
      @warn.call("could not post the #{CONTEXT} status (#{e.class}: #{e.message})")
      nil
    end

    private

    def detect
      detector = CiDetector.new(env: @env, git: ->(*) {})
      if @env["GITHUB_ACTIONS"] == "true"
        @sha = detector.git&.dig("commit_sha")
        :github if [@env["GITHUB_TOKEN"], @env["GITHUB_REPOSITORY"], @sha].none? { |value| value.to_s.strip.empty? }
      elsif AzureEnv.azure?(@env)
        pr = detector.git&.dig("pr")
        @azure_url = pr && AzureEnv.pull_request_api_url(@env, pr["number"])
        :azure if @azure_url && AzureEnv.value(@env, "SYSTEM_ACCESSTOKEN")
      end
    end

    def github_client
      Comment::GithubClient.new(token: @env["GITHUB_TOKEN"], repository: @env["GITHUB_REPOSITORY"],
                                api_url: Comment::GithubClient.api_url(@env), timeout: TIMEOUT)
    end

    def azure_client
      Comment::AzureClient.new(token: AzureEnv.value(@env, "SYSTEM_ACCESSTOKEN"), base_url: @azure_url, timeout: TIMEOUT)
    end
  end
end
