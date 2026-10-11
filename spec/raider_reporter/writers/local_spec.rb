# frozen_string_literal: true

require "raider_reporter/writers/local"

RSpec.describe RaiderReporter::Writers::Local do
  def run_with(attachments)
    result = RaiderReporter::TestResult.new(
      identifier: "i", full_name: "n", file_path: "f", line_number: 1, status: "failed", duration_ms: 1,
      attempts: 1, tags: [], failure: nil, attachments: attachments
    )
    RaiderReporter::Run.new(client_run_id: "u", started_at: Time.now.utc, finished_at: Time.now.utc,
                            ci: nil, git: nil, environment: {}, results: [result], shard: nil)
  end

  it "writes run.json and copies attachments" do
    Dir.mktmpdir do |dir|
      src = File.join(dir, "shot.png")
      File.binwrite(src, "PNG")
      config = RaiderReporter::Configuration.new({})
      config.output_dir = File.join(dir, "out")
      att = RaiderReporter::Attachment.new(name: "screenshot", source_path: src, content_type: "image/png")

      path = described_class.new(config).write(RaiderReporter::Payload.new(run_with([att])))

      json = JSON.parse(File.read(path))
      expect(json["results"][0]["attachments"][0]["path"]).to eq("attachments/0-shot.png")
      expect(File.binread(File.join(dir, "out", "attachments", "0-shot.png"))).to eq("PNG")
    end
  end

  it "cleans only its own files, never other files in output_dir" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "user_file.rb"), "keep me")
      FileUtils.mkdir_p(File.join(dir, "attachments"))
      File.write(File.join(dir, "attachments", "old.png"), "old")
      config = RaiderReporter::Configuration.new({})
      config.output_dir = dir

      described_class.new(config).write(RaiderReporter::Payload.new(run_with([])))

      expect(File.read(File.join(dir, "user_file.rb"))).to eq("keep me")
      expect(File).not_to exist(File.join(dir, "attachments", "old.png"))
      expect(File).to exist(File.join(dir, "run.json"))
    end
  end
end
