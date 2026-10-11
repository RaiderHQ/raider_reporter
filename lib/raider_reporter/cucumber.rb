# frozen_string_literal: true

begin
  require "cucumber"
rescue LoadError
  raise LoadError, "raider_reporter/cucumber needs the cucumber gem (>= 9, < 12) in your Gemfile"
end
require "raider_reporter"
require_relative "cucumber/formatter"
