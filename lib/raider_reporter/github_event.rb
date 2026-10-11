# frozen_string_literal: true

require "json"

module RaiderReporter
  # Reads the webhook payload GitHub Actions leaves at GITHUB_EVENT_PATH.
  module GithubEvent
    # Returns the parsed event Hash, or nil when missing, unreadable or invalid.
    def self.load(env = ENV)
      path = env["GITHUB_EVENT_PATH"].to_s
      return nil if path.empty?

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue StandardError
      nil
    end
  end
end
