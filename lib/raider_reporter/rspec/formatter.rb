# frozen_string_literal: true

require "rspec/core"
require "raider_reporter"
require "raider_reporter/text"

module RaiderReporter
  module RSpec
    # Translates RSpec notifications into Collector calls. Every hook is guarded:
    # a reporting bug must never fail or crash the user's suite.
    class Formatter
      ::RSpec::Core::Formatters.register self,
                                         :start, :example_started, :example_passed,
                                         :example_failed, :example_pending, :close

      NON_TAG_KEYS = %i[pending skip].freeze
      MAX_MESSAGE = Text::MAX_MESSAGE
      MAX_BACKTRACE = Text::MAX_BACKTRACE

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
        guard { RaiderReporter.finish! }
      end

      private

      def record(example, status)
        metadata = example.metadata
        execution = example.execution_result
        file_path = metadata[:file_path].to_s.delete_prefix("./")
        full_name = utf8(example.full_description)
        failure = status == "failed" ? failure_for(execution.exception) : nil
        # The key is computed from the payload's own file_path and full_name (spec §4.2).
        status = "quarantined" if status == "failed" && @collector.quarantined?(file_path, full_name)
        @collector.finish_test(
          identifier: example.id,
          full_name: full_name,
          file_path: file_path,
          line_number: metadata[:line_number],
          status: status,
          duration_ms: ((execution.run_time || 0) * 1000).round,
          attempts: metadata.fetch(:retry_attempts, 0).to_i + 1,
          tags: metadata.select { |key, value| value == true && !NON_TAG_KEYS.include?(key) }.keys.map(&:to_s).sort,
          failure: failure
        )
      end

      def failure_for(exception)
        return nil unless exception

        backtrace = ::RSpec.configuration.backtrace_formatter.format_backtrace(exception.backtrace || [])
        Failure.new(
          message: utf8(exception.message)[0, MAX_MESSAGE],
          exception_class: utf8(exception.class.name),
          backtrace: backtrace.first(MAX_BACKTRACE).map { |line| utf8(line) },
          app_frame: app_frame_for(exception)
        )
      end

      # From the raw backtrace: RSpec's formatter strips gem and project-support frames.
      # MultipleExceptionError (aggregate_failures) has no backtrace of its own.
      def raw_backtrace(exception)
        return exception.backtrace if exception.backtrace
        return nil unless exception.respond_to?(:all_exceptions)

        exception.all_exceptions.first&.backtrace
      end

      def app_frame_for(exception)
        AppFrame.from(raw_backtrace(exception), root: RaiderReporter.project_root || Dir.pwd)
      rescue StandardError
        nil
      end

      def utf8(value)
        Text.utf8(value)
      end

      def guard
        yield
      rescue StandardError => e
        RaiderReporter.warn("#{e.class}: #{e.message}")
      end
    end
  end
end
