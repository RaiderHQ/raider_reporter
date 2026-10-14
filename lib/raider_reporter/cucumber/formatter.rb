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

      # Passed to the World's `attach`; reports an existing file as an attachment.
      module AttachCapture
        # Takes whatever Cucumber passes (file, media_type, filename, and any
        # argument a later release adds) and forwards it untouched.
        ruby2_keywords def attach(*args, &block)
          result = super
          Formatter.record_attachment(args[0], args[1])
          result
        end
      end

      @claimed = []

      class << self
        # One listener per run, whether it arrives as a --format or as a plugin.
        # Cucumber copies the configuration for --out, but the event bus is shared.
        def claim(config)
          bus = config.event_bus
          return false if @claimed.any? { |claimed| claimed.equal?(bus) }

          @claimed << bus
          true
        end

        # Inline text, IO objects and missing paths are ignored: only a file that
        # exists can be copied. Never raises into the user's step.
        def record_attachment(file, media_type)
          # `log` is attach with this media type; a logged message is not a file.
          return if media_type.to_s.start_with?("text/x.cucumber.log")

          file = file.to_path if file.respond_to?(:to_path)
          return unless file.is_a?(String) && RaiderReporter.collector&.in_test? && File.file?(file)

          RaiderReporter.attach(File.basename(file), file, type: media_type)
        rescue StandardError => e
          RaiderReporter.warn("#{e.class}: #{e.message}")
        end

        # Called when the run ends, so the list does not outlive the run.
        def release(config)
          bus = config.event_bus
          @claimed.reject! { |claimed| claimed.equal?(bus) }
          RaiderReporter.dry_run = false
        end

        # Cucumber hands steps a World, not the formatter, so `attach` is observed
        # by prepending to ProtoWorld. Installed once, at the first formatter.
        # Event-bus alternatives were checked in cucumber 9.2.1, 10.2.0 and 11.1.1:
        # there is no :attach_called event before 11, and even there (and in the
        # :envelope attachment message) a file path has already been read into
        # bytes with no name, so the basename the report needs is only available
        # in ProtoWorld#attach, which exists unchanged in all three versions.
        def capture_attach
          return if @capturing

          ::Cucumber::Glue::ProtoWorld.prepend(AttachCapture)
          @capturing = true
        end
      end

      def initialize(config)
        @buffer = {}
        @attempts = Hash.new(0)
        @attempt = nil
        guard { setup(config) if self.class.claim(config) }
      end

      private

      def setup(config)
        @config = config
        @ast = ::Cucumber::Formatter::AstLookup.new(config)
        @collector = RaiderReporter.start_collector!
        RaiderReporter.dry_run = config.dry_run?
        config.on_event(:test_run_started) { |_event| guard { @collector.start_run } }
        config.on_event(:test_case_started) { |event| guard { case_started(event.test_case) } }
        config.on_event(:test_step_finished) { |event| guard { step_finished(event.test_step, event.result) } }
        config.on_event(:test_case_finished) { |event| guard { case_finished(event.test_case, event.result) } }
        config.on_event(:test_run_finished) { |_event| guard { run_finished } }
        # Last, and on its own: a broken attach hook may only lose attachments.
        safely(nil) { self.class.capture_attach }
      end

      # Every attempt starts with an empty attachment list.
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
        # Always buffer: a lookup problem may lose detail, never the scenario.
        failure = status == "failed" ? safely(nil) { failure_for(problem, result, test_case) } : nil
        fields = identity_for(test_case)
        key = "#{test_case.location}|#{test_case.name}"
        @attempts[key] += 1
        # The newest attempt replaces the older one, taking its attachments with it.
        @buffer[key] = @collector.build_test(
          **fields, status: status, duration_ms: duration_ms(result), attempts: @attempts[key], failure: failure
        )
      end

      def run_finished
        @buffer.each_value { |result| @collector.add_result(result) }
        @buffer.clear
        RaiderReporter.finish!($stderr)
      ensure
        self.class.release(@config)
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
        safely(test_case.name) do
          feature = @ast.gherkin_document(test_case.location.file)&.feature
          name = scenario_name(@ast.scenario_source(test_case))
          next test_case.name unless name

          feature ? "#{feature.name}: #{name}" : name
        end
      end

      # nil when the scenario cannot be located in the AST.
      def scenario_name(source)
        case source&.type
        when :ScenarioOutline
          examples = source.examples
          row = examples.table_body.index { |candidate| candidate.location.line == source.row.location.line }
          row && "#{source.scenario_outline.name} (#{examples_label(source)}, row #{row + 1})"
        when :Scenario
          source.scenario.name
        end
      end

      # "Examples" or the table's name. When several tables of one outline share a
      # label (two unnamed ones, say), each gets its 1-based position among them,
      # so rows of different tables never collide on full_name.
      def examples_label(source)
        tables = source.scenario_outline.examples
        label = examples_name(source.examples)
        same = tables.select { |table| examples_name(table) == label }
        return label if same.size < 2

        "#{label} #{same.index { |table| table.equal?(source.examples) || table.location.line == source.examples.location.line } + 1}"
      end

      def examples_name(table)
        table.name.to_s.strip.empty? ? "Examples" : table.name.strip
      end

      # step_info is { step:, result: } for the first non-passed step, if any.
      def failure_for(step_info, result, test_case)
        exception = result.respond_to?(:exception) ? result.exception : nil
        exception ||= step_info && step_info[:result].respond_to?(:exception) ? step_info[:result].exception : nil
        return nil unless exception

        Failure.new(
          message: Text.utf8("#{step_label(step_info, test_case)}\n\n#{exception.message}")[0, Text::MAX_MESSAGE],
          exception_class: Text.utf8(exception.class.name),
          backtrace: (exception.backtrace || []).first(Text::MAX_BACKTRACE).map { |line| Text.utf8(line) },
          app_frame: app_frame_for(exception)
        )
      end

      def app_frame_for(exception)
        AppFrame.from(exception.backtrace, root: RaiderReporter.project_root || Dir.pwd)
      rescue StandardError
        nil
      end

      def step_label(step_info, test_case)
        return "Step" unless step_info

        test_step = step_info[:step]
        location = "(#{relative_path(test_step.location.file)}:#{test_step.location.lines.min})"
        if test_step.hook?
          "#{hook_kind(test_step, test_case)} hook #{location}"
        else
          "#{step_keyword(test_step)}#{test_step.text} #{location}"
        end
      end

      def step_keyword(test_step)
        safely("") { @ast.step_source(test_step).step.keyword.to_s }
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
      rescue ArgumentError
        # Windows: a path on another drive has no relative form.
        path.to_s.delete_prefix("./")
      end

      def safely(fallback)
        yield
      rescue StandardError => e
        RaiderReporter.warn("#{e.class}: #{e.message}")
        fallback
      end

      def guard
        yield
      rescue StandardError => e
        RaiderReporter.warn("#{e.class}: #{e.message}")
      end
    end
  end
end
