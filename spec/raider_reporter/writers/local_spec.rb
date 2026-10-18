# frozen_string_literal: true

require "raider_reporter/writers/local"

RSpec.describe RaiderReporter::Writers::Local do
  def run_with(attachments, shard: nil)
    result = RaiderReporter::TestResult.new(
      identifier: "i", full_name: "n", file_path: "f", line_number: 1, status: "failed", duration_ms: 1,
      attempts: 1, tags: [], failure: nil, attachments: attachments
    )
    RaiderReporter::Run.new(client_run_id: "u", started_at: Time.now.utc, finished_at: Time.now.utc,
                            ci: nil, git: nil, environment: {}, results: [result], shard: shard)
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

  it "writes run-<index>.json and attachments-<index>/ for a shard, cleaning only its own files" do
    Dir.mktmpdir do |dir|
      out = File.join(dir, "out")
      FileUtils.mkdir_p([File.join(out, "attachments-1"), File.join(out, "attachments-2")])
      File.write(File.join(out, "run-1.json"), "one")
      File.write(File.join(out, "run.json"), "plain")
      File.write(File.join(out, "attachments-1", "keep.png"), "k")
      File.write(File.join(out, "attachments-2", "stale.png"), "s")
      File.write(File.join(out, "run-2.json"), "stale")
      src = File.join(dir, "shot.png")
      File.binwrite(src, "PNG")
      config = RaiderReporter::Configuration.new({})
      config.output_dir = out
      att = RaiderReporter::Attachment.new(name: "screenshot", source_path: src, content_type: "image/png")
      shard = { "index" => 2, "total" => 3, "label" => "local#2" }

      path = described_class.new(config).write(RaiderReporter::Payload.new(run_with([att], shard: shard)))

      expect(File.basename(path)).to eq("run-2.json")
      json = JSON.parse(File.read(path))
      expect(json["results"][0]["attachments"][0]["path"]).to eq("attachments-2/0-shot.png")
      expect(File.binread(File.join(out, "attachments-2", "0-shot.png"))).to eq("PNG")
      expect(File).not_to exist(File.join(out, "attachments-2", "stale.png"))
      expect(File.read(File.join(out, "run-1.json"))).to eq("one")
      expect(File.read(File.join(out, "run.json"))).to eq("plain")
      expect(File.read(File.join(out, "attachments-1", "keep.png"))).to eq("k")
    end
  end

  it "removes its own index.html when cleaning but never a user's" do
    Dir.mktmpdir do |dir|
      config = RaiderReporter::Configuration.new({})
      config.output_dir = dir
      File.write(File.join(dir, "index.html"), "<html>#{RaiderReporter::Writers::Html::MARKER}</html>")
      described_class.new(config).write(RaiderReporter::Payload.new(run_with([])))
      expect(File).not_to exist(File.join(dir, "index.html"))

      File.write(File.join(dir, "index.html"), "<html>mine</html>")
      described_class.new(config).write(RaiderReporter::Payload.new(run_with([])))
      expect(File.read(File.join(dir, "index.html"))).to eq("<html>mine</html>")
    end
  end

  it "still writes run.json when its own index.html is unreadable" do
    skip "root ignores file modes" if Process.uid.zero?
    Dir.mktmpdir do |dir|
      config = RaiderReporter::Configuration.new({})
      config.output_dir = dir
      index = File.join(dir, "index.html")
      File.write(index, "<html>#{RaiderReporter::Writers::Html::MARKER}</html>")
      File.chmod(0o000, index)
      begin
        path = described_class.new(config).write(RaiderReporter::Payload.new(run_with([])))
        expect(File).to exist(path)
      ensure
        File.chmod(0o644, index)
      end
    end
  end
end
