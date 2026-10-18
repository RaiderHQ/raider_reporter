# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "html"

module RaiderReporter
  module Writers
    class Local
      def initialize(config)
        @config = config
      end

      def write(payload)
        dir = File.expand_path(@config.output_dir)
        clean(dir, payload) if @config.clean_output_dir
        FileUtils.mkdir_p(File.join(dir, payload.attachments_dir))
        payload.attachment_entries.each do |entry|
          FileUtils.cp(entry[:attachment].source_path, File.join(dir, entry[:path]))
        end
        run_json = File.join(dir, payload.run_file)
        File.write(run_json, JSON.pretty_generate(payload.to_h(mode: :local)))
        run_json
      end

      private

      # Remove only what this writer creates, so output_dir "." or "spec" is safe.
      def clean(dir, payload)
        FileUtils.rm_f(File.join(dir, payload.run_file))
        FileUtils.rm_rf(File.join(dir, payload.attachments_dir))
        index = File.join(dir, Html::FILE)
        FileUtils.rm_f(index) if Html.ours?(index)
      end
    end
  end
end
