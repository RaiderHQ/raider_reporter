# frozen_string_literal: true

require "json"
require "fileutils"
require "raider_reporter/text"
require "raider_reporter/shard_detector"

module RaiderReporter
  # Live NDJSON events for the Raider desktop app, one file per worker. On only
  # when RAIDER_EVENTS_DIR is set. A write error switches it off after one warning.
  class EventStream
    VERSION = 1
    # Owner-only, and never through a symlink someone planted in the events dir.
    OPEN_FLAGS = File::WRONLY | File::APPEND | File::CREAT | (defined?(File::NOFOLLOW) ? File::NOFOLLOW : 0)

    def self.open(warn:, env: ENV, shard: ShardDetector.new.shard)
      dir = env["RAIDER_EVENTS_DIR"].to_s
      return nil if dir.empty?

      FileUtils.mkdir_p(dir)
      file = File.open(File.join(dir, "worker-#{shard ? shard["index"] : 1}.ndjson"), OPEN_FLAGS, 0o600)
      file.sync = true
      new(file, warn: warn)
    rescue StandardError => e
      warn.call("events stream disabled: #{e.class}: #{e.message}")
      nil
    end

    def initialize(file, warn:)
      @file = file
      @warn = warn
    end

    def plan(tests)
      emit("plan", tests: tests.map { |test| test_fields(test) })
    end

    def started(test)
      emit("started", **test_fields(test))
    end

    def finished(id:, status:, duration_ms:, attempts:)
      emit("finished", id: cap(id), status: status, duration_ms: duration_ms, attempts: attempts)
    end

    def done
      emit("done")
    end

    def close
      @file&.close
    rescue StandardError
      nil
    ensure
      @file = nil
    end

    private

    def test_fields(test)
      { id: cap(test[:id]), file: cap(test[:file]), line: test[:line],
        description: cap(test[:description]), full_name: cap(test[:full_name]) }
    end

    def cap(value)
      Text.utf8(value)[0, Text::MAX_MESSAGE]
    end

    def emit(type, **fields)
      return unless @file

      @file.write("#{JSON.generate({ v: VERSION, type: type }.merge(fields))}\n")
    rescue StandardError => e
      @warn.call("events stream disabled: #{e.class}: #{e.message}")
      close
    end
  end
end
