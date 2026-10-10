# frozen_string_literal: true

require "tmpdir"
require "raider_reporter/rspec"

RaiderReporter.configure do |c|
  c.environment = { "suite" => "example" }
end

RSpec.configure do |config|
  # Real projects take a browser screenshot here, e.g. driver.save_screenshot(path).
  config.after do |example|
    next unless example.exception

    path = File.join(Dir.tmpdir, "failure-#{example.id.gsub(/\W/, '_')}.txt")
    File.write(path, "Failure captured for #{example.full_description}")
    RaiderReporter.attach("failure-note", path, type: :text)
  end
end
