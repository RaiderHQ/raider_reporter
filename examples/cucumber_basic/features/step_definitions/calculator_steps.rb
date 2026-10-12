# frozen_string_literal: true

require "tmpdir"

When("I add {int} and {int}") do |a, b|
  @result = a + b
end

Then("the result is {int}") do |expected|
  next if @result == expected

  # Real projects take a browser screenshot here, e.g. driver.save_screenshot(path).
  path = File.join(Dir.tmpdir, "failure-note.txt")
  File.write(path, "Expected #{expected}, got #{@result}")
  attach(path, "text/plain") # Cucumber's own attach; captured when given an existing file path
  raise "expected #{expected}, got #{@result}"
end
