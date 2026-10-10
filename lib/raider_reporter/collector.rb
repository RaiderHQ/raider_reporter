# frozen_string_literal: true

require "securerandom"

module RaiderReporter
  # Accumulates one suite run. Framework formatters call it; writers read the Run it returns.
  class Collector
    def initialize(max_attachment_bytes:, warn:, clock: -> { Time.now.utc }, uuid: -> { SecureRandom.uuid })
      @max_attachment_bytes = max_attachment_bytes
      @warn = warn
      @clock = clock
      @uuid = uuid
      @results = []
      @pending_attachments = nil
    end

    def start_run
      @started_at = @clock.call
      @results = []
    end

    def start_test
      @pending_attachments = []
    end

    def in_test?
      !@pending_attachments.nil?
    end

    def attach(attachment)
      return false unless in_test?

      @pending_attachments << attachment
      true
    end

    def finish_test(**fields)
      result = TestResult.new(**fields, attachments: @pending_attachments || [])
      @pending_attachments = nil
      @results << result
      result
    end

    def finish_run(ci:, git:, environment:)
      Run.new(
        client_run_id: @uuid.call, started_at: @started_at, finished_at: @clock.call,
        ci: ci, git: git, environment: environment,
        results: @results.map { |r| r.with(attachments: r.attachments.select { |a| keep?(a) }) }
      )
    end

    private

    def keep?(attachment)
      path = attachment.source_path
      unless File.file?(path)
        @warn.call("attachment #{path} no longer exists; skipped")
        return false
      end
      if File.size(path) > @max_attachment_bytes
        @warn.call("attachment #{path} is larger than #{@max_attachment_bytes} bytes; skipped")
        return false
      end
      true
    end
  end
end
