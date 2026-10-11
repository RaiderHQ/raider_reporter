# frozen_string_literal: true

Given("I am on the login page") { nil }
When("I log in") { nil }
Then("I see the dashboard") { nil }
When("I fail on purpose") { raise ArgumentError, "bad credentials" }
When("I do something pending") { pending("not built yet") }
When("I raise binary text") { raise "bad \xFF byte" }
When("I am ambiguous") { nil }
When(/^I am (ambiguous)$/) { |_| nil }
When("I greet {word}") { |_name| nil }

# Counts attempts across retries through a file, because each retry is a fresh World.
def fixture_attempt
  path = ENV.fetch("FIXTURE_COUNTER")
  count = File.exist?(path) ? File.read(path).to_i : 0
  File.write(path, (count + 1).to_s)
  count + 1
end

When("I fail on the first attempt") { raise "flaky" if fixture_attempt == 1 }
When("I attach a screenshot with raider") { RaiderReporter.attach("screenshot", ENV.fetch("FIXTURE_PNG"), type: :png) }
When("I attach a screenshot with cucumber") { attach(ENV.fetch("FIXTURE_PNG"), "image/png") }
When("I attach inline text") { attach("inline text", "text/plain") }
When("I attach a screenshot then fail on the first attempt") do
  if fixture_attempt == 1
    RaiderReporter.attach("screenshot", ENV.fetch("FIXTURE_PNG"), type: :png)
    raise "flaky"
  end
end
When("I log the screenshot path") { log ENV.fetch("FIXTURE_PNG") }
When("I attach a screenshot pathname") { attach(Pathname.new(ENV.fetch("FIXTURE_PNG")), "image/png") }
