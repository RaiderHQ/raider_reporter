# frozen_string_literal: true

RSpec.describe RaiderReporter::Payload do
  let(:shot) { RaiderReporter::Attachment.new(name: "screenshot", source_path: "/tmp/a/shot.png", content_type: "image/png") }
  let(:video) { RaiderReporter::Attachment.new(name: "video", source_path: "/tmp/a/run.mp4", content_type: "video/mp4") }
  let(:failed) do
    RaiderReporter::TestResult.new(
      identifier: "./spec/login_spec.rb[1:2]", full_name: "Login fails", file_path: "spec/login_spec.rb",
      line_number: 12, status: "failed", duration_ms: 2340, attempts: 1, tags: ["smoke"],
      failure: RaiderReporter::Failure.new(message: "boom", exception_class: "RuntimeError", backtrace: ["a.rb:1"]),
      attachments: [shot, video]
    )
  end
  let(:passed) { failed.with(identifier: "./spec/login_spec.rb[1:1]", status: "passed", failure: nil, attachments: []) }
  let(:run) do
    RaiderReporter::Run.new(
      client_run_id: "uuid-1", started_at: Time.utc(2026, 10, 10, 12), finished_at: Time.utc(2026, 10, 10, 12, 4, 31),
      ci: nil, git: { "branch" => "main" }, environment: { "ruby" => "4.0.2" }, results: [passed, failed], shard: nil
    )
  end

  subject(:payload) { described_class.new(run) }

  it "emits schema version and run metadata" do
    h = payload.to_h(mode: :local)
    expect(h["schema_version"]).to eq(1)
    expect(h["client_run_id"]).to eq("uuid-1")
    expect(h["run"]).to eq(
      "started_at" => "2026-10-10T12:00:00.000Z", "finished_at" => "2026-10-10T12:04:31.000Z",
      "git" => { "branch" => "main" }, "environment" => { "ruby" => "4.0.2" }
    )
  end

  describe "comparisons" do
    let(:comparison) do
      RaiderReporter::Comparison.new(
        name: "home", status: "failed", baseline: "screenshots/baselines/chrome/home.png", diff_pixels: 1834,
        diff_ratio: 0.00088, threshold: 0.2, max_diff_pixels: 0, max_diff_ratio: nil,
        expected_size: [1920, 1080], actual_size: [1920, 1080]
      )
    end
    let(:expected) do
      { "name" => "home", "status" => "failed", "baseline" => "screenshots/baselines/chrome/home.png",
        "diff_pixels" => 1834, "diff_ratio" => 0.00088, "threshold" => 0.2, "max_diff_pixels" => 0,
        "max_diff_ratio" => nil, "expected_size" => [1920, 1080], "actual_size" => [1920, 1080] }
    end

    it "omits the key and stays schema 1 when a result has none" do
      h = payload.to_h(mode: :local)
      expect(h["results"].flat_map(&:keys)).not_to include("comparisons")
      expect(h["schema_version"]).to eq(1)
    end

    %i[local upload].each do |mode|
      it "emits the exact hash in #{mode} mode" do
        with = described_class.new(run.with(results: [failed.with(comparisons: [comparison])]))
        h = with.to_h(mode: mode)
        expect(h["results"].first["comparisons"]).to eq([expected])
        expect(h["schema_version"]).to eq(1)
      end
    end
  end

  it "serializes the shard under run.shard and omits it when nil" do
    shard = { "index" => 2, "total" => 3, "label" => "e2e#2" }
    sharded = described_class.new(run.with(shard: shard))
    expect(sharded.to_h(mode: :local)["run"]["shard"]).to eq(shard)
    expect(sharded.shard_index).to eq(2)
    expect(payload.to_h(mode: :local)["run"]).not_to have_key("shard")
    expect(payload.shard_index).to be_nil
  end

  it "keeps sub-second precision in run timestamps" do
    sub = run.with(started_at: Time.utc(2026, 10, 10, 12, 0, 0.5r), finished_at: Time.utc(2026, 10, 10, 12, 0, 1.25r))
    h = described_class.new(sub).to_h(mode: :local)
    expect(h["run"]).to include("started_at" => "2026-10-10T12:00:00.500Z", "finished_at" => "2026-10-10T12:00:01.250Z")
  end

  it "omits failure for non-failed results" do
    expect(payload.to_h(mode: :local)["results"][0]).not_to have_key("failure")
    expect(payload.to_h(mode: :local)["results"][1]["failure"]).to eq(
      "message" => "boom", "exception_class" => "RuntimeError", "backtrace" => ["a.rb:1"]
    )
  end

  it "includes app_frame in the failure only when present" do
    with_frame = failed.with(failure: failed.failure.with(app_frame: "spec/a_spec.rb:3:in 'block'"))
    run_with = run.with(results: [with_frame])
    expect(described_class.new(run_with).to_h(mode: :local)["results"][0]["failure"]).to eq(
      "message" => "boom", "exception_class" => "RuntimeError", "backtrace" => ["a.rb:1"],
      "app_frame" => "spec/a_spec.rb:3:in 'block'"
    )
    expect(payload.to_h(mode: :local)["results"][1]["failure"]).not_to have_key("app_frame")
  end

  it "references attachments by path in local mode" do
    atts = payload.to_h(mode: :local)["results"][1]["attachments"]
    expect(atts).to eq([
      { "name" => "screenshot", "content_type" => "image/png", "path" => "attachments/0-shot.png" },
      { "name" => "video", "content_type" => "video/mp4", "path" => "attachments/1-run.mp4" }
    ])
  end

  it "writes an attachment's attempt when it has one, in both modes" do
    trace = RaiderReporter::Attachment.new(name: "trace", source_path: "/tmp/a/trace.zip",
                                           content_type: "application/vnd.raider.trace+zip", attempt: 2)
    result = payload.run.results[1].with(attachments: [trace])
    traced = RaiderReporter::Payload.new(payload.run.with(results: [result]))
    expect(traced.to_h(mode: :local)["results"][0]["attachments"]).to eq([
      { "name" => "trace", "content_type" => "application/vnd.raider.trace+zip",
        "path" => "attachments/0-trace.zip", "attempt" => 2 }
    ])
    expect(traced.to_h(mode: :upload)["results"][0]["attachments"][0]["attempt"]).to eq(2)
  end

  it "references attachments by part in upload mode" do
    atts = payload.to_h(mode: :upload)["results"][1]["attachments"]
    expect(atts.map { |a| a["part"] }).to eq(%w[att_0 att_1])
    expect(atts.first).not_to have_key("path")
  end

  it "lists attachment entries in the same order as the hash" do
    expect(payload.attachment_entries.map { |e| [e[:part], e[:attachment].name] })
      .to eq([%w[att_0 screenshot], %w[att_1 video]])
  end

  it "rejects unknown modes" do
    expect { payload.to_h(mode: :nope) }.to raise_error(ArgumentError)
  end

  it "lists quarantined as a status and writes the highest schema version" do
    expect(RaiderReporter::STATUSES).to eq(%w[passed failed pending skipped quarantined])
    expect(RaiderReporter::SCHEMA_VERSION).to eq(2)
  end

  it "writes schema 2 only when a result is quarantined, keeping its failure" do
    expect(payload.to_h(mode: :upload)["schema_version"]).to eq(1)

    quarantined = failed.with(status: "quarantined")
    h = described_class.new(run.with(results: [passed, quarantined])).to_h(mode: :upload)

    expect(h["schema_version"]).to eq(2)
    expect(h["results"][1]["status"]).to eq("quarantined")
    expect(h["results"][1]["failure"]).to eq("message" => "boom", "exception_class" => "RuntimeError", "backtrace" => ["a.rb:1"])
    expect(h["results"][1]["attachments"].map { |a| a["part"] }).to eq(%w[att_0 att_1])
  end
end
