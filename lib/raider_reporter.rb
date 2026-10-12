# frozen_string_literal: true

require "time"
require "rbconfig"
require_relative "raider_reporter/version"
require_relative "raider_reporter/text"
require_relative "raider_reporter/models"
require_relative "raider_reporter/payload"
require_relative "raider_reporter/configuration"
require_relative "raider_reporter/content_types"
require_relative "raider_reporter/collector"
require_relative "raider_reporter/writers/local"
require_relative "raider_reporter/ci_detector"
require_relative "raider_reporter/shard_detector"
require_relative "raider_reporter/writers/uploader"
require_relative "raider_reporter/comment/summary_client"
require_relative "raider_reporter/comment/github_client"
require_relative "raider_reporter/comment/azure_client"

module RaiderReporter
  class << self
    attr_reader :collector

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    # Set by the Cucumber formatter when the run is a --dry-run.
    attr_writer :dry_run

    def reset!
      @dry_run = false
      @collector&.cleanup
      @configuration = nil
      @collector = nil
    end

    def start_collector!
      @dry_run = false
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

      limit = configuration.max_attachment_bytes
      if File.size(path.to_s) > limit
        warn("attach(#{name.inspect}): file #{path} is larger than #{limit} bytes; ignored")
        return false
      end

      collector.attach(Attachment.new(name: name.to_s, source_path: collector.stage(path.to_s),
                                      content_type: ContentTypes.resolve(type, path)))
    rescue StandardError => e
      warn("attach(#{name.inspect}) failed: #{e.class}: #{e.message}")
      false
    end

    def warn(message)
      # $stderr.puts, not Kernel.warn: -W0 must not silence reporting problems.
      $stderr.puts("[raider_reporter] #{message}")
    end

    def finish!(output = $stderr)
      return nil if dry_run?

      detector = CiDetector.new
      ci = detector.ci
      shard = ShardDetector.new(job: ci&.fetch("job", nil)).shard
      run = collector.finish_run(ci: ci, git: detector.git, environment: default_environment, shard: shard)
      payload = Payload.new(run)
      begin
        Writers::Local.new(configuration).write(payload)
      rescue StandardError => e
        warn("could not write #{configuration.output_dir}: #{e.class}: #{e.message}")
      end
      return nil unless configuration.upload?

      result = Writers::Uploader.new(configuration).upload(payload)
      if result.ok
        output.puts(success_line(result))
      else
        warn("upload failed: #{result.error}")
      end
      nil
    ensure
      collector&.cleanup
    end

    private

    def success_line(result)
      link = result.build_url || result.url
      return "Raider report: #{link}" if link
      return "Raider report uploaded (run #{result.run_id})" if result.run_id

      "Raider report uploaded"
    end

    # `rspec --dry-run` and `cucumber --dry-run` report every example as passed without running it.
    def dry_run?
      return true if @dry_run

      defined?(::RSpec.configuration) && ::RSpec.configuration.respond_to?(:dry_run?) &&
        ::RSpec.configuration.dry_run?
    end

    def default_environment
      { "ruby" => RUBY_VERSION, "os" => RbConfig::CONFIG["host_os"] }
        .merge((configuration.environment || {}).transform_keys(&:to_s))
    end
  end
end
