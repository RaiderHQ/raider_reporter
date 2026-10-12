# frozen_string_literal: true

require "raider_reporter/azure_env"

module RaiderReporter
  # Identifies which slice of a parallel suite this process is.
  class ShardDetector
    def initialize(env: ENV, job: nil)
      @env = env
      @job = job.to_s.strip.empty? ? nil : job.to_s
    end

    def shard
      index, total, suffix = composed || outer || parallel_tests
      return nil unless index

      { "index" => index, "total" => total, "label" => "#{@job || "local"}##{suffix || index}" }
    end

    private

    # A matrix leg that also runs parallel_tests: every process gets a unique index.
    def composed
      explicit_index, explicit_total = outer
      parallel_index, = parallel_tests
      groups = positive(@env["PARALLEL_TEST_GROUPS"])
      return nil unless explicit_index && parallel_index && groups

      [(explicit_index - 1) * groups + parallel_index,
       explicit_total && explicit_total * groups,
       "#{explicit_index}.#{parallel_index}"]
    end

    def outer
      explicit || azure_parallel
    end

    def azure_parallel
      return nil unless AzureEnv.azure?(@env)

      total = positive(AzureEnv.value(@env, "SYSTEM_TOTALJOBSINPHASE"))
      index = positive(AzureEnv.value(@env, "SYSTEM_JOBPOSITIONINPHASE"))
      [index, total] if index && total && total > 1
    end

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
