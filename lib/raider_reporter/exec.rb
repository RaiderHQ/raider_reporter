# frozen_string_literal: true

require "tmpdir"
require "raider_reporter/exec_summary"

module RaiderReporter
  # `raider-reporter exec -- <command…>` (spec §4.5). Runs the command without a
  # shell, streams its output, and keeps its exit code, except that exit 1 becomes 0
  # when the summary says every counted failure was quarantined and nothing else
  # went wrong. Anything uncertain keeps the command's code.
  class Exec
    USAGE = <<~TEXT
      Usage: raider-reporter exec -- <command> [args...]

      Runs the command (no shell) and exits with its status. When the command exits 1, every failure it
      counted was quarantined in Raider and nothing else went wrong, exits 0 instead and says so on stderr.
      Quarantine needs RAIDER_QUARANTINE=1 with RAIDER_TOKEN and RAIDER_ENDPOINT.
    TEXT
    USAGE_ERROR = 2
    NOT_STARTED = 127
    # A terminal Ctrl-C already reaches the command through the process group.
    FORWARDED = %w[TERM HUP].freeze
    IGNORED = %w[INT].freeze

    def self.quarantined_only?(summary)
      return false unless summary

      failures = summary["framework_failures"]
      failures.positive? && failures == summary["quarantined"] && summary["errors_outside_tests"].zero?
    end

    def initialize(command, err: $stderr)
      @command = command
      @err = err
      @pid = nil
      @code = nil
    end

    def run
      if @command.empty?
        @err.puts(USAGE)
        return USAGE_ERROR
      end

      Dir.mktmpdir("raider-exec") { |dir| run_with(File.join(dir, "summary.json")) }
    rescue StandardError => e
      @err.puts("[raider_reporter] exec failed: #{e.class}: #{e.message}")
      @code || 1
    end

    private

    def run_with(summary_path)
      previous = install_traps
      @pid = start(summary_path)
      return NOT_STARTED unless @pid

      @code = wait
      summary = ExecSummary.read(summary_path)
      return @code unless @code == 1 && self.class.quarantined_only?(summary)

      @err.puts("raider-reporter: #{summary['quarantined']} quarantined failure(s) did not fail the build")
      0
    ensure
      previous&.each { |signal, handler| trap(signal, handler || "DEFAULT") }
    end

    def start(summary_path)
      program, *args = @command
      Process.spawn({ ExecSummary::ENV_NAME => summary_path }, [program, program], *args)
    rescue SystemCallError => e
      @err.puts("[raider_reporter] exec: cannot run #{program}: #{e.message}")
      nil
    end

    def wait
      _, status = Process.wait2(@pid)
      status.signaled? ? 128 + status.termsig : status.exitstatus
    end

    # Installed before spawning so a signal that arrives early is not lost. A Ruby
    # handler (not "IGNORE") is reset to the default in the child by exec(2).
    def install_traps
      forwarded = FORWARDED.to_h do |signal|
        handler = trap(signal) do
          Process.kill(signal, @pid) if @pid
        rescue SystemCallError
          nil
        end
        [signal, handler]
      end
      forwarded.merge(IGNORED.to_h { |signal| [signal, trap(signal) {}] })
    end
  end
end
