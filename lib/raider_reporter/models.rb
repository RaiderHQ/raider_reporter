# frozen_string_literal: true

module RaiderReporter
  SCHEMA_VERSION = 2
  STATUSES = %w[passed failed pending skipped quarantined].freeze

  Failure = Data.define(:message, :exception_class, :backtrace, :app_frame) do
    def initialize(message:, exception_class:, backtrace:, app_frame: nil)
      super
    end
  end
  # attempt: which try of the test produced it, when the caller knows (traces); nil otherwise.
  Attachment = Data.define(:name, :source_path, :content_type, :attempt) do
    def initialize(name:, source_path:, content_type:, attempt: nil)
      super
    end
  end
  # steps: the recorded steps of a failed test and the one it failed at (FailedSteps); nil otherwise.
  # comparisons: the screenshot comparisons made during the test (Comparison); nil when there were none.
  TestResult = Data.define(
    :identifier, :full_name, :file_path, :line_number, :status,
    :duration_ms, :attempts, :tags, :failure, :attachments, :steps, :comparisons
  ) do
    def initialize(steps: nil, comparisons: nil, **fields)
      super
    end
  end
  COMPARISON_STATUSES = %w[passed failed created updated].freeze
  # One screenshot compared with its baseline. Images travel as attachments named comparison:<name>:<kind>.
  Comparison = Data.define(
    :name, :status, :baseline, :diff_pixels, :diff_ratio, :threshold,
    :max_diff_pixels, :max_diff_ratio, :expected_size, :actual_size
  ) do
    def to_h
      members.to_h { |member| [member.to_s, public_send(member)] }
    end
  end
  Run = Data.define(:client_run_id, :started_at, :finished_at, :ci, :git, :environment, :results, :shard)
end
