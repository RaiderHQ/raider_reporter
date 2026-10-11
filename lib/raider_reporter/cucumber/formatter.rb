# frozen_string_literal: true

require "pathname"
require "cucumber"
require "cucumber/formatter/ast_lookup"
require "raider_reporter"
require "raider_reporter/text"

module RaiderReporter
  module Cucumber
    # Translates Cucumber events into Collector calls. Every handler is guarded:
    # a reporting bug must never fail or crash the user's run. The formatter
    # writes nothing to its IO; the report goes to RaiderReporter's own writers.
    #
    # Inside this namespace `Cucumber` means RaiderReporter::Cucumber, so the
    # gem's constants are always written ::Cucumber.
    class Formatter
      STATUSES = {
        passed: "passed", failed: "failed", ambiguous: "failed",
        pending: "pending", undefined: "pending", skipped: "skipped"
      }.freeze

      def initialize(config)
        @buffer = {}
        @attempt = nil
        guard { setup(config) }
      end

      private

      def setup(config)
        @ast = ::Cucumber::Formatter::AstLookup.new(config)
        @collector = RaiderReporter.start_collector!
        config.on_event(:test_run_started) { |_event| guard { @collector.start_run } }
        config.on_event(:test_case_started) { |event| guard { case_started(event.test_case) } }
        config.on_event(:test_step_finished) { |event| guard { step_finished(event.test_step, event.result) } }
        config.on_event(:test_case_finished) { |event| guard { case_finished(event.test_case, event.result) } }
        config.on_event(:test_run_finished) { |_event| guard { run_finished } }
      end

      def case_started(test_case)
        @collector.start_test
        @attempt = { test_case: test_case }
      end

      # The first non-passed step explains why the scenario did not pass.
      def step_finished(test_step, result)
        return unless @attempt
        return if @attempt[:problem] || result.passed?

        @attempt[:problem] = { step: test_step, result: result }
      end

      def case_finished(test_case, result)
        problem = @attempt && @attempt[:problem]
        @attempt = nil
        status = STATUSES.fetch(result.to_sym, "pending")
        fields = identity_for(test_case).merge(
          status: status,
          duration_ms: duration_ms(result),
          attempts: 1,
          failure: status == "failed" ? failure_for(problem, result, test_case) : nil
        )
        @buffer[fields[:identifier]] = fields
      end

      def run_finished
        @buffer.each_value { |fields| @collector.finish_test(**fields) }
        @buffer.clear
        RaiderReporter.finish!($stderr)
      end

      def identity_for(test_case)
        file_path = relative_path(test_case.location.file)
        line_number = test_case.location.lines.max
        {
          file_path: file_path,
          line_number: line_number,
          full_name: Text.utf8(full_name(test_case)),
          identifier: "#{file_path}:#{line_number}",
          tags: test_case.tags.map { |tag| tag.name.to_s.delete_prefix("@") }.uniq.sort
        }
      end

      def full_name(test_case)
        feature = @ast.gherkin_document(test_case.location.file)&.feature
        source = @ast.scenario_source(test_case)
        name = scenario_name(source, test_case)
        feature ? "#{feature.name}: #{name}" : name
      end

      def scenario_name(source, test_case)
        case source&.type
        when :ScenarioOutline
          examples = source.examples
          label = examples.name.to_s.strip.empty? ? "Examples" : examples.name.strip
          row = examples.table_body.index { |candidate| candidate.equal?(source.row) } || 0
          "#{source.scenario_outline.name} (#{label}, row #{row + 1})"
        when :Scenario
          source.scenario.name
        else
          test_case.name
        end
      end

      # step_info is { step:, result: } for the first non-passed step, if any.
      def failure_for(step_info, result, test_case)
        exception = result.respond_to?(:exception) ? result.exception : nil
        exception ||= step_info && step_info[:result].respond_to?(:exception) ? step_info[:result].exception : nil
        return nil unless exception

        Failure.new(
          message: Text.utf8("#{step_label(step_info, test_case)}\n\n#{exception.message}")[0, Text::MAX_MESSAGE],
          exception_class: Text.utf8(exception.class.name),
          backtrace: (exception.backtrace || []).first(Text::MAX_BACKTRACE).map { |line| Text.utf8(line) }
        )
      end

      def step_label(step_info, test_case)
        return "Step" unless step_info

        test_step = step_info[:step]
        location = "(#{relative_path(test_step.location.file)}:#{test_step.location.lines.min})"
        if test_step.hook?
          "#{hook_kind(test_step, test_case)} hook #{location}"
        else
          "#{@ast.step_source(test_step).step.keyword}#{test_step.text} #{location}"
        end
      end

      # A hook with a real step before it runs after the scenario started.
      def hook_kind(test_step, test_case)
        steps = test_case.test_steps
        index = steps.index { |candidate| candidate.equal?(test_step) }
        index && steps.first(index).any? { |candidate| !candidate.hook? } ? "After" : "Before"
      end

      def duration_ms(result)
        (result.duration.nanoseconds / 1_000_000.0).round
      rescue StandardError
        0
      end

      def relative_path(path)
        absolute = Pathname.new(File.expand_path(path.to_s, Dir.pwd))
        relative = absolute.relative_path_from(Pathname.new(Dir.pwd)).to_s
        relative.start_with?("..") ? path.to_s.delete_prefix("./") : relative
      end

      def guard
        yield
      rescue StandardError => e
        RaiderReporter.warn("#{e.class}: #{e.message}")
      end
    end
  end
end
