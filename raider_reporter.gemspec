# frozen_string_literal: true

require_relative "lib/raider_reporter/version"

Gem::Specification.new do |spec|
  spec.name = "raider_reporter"
  spec.version = RaiderReporter::VERSION
  spec.authors = ["Augustin Gottlieb"]
  spec.email = ["33221555+aguspe@users.noreply.github.com"]
  spec.summary = "Test reporting for Ruby Raider: local run.json and Raider uploads"
  spec.description = "RSpec formatter that records results, screenshots and videos in the Raider " \
                     "schema, writes them locally, and optionally uploads them to a Raider server."
  spec.homepage = "https://github.com/RaiderHQ/raider_reporter"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
