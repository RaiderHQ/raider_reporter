# frozen_string_literal: true

require "tmpdir"
require "raider_reporter/event_stream"

RSpec.describe RaiderReporter::EventStream do
  let(:warnings) { [] }
  let(:warn_fn) { ->(message) { warnings << message } }

  def lines(dir, name = "worker-1.ndjson")
    File.readlines(File.join(dir, name)).map { |line| JSON.parse(line) }
  end

  it "returns nil without RAIDER_EVENTS_DIR" do
    expect(described_class.open(env: {}, shard: nil, warn: warn_fn)).to be_nil
    expect(described_class.open(env: { "RAIDER_EVENTS_DIR" => "" }, shard: nil, warn: warn_fn)).to be_nil
  end

  it "writes worker-1.ndjson without a shard" do
    Dir.mktmpdir do |dir|
      stream = described_class.open(env: { "RAIDER_EVENTS_DIR" => File.join(dir, "ev") }, shard: nil, warn: warn_fn)
      stream.done
      stream.close
      expect(File).to exist(File.join(dir, "ev", "worker-1.ndjson"))
    end
  end

  it "writes worker-3.ndjson for shard index 3" do
    Dir.mktmpdir do |dir|
      stream = described_class.open(env: { "RAIDER_EVENTS_DIR" => dir }, shard: { "index" => 3 }, warn: warn_fn)
      stream.done
      stream.close
      expect(File).to exist(File.join(dir, "worker-3.ndjson"))
    end
  end

  it "writes one JSON line per call with v 1" do
    Dir.mktmpdir do |dir|
      stream = described_class.open(env: { "RAIDER_EVENTS_DIR" => dir }, shard: nil, warn: warn_fn)
      test = { id: "./a_spec.rb[1:1]", file: "a_spec.rb", line: 3, description: "d", full_name: "A d" }
      stream.plan([test])
      stream.started(test)
      stream.finished(id: "./a_spec.rb[1:1]", status: "passed", duration_ms: 12, attempts: 1)
      stream.done
      stream.close

      events = lines(dir)
      expect(events.map { |e| e["type"] }).to eq(%w[plan started finished done])
      expect(events[2]).to eq("v" => 1, "type" => "finished", "id" => "./a_spec.rb[1:1]", "status" => "passed",
                              "duration_ms" => 12, "attempts" => 1)
      expect(events[0]["tests"]).to eq([{ "id" => "./a_spec.rb[1:1]", "file" => "a_spec.rb", "line" => 3,
                                          "description" => "d", "full_name" => "A d" }])
    end
  end

  it "stops writing after an IO error and warns once" do
    Dir.mktmpdir do |dir|
      file = File.open(File.join(dir, "x.ndjson"), "a")
      allow(file).to receive(:write).and_raise(IOError, "disk gone")
      stream = described_class.new(file, warn: warn_fn)
      stream.done
      stream.done
      expect(warnings.size).to eq(1)
      expect(file).to have_received(:write).once
    end
  end
end
