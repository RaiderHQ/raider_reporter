# frozen_string_literal: true

module RaiderReporter
  class Configuration
    attr_accessor :token, :endpoint, :output_dir, :clean_output_dir, :environment, :max_attachment_bytes

    def initialize(env = ENV)
      @token = env["RAIDER_TOKEN"]
      @endpoint = env["RAIDER_ENDPOINT"]
      @output_dir = "raider-results"
      @clean_output_dir = true
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
