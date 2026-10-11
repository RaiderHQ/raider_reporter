# frozen_string_literal: true

begin
  require "cucumber"
rescue LoadError => e
  raise unless e.path == "cucumber" || e.message.include?("cucumber")

  raise LoadError, "raider_reporter/cucumber needs the cucumber gem (>= 9, < 12) in your Gemfile"
end
require "raider_reporter"
require_relative "cucumber/formatter"

module RaiderReporter
  module Cucumber
    # Plugin mode: requiring this file from features/support registers the
    # listener through Cucumber's InstallPlugin hook, so no --format is needed
    # (and none of the "one formatter per stream" juggling). Outside a Cucumber
    # run there is no step-definition registry and this is a no-op.
    def self.install_plugin
      ::Cucumber::Glue::Dsl.register_rb_hook(
        "install_plugin", [], proc { |config, *| RaiderReporter::Cucumber::Formatter.new(config) },
        name: "raider_reporter"
      )
      true
    rescue StandardError
      false
    end
  end
end

RaiderReporter::Cucumber.install_plugin
