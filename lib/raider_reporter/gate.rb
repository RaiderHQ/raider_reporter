# frozen_string_literal: true

require "raider_reporter/azure_env"
require "raider_reporter/ci_detector"
require "raider_reporter/gate_client"
require "raider_reporter/gate_status"

module RaiderReporter
  # `raider-reporter gate` (spec §5): waits for the Raider server's frozen quality gate
  # verdict of this CI build. Exits 0 when it passed or the project has no gate rules,
  # 1 when it failed, and 2 for every way it gets no verdict. Unlike `exec` and
  # `comment`, it fails closed. The tokens are never printed.
  class Gate
    PREFIX = "raider-reporter gate:"
    PASSED = 0
    FAILED = 1
    NO_VERDICT = 2
    DEFAULT_TIMEOUT = 600
    TIMEOUT_RANGE = (1..3600)
    INTERVAL = 10
    PROGRESS_EVERY = 60
    LABELS = { "pass_rate" => "pass rate", "new_failures" => "new failures", "new_flaky" => "new flaky" }.freeze
    MARKS = { "passed" => "✓", "failed" => "✗", "skipped" => "–" }.freeze
    USAGE = <<~TEXT
      Usage: raider-reporter gate

      Waits for the Raider quality gate verdict of this CI build and posts a "raider/gate" status.
      Exits 0 when the gate passed or the project has no gate rules, 1 when it failed, and 2 when no
      verdict arrived (timeout, Raider unreachable, token rejected, build not found).
        Environment: RAIDER_TOKEN, RAIDER_ENDPOINT, RAIDER_GATE_TIMEOUT (seconds, 1-3600, default 600).
        Status: GITHUB_TOKEN (GitHub Actions) or SYSTEM_ACCESSTOKEN (Azure Repos pull requests).
    TEXT

    def initialize(env: ENV, out: $stdout, err: $stderr, clock: nil, sleeper: nil)
      @env = env
      @out = out
      @err = err
      @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      @status = nil
      @url = nil
      @detail = nil
      @last_progress = nil
    end

    def run
      build_key = CiDetector.new(env: @env, git: ->(*) {}).ci&.dig("build_key")
      return refuse("no CI build key (run this in GitHub Actions or Azure Pipelines)") unless build_key

      token = AzureEnv.value(@env, "RAIDER_TOKEN")
      endpoint = AzureEnv.value(@env, "RAIDER_ENDPOINT")
      return refuse("RAIDER_TOKEN and RAIDER_ENDPOINT are required") unless token && endpoint

      timeout = parse_timeout
      return refuse("RAIDER_GATE_TIMEOUT must be a whole number of seconds from 1 to 3600") unless timeout

      @status = GateStatus.new(env: @env, warn: ->(message) { say(@err, "#{PREFIX} #{message}") })
      @status.post(:pending, "Waiting for the Raider verdict")
      finish(poll(GateClient.new(endpoint: endpoint, token: token), build_key, timeout), timeout)
    rescue StandardError => e
      no_verdict("#{e.class}: #{e.message}")
    end

    private

    def parse_timeout
      raw = AzureEnv.value(@env, "RAIDER_GATE_TIMEOUT")
      return DEFAULT_TIMEOUT if raw.nil?

      value = Integer(raw, 10, exception: false)
      value if value && TIMEOUT_RANGE.cover?(value)
    end

    # The last response that ends the wait, or nil when the time limit ran out.
    def poll(client, build_key, timeout)
      deadline = @clock.call + timeout
      loop do
        response = client.fetch(build_key)
        return response unless response.kind == :retry || pending?(response)

        note(response)
        remaining = deadline - @clock.call
        return nil if remaining <= 0

        @sleeper.call([INTERVAL, remaining].min)
      end
    end

    def pending?(response)
      response.kind == :verdict && response.data["state"] == "pending"
    end

    def note(response)
      if response.kind == :retry
        @detail = response.reason
        return
      end

      remember_url(response.data)
      @detail = pending_detail(response.data)
      now = @clock.call
      return if @last_progress && now - @last_progress < PROGRESS_EVERY

      @last_progress = now
      say(@out, "#{PREFIX} waiting for the verdict (#{@detail})")
    end

    def pending_detail(data)
      shards = data["shards"].is_a?(Hash) ? data["shards"] : {}
      received = shards["received"]
      expected = shards["expected"]
      if received.is_a?(Integer) && expected.is_a?(Integer) && received < expected
        "build incomplete: #{received} of #{expected} shards"
      else
        "analysing results"
      end
    end

    def finish(response, timeout)
      return no_verdict("no verdict after #{timeout}s (#{@detail || 'no response'})") unless response

      case response.kind
      when :rejected then no_verdict("token rejected (HTTP #{response.code})")
      when :not_found then no_verdict("build not found (did the tests upload?)")
      when :error then no_verdict(response.reason)
      else report(response.data)
      end
    end

    def report(data)
      remember_url(data)
      rules = data["rules"].select { |rule| rule.is_a?(Hash) }
      case data["state"]
      when "none"
        say(@out, "#{PREFIX} no gate rules for this project")
        @status.post(:success, "No gate rules", target_url: @url)
        PASSED
      when "passed"
        say(@out, "#{PREFIX} passed")
        rules.each { |rule| say(@out, rule_line(rule)) }
        @status.post(:success, "Gate passed", target_url: @url)
        PASSED
      else
        report_failed(rules.select { |rule| rule["outcome"] == "failed" })
      end
    end

    def report_failed(failed)
      say(@err, "#{PREFIX} failed")
      failed.each { |rule| say(@err, rule_line(rule)) }
      say(@err, "  #{@url}") if @url
      description = failed.map { |rule| rule_text(rule) }.join("; ")
      @status.post(:failure, description.empty? ? "Gate failed" : description, target_url: @url)
      FAILED
    end

    def rule_line(rule)
      "  #{MARKS.fetch(rule['outcome'].to_s, '?')} #{rule_text(rule)}"
    end

    def rule_text(rule)
      name = rule["rule"].to_s
      "#{LABELS.fetch(name, name)}: #{rule['detail']}"
    end

    def remember_url(data)
      @url = data["url"] if data["url"].is_a?(String) && !data["url"].empty?
    end

    # Exit 2 before polling: nothing was posted, so there is no status to clear.
    def refuse(message)
      say(@err, "#{PREFIX} #{message}")
      NO_VERDICT
    end

    # Exit 2 after the pending status: replace it, so a required check is never left pending.
    def no_verdict(message)
      say(@err, "#{PREFIX} #{message}")
      @status&.post(:error, "No verdict", target_url: @url)
      NO_VERDICT
    end

    def say(io, text)
      io.puts(redact(text))
    end

    def redact(text)
      secrets = [AzureEnv.value(@env, "RAIDER_TOKEN"), AzureEnv.value(@env, "GITHUB_TOKEN"),
                 AzureEnv.value(@env, "SYSTEM_ACCESSTOKEN")].compact
      secrets.reduce(text.to_s) { |memo, secret| memo.gsub(secret, "[REDACTED]") }
    end
  end
end
