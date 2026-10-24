# frozen_string_literal: true

require "raider_reporter/azure_env"

module RaiderReporter
  class Configuration
    TRUTHY = %w[1 true].freeze

    attr_accessor :token, :endpoint, :output_dir, :clean_output_dir, :html_report, :environment, :max_attachment_bytes,
                  :quarantine

    def initialize(env = ENV)
      @token = AzureEnv.value(env, "RAIDER_TOKEN")
      @endpoint = AzureEnv.value(env, "RAIDER_ENDPOINT")
      @output_dir = "raider-results"
      @clean_output_dir = true
      @html_report = true
      @environment = {}
      @max_attachment_bytes = 5 * 1024 * 1024
      @quarantine = TRUTHY.include?(AzureEnv.value(env, "RAIDER_QUARANTINE").to_s.downcase)
    end

    def upload?
      present?(token) && present?(endpoint)
    end

    # Quarantine needs the server: on, with both token and endpoint (spec §4.1).
    def quarantine?
      quarantine == true && upload?
    end

    private

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
  end
end
