# frozen_string_literal: true

require "raider_reporter/cucumber"

RaiderReporter.configure { |c| c.output_dir = ENV.fetch("FIXTURE_OUT") }

After("@boom_after") do
  raise "teardown exploded"
end
