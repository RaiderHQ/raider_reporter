# frozen_string_literal: true

begin
  require "cucumber"
rescue LoadError => e
  raise unless e.path == "cucumber"

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
      # Cucumber's public InstallPlugin DSL method, called on a throwaway object
      # (it is only an instance method of Dsl; main is extended with it).
      Object.new.extend(::Cucumber::Glue::Dsl).InstallPlugin(name: "raider_reporter") do |config, *|
        RaiderReporter::Cucumber::Formatter.new(config)
      end
      true
    rescue StandardError => e
      # Outside a run there is no registry (Dsl has no rb_language) and nothing to
      # report. Inside one, losing the listener must not be silent.
      RaiderReporter.warn("could not register the Cucumber plugin: #{e.class}: #{e.message}") if run_active?
      false
    end

    def self.run_active?
      !::Cucumber::Glue::Dsl.instance_variable_get(:@rb_language).nil?
    end
    private_class_method :run_active?
  end
end

RaiderReporter::Cucumber.install_plugin
