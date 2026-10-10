# frozen_string_literal: true

require "fileutils"
require "json"

module RaiderReporter
  module Writers
    class Local
      def initialize(config)
        @config = config
      end

      def write(payload)
        dir = File.expand_path(@config.output_dir)
        clean(dir) if @config.clean_output_dir
        FileUtils.mkdir_p(File.join(dir, "attachments"))
        payload.attachment_entries.each do |entry|
          FileUtils.cp(entry[:attachment].source_path, File.join(dir, entry[:path]))
        end
        run_json = File.join(dir, "run.json")
        File.write(run_json, JSON.pretty_generate(payload.to_h(mode: :local)))
        run_json
      end

      private

      # Remove only what this writer creates, so output_dir "." or "spec" is safe.
      def clean(dir)
        FileUtils.rm_f(File.join(dir, "run.json"))
        FileUtils.rm_rf(File.join(dir, "attachments"))
      end
    end
  end
end
