# frozen_string_literal: true

RSpec.describe RaiderReporter::Collector do
  let(:warnings) { [] }
  let(:times) { [Time.utc(2026, 1, 1, 0, 0, 0), Time.utc(2026, 1, 1, 0, 1, 0)] }
  let(:collector) do
    described_class.new(max_attachment_bytes: 10, warn: ->(m) { warnings << m },
                        clock: -> { times.shift }, uuid: -> { "uuid-1" })
  end
  let(:fields) do
    { identifier: "id", full_name: "n", file_path: "spec/a_spec.rb", line_number: 1, status: "passed",
      duration_ms: 1, attempts: 1, tags: [], failure: nil }
  end

  def attachment(dir, name, bytes)
    path = File.join(dir, name)
    File.binwrite(path, "x" * bytes)
    RaiderReporter::Attachment.new(name: name, source_path: path, content_type: "image/png")
  end

  it "builds a run with results and timing" do
    collector.start_run
    collector.start_test
    collector.finish_test(**fields)
    run = collector.finish_run(ci: nil, git: nil, environment: {})
    expect(run.client_run_id).to eq("uuid-1")
    expect([run.started_at, run.finished_at]).to eq([Time.utc(2026, 1, 1, 0, 0, 0), Time.utc(2026, 1, 1, 0, 1, 0)])
    expect(run.results.map(&:identifier)).to eq(["id"])
  end

  it "attaches only inside a test" do
    Dir.mktmpdir do |dir|
      collector.start_run
      expect(collector.attach(attachment(dir, "a.png", 1))).to be(false)
      collector.start_test
      expect(collector.attach(attachment(dir, "b.png", 1))).to be(true)
      result = collector.finish_test(**fields)
      expect(result.attachments.map(&:name)).to eq(["b.png"])
      expect(collector.in_test?).to be(false)
    end
  end

  it "drops attachments that vanished or exceed the size limit, with warnings" do
    Dir.mktmpdir do |dir|
      collector.start_run
      collector.start_test
      kept = attachment(dir, "ok.png", 10)
      big = attachment(dir, "big.png", 11)
      gone = attachment(dir, "gone.png", 1)
      [kept, big, gone].each { |a| collector.attach(a) }
      collector.finish_test(**fields)
      File.delete(gone.source_path)
      run = collector.finish_run(ci: nil, git: nil, environment: {})
      expect(run.results.first.attachments).to eq([kept])
      expect(warnings.join("\n")).to include("big.png").and include("gone.png")
    end
  end

  it "loads the quarantine list at run start and matches results by test key" do
    loads = 0
    key = RaiderReporter.test_key("spec/a_spec.rb", "n")
    quarantining = described_class.new(max_attachment_bytes: 10, warn: ->(m) { warnings << m },
                                       quarantine: lambda {
                                         loads += 1
                                         Set[key].freeze
                                       })

    expect(quarantining.quarantined?("spec/a_spec.rb", "n")).to be(false)
    quarantining.start_run
    expect(loads).to eq(1)
    expect(quarantining.quarantined?("spec/a_spec.rb", "n")).to be(true)
    expect(quarantining.quarantined?("spec/a_spec.rb", "other")).to be(false)
  end

  it "quarantines nothing and warns when the loader raises" do
    broken = described_class.new(max_attachment_bytes: 10, warn: ->(m) { warnings << m }, quarantine: -> { raise "boom" })
    broken.start_run
    expect(broken.quarantined?("spec/a_spec.rb", "n")).to be(false)
    expect(warnings).to eq(["quarantine list unavailable (RuntimeError: boom); no tests quarantined"])
  end

  it "quarantines nothing by default" do
    collector.start_run
    expect(collector.quarantined?("spec/a_spec.rb", "n")).to be(false)
  end
end
