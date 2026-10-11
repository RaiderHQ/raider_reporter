# frozen_string_literal: true

# FIXTURE_MODE: "formatter" (default; wired up by --format), "plugin" or "both"
# (requiring raider_reporter/cucumber installs the plugin).
if ENV.fetch("FIXTURE_MODE", "formatter") == "formatter"
  require "raider_reporter/cucumber/formatter"
else
  require "raider_reporter/cucumber"
end

RaiderReporter.configure { |c| c.output_dir = ENV.fetch("FIXTURE_OUT") }

if ENV["FIXTURE_BREAK_AST"]
  Cucumber::Formatter::AstLookup.prepend(Module.new { def gherkin_document(_uri) = nil })
end

Before("@boom_before") do
  raise "setup exploded"
end

AfterStep("@boom_after_step") do
  raise "after step exploded"
end

After("@boom_after") do
  raise "teardown exploded"
end

# Simulates a bug inside the reporter to prove it is fail-open.
if ENV["RAIDER_FIXTURE_BOOM"]
  RaiderReporter::Collector.prepend(Module.new do
    def finish_test(**) = raise("boom in finish_test")
    def build_test(**) = raise("boom in build_test")
  end)
end
