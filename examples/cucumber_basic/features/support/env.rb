# frozen_string_literal: true

# Plugin mode: requiring this file registers the Raider reporter with Cucumber.
# Run with any normal --format; no --out is needed.
require "raider_reporter/cucumber"

RaiderReporter.configure do |c|
  c.environment = { "suite" => "example" }
end
