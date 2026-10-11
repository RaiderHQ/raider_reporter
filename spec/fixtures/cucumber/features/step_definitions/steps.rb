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
