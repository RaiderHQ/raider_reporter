# frozen_string_literal: true

require "json"

module RaiderReporter
  # The file `raider-reporter exec` reads to decide its exit code (spec §4.4). One
  # process writes it. A second writer (several processes under one exec) turns it
  # into a conflict, which exec treats as no summary, so the command's code wins.
  module ExecSummary
    ENV_NAME = "RAIDER_EXEC_SUMMARY"
    KEYS = %w[framework_failures quarantined errors_outside_tests].freeze
    CONFLICT = { "conflict" => true }.freeze

    module_function

    def write(path, framework_failures:, quarantined:, errors_outside_tests:, pid: Process.pid)
      summary = { "framework_failures" => framework_failures, "quarantined" => quarantined,
                  "errors_outside_tests" => errors_outside_tests, "pid" => pid }
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        existing = file.read
        same_writer = existing.empty? || parse(existing)&.fetch("pid", nil) == pid
        file.rewind
        file.truncate(0)
        file.write(JSON.generate(same_writer ? summary : CONFLICT))
      end
    end

    def read(path)
      data = parse(File.read(path))
      return nil if data.nil? || data.key?("conflict")
      return nil unless KEYS.all? { |key| data[key].is_a?(Integer) && !data[key].negative? }

      data.slice(*KEYS)
    rescue SystemCallError, IOError
      nil
    end

    def parse(text)
      data = JSON.parse(text)
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError
      nil
    end
  end
end
