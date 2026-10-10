# frozen_string_literal: true

require "time"
require "rbconfig"
require_relative "raider_reporter/version"
require_relative "raider_reporter/models"
require_relative "raider_reporter/payload"
require_relative "raider_reporter/configuration"
require_relative "raider_reporter/content_types"
require_relative "raider_reporter/collector"
require_relative "raider_reporter/writers/local"

module RaiderReporter
  class << self
    attr_reader :collector

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def reset!
      @configuration = nil
      @collector = nil
    end

    def start_collector!
      @collector = Collector.new(
        max_attachment_bytes: configuration.max_attachment_bytes,
        warn: ->(message) { warn(message) }
      )
    end

    def attach(name, path, type: nil)
      unless collector&.in_test?
        warn("attach(#{name.inspect}) called outside a running example; ignored")
        return false
      end
      unless File.file?(path.to_s)
        warn("attach(#{name.inspect}): file #{path} not found; ignored")
        return false
      end

      collector.attach(Attachment.new(name: name.to_s, source_path: File.expand_path(path.to_s),
                                      content_type: ContentTypes.resolve(type, path)))
    end

    def warn(message)
      Kernel.warn("[raider_reporter] #{message}")
    end

    def finish!(_output = $stdout)
      run = collector.finish_run(ci: nil, git: nil, environment: default_environment)
      Writers::Local.new(configuration).write(Payload.new(run))
      nil
    end

    private

    def default_environment
      { "ruby" => RUBY_VERSION, "os" => RbConfig::CONFIG["host_os"] }
        .merge(configuration.environment.transform_keys(&:to_s))
    end
  end
end
