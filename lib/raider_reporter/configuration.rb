# frozen_string_literal: true

require "raider_reporter/azure_env"

module RaiderReporter
  class Configuration
    attr_accessor :token, :endpoint, :output_dir, :clean_output_dir, :html_report, :environment, :max_attachment_bytes

    def initialize(env = ENV)
      @token = AzureEnv.value(env, "RAIDER_TOKEN")
      @endpoint = AzureEnv.value(env, "RAIDER_ENDPOINT")
      @output_dir = "raider-results"
      @clean_output_dir = true
      @html_report = true
      @environment = {}
      @max_attachment_bytes = 5 * 1024 * 1024
    end

    def upload?
      present?(token) && present?(endpoint)
    end

    private

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end
  end
end
