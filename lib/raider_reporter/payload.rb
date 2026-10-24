# frozen_string_literal: true

module RaiderReporter
  # Serializes a Run: schema 1, or schema 2 when a result is quarantined. Local mode points attachments at copied
  # files; upload mode points them at multipart part names.
  class Payload
    MODES = %i[local upload].freeze

    attr_reader :run

    def initialize(run)
      @run = run
    end

    def to_h(mode:)
      raise ArgumentError, "unknown mode #{mode.inspect}" unless MODES.include?(mode)

      entries = attachment_entries.each
      {
        "schema_version" => schema_version,
        "client_run_id" => @run.client_run_id,
        "run" => run_hash,
        "results" => @run.results.map do |result|
          result_hash(result).merge(
            "attachments" => result.attachments.map { attachment_hash(entries.next, mode) }
          )
        end
      }
    end

    def shard_index = @run.shard&.fetch("index")

    def attachments_dir = shard_index ? "attachments-#{shard_index}" : "attachments"

    def run_file = shard_index ? "run-#{shard_index}.json" : "run.json"

    # Version 2 only adds the quarantined status; older servers keep accepting
    # every run that has none (spec §4.3).
    def schema_version = @run.results.any? { |result| result.status == "quarantined" } ? SCHEMA_VERSION : 1

    def attachment_entries
      @attachment_entries ||= @run.results.flat_map(&:attachments).each_with_index.map do |attachment, index|
        {
          attachment: attachment,
          part: "att_#{index}",
          path: "#{attachments_dir}/#{index}-#{File.basename(attachment.source_path)}"
        }
      end
    end

    private

    def run_hash
      {
        "started_at" => @run.started_at&.utc&.iso8601(3),
        "finished_at" => @run.finished_at&.utc&.iso8601(3),
        "ci" => @run.ci,
        "git" => @run.git,
        "environment" => @run.environment,
        "shard" => @run.shard
      }.compact
    end

    def result_hash(result)
      hash = {
        "identifier" => result.identifier,
        "full_name" => result.full_name,
        "file_path" => result.file_path,
        "line_number" => result.line_number,
        "status" => result.status,
        "duration_ms" => result.duration_ms,
        "attempts" => result.attempts,
        "tags" => result.tags
      }
      hash["failure"] = failure_hash(result.failure) if result.failure
      hash
    end

    def failure_hash(failure)
      hash = {
        "message" => failure.message,
        "exception_class" => failure.exception_class,
        "backtrace" => failure.backtrace
      }
      hash["app_frame"] = failure.app_frame if failure.app_frame
      hash
    end

    def attachment_hash(entry, mode)
      ref = mode == :local ? { "path" => entry[:path] } : { "part" => entry[:part] }
      { "name" => entry[:attachment].name, "content_type" => entry[:attachment].content_type }.merge(ref)
    end
  end
end
