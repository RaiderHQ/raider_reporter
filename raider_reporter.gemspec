# frozen_string_literal: true

require_relative "lib/raider_reporter/version"

Gem::Specification.new do |spec|
  spec.name = "raider_reporter"
  spec.version = RaiderReporter::VERSION
  spec.authors = ["Augustin Gottlieb"]
  spec.email = ["33221555+aguspe@users.noreply.github.com"]
  spec.summary = "RSpec and Cucumber formatters that write Raider reports locally and upload them to Raider"
  spec.description = "RSpec and Cucumber formatters that record results, screenshots and videos in the Raider " \
                     "schema, write them locally, and optionally upload them to a Raider server."
  spec.homepage = "https://github.com/RaiderHQ/raider_reporter"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = ["raider-reporter"]
  spec.require_paths = ["lib"]
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
