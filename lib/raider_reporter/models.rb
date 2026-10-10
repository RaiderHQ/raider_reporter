# frozen_string_literal: true

module RaiderReporter
  SCHEMA_VERSION = 1
  STATUSES = %w[passed failed pending skipped].freeze

  Failure = Data.define(:message, :exception_class, :backtrace)
  Attachment = Data.define(:name, :source_path, :content_type)
  TestResult = Data.define(
    :identifier, :full_name, :file_path, :line_number, :status,
    :duration_ms, :attempts, :tags, :failure, :attachments
  )
  Run = Data.define(:client_run_id, :started_at, :finished_at, :ci, :git, :environment, :results)
end
