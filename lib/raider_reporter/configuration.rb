# frozen_string_literal: true

require "raider_reporter/azure_env"
require "raider_reporter/content_types"

module RaiderReporter
  class Configuration
    TRUTHY = %w[1 true].freeze
    DEFAULT_MAX_VIDEO_BYTES = 50 * 1024 * 1024
    DEFAULT_MAX_TRACE_BYTES = 25 * 1024 * 1024

    attr_accessor :token, :endpoint, :output_dir, :clean_output_dir, :html_report, :environment, :max_attachment_bytes,
                  :max_video_bytes, :max_trace_bytes, :quarantine, :exec_summary_path

    def initialize(env = ENV)
      @token = AzureEnv.value(env, "RAIDER_TOKEN")
      @endpoint = AzureEnv.value(env, "RAIDER_ENDPOINT")
      @output_dir = "raider-results"
      @clean_output_dir = true
      @html_report = true
      @environment = {}
      @max_attachment_bytes = 5 * 1024 * 1024
      @max_video_bytes = DEFAULT_MAX_VIDEO_BYTES
      @max_trace_bytes = DEFAULT_MAX_TRACE_BYTES
      @quarantine = TRUTHY.include?(AzureEnv.value(env, "RAIDER_QUARANTINE").to_s.downcase)
      @exec_summary_path = AzureEnv.value(env, "RAIDER_EXEC_SUMMARY")
    end

    # The size cap for one attachment of this content type.
    def attachment_limit(content_type)
      return max_trace_bytes if ContentTypes.trace?(content_type)
      return max_video_bytes if ContentTypes.video?(content_type)

      max_attachment_bytes
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
