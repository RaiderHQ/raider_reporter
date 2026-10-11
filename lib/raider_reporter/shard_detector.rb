# frozen_string_literal: true

module RaiderReporter
  # Identifies which slice of a parallel suite this process is.
  class ShardDetector
    def initialize(env: ENV, job: nil)
      @env = env
      @job = job.to_s.strip.empty? ? nil : job.to_s
    end

    def shard
      index, total = explicit || parallel_tests
      return nil unless index

      { "index" => index, "total" => total, "label" => "#{@job || "local"}##{index}" }
    end

    private

    def explicit
      index = positive(@env["RAIDER_SHARD_INDEX"])
      [index, positive(@env["RAIDER_SHARD_TOTAL"])] if index
    end

    def parallel_tests
      return nil unless @env.key?("TEST_ENV_NUMBER")

      raw = @env["TEST_ENV_NUMBER"].to_s
      index = raw.empty? ? 1 : positive(raw)
      [index, positive(@env["PARALLEL_TEST_GROUPS"])] if index
    end

    def positive(value)
      Integer(value.to_s, exception: false)&.then { |n| n.positive? ? n : nil }
    end
  end
end
