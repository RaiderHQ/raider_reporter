# frozen_string_literal: true

require "rspec/core"
require "raider_reporter"

module RaiderReporter
  module RSpec
    # Translates RSpec notifications into Collector calls. Every hook is guarded:
    # a reporting bug must never fail or crash the user's suite.
    class Formatter
      ::RSpec::Core::Formatters.register self,
                                         :start, :example_started, :example_passed,
                                         :example_failed, :example_pending, :close

      NON_TAG_KEYS = %i[pending skip].freeze
      MAX_MESSAGE = 10_000
      MAX_BACKTRACE = 50

      def initialize(output)
        @output = output
        @collector = RaiderReporter.start_collector!
      end

      def start(_notification)
        guard { @collector.start_run }
      end

      def example_started(_notification)
        guard { @collector.start_test }
      end

      def example_passed(notification)
        guard { record(notification.example, "passed") }
      end

      def example_failed(notification)
        guard { record(notification.example, "failed") }
      end

      def example_pending(notification)
        guard do
          example = notification.example
          record(example, example.metadata[:skip] ? "skipped" : "pending")
        end
      end

      def close(_notification)
        guard { RaiderReporter.finish!(@output) }
      end

      private

      def record(example, status)
        metadata = example.metadata
        execution = example.execution_result
        @collector.finish_test(
          identifier: example.id,
          full_name: example.full_description,
          file_path: metadata[:file_path].to_s.delete_prefix("./"),
          line_number: metadata[:line_number],
          status: status,
          duration_ms: ((execution.run_time || 0) * 1000).round,
          attempts: metadata.fetch(:retry_attempts, 0).to_i + 1,
          tags: metadata.select { |key, value| value == true && !NON_TAG_KEYS.include?(key) }.keys.map(&:to_s).sort,
          failure: status == "failed" ? failure_for(execution.exception) : nil
        )
      end

      def failure_for(exception)
        return nil unless exception

        backtrace = ::RSpec.configuration.backtrace_formatter.format_backtrace(exception.backtrace || [])
        Failure.new(
          message: exception.message.to_s[0, MAX_MESSAGE],
          exception_class: exception.class.name,
          backtrace: backtrace.first(MAX_BACKTRACE)
        )
      end

      def guard
        yield
      rescue StandardError => e
        RaiderReporter.warn("#{e.class}: #{e.message}")
      end
    end
  end
end
