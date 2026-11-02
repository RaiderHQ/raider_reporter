# frozen_string_literal: true

RSpec.describe "RaiderReporter.comparison" do
  let(:err) { StringIO.new }
  let(:collector) { RaiderReporter.start_collector! }
  let(:fields) do
    { identifier: "i", full_name: "n", file_path: "f", line_number: 1, status: "failed",
      duration_ms: 1, attempts: 1, tags: [], failure: nil }
  end

  def record(name: "home", status: "failed", **extra)
    RaiderReporter.comparison(name: name, status: status, baseline: "screenshots/baselines/chrome/#{name}.png",
                              diff_pixels: 10, diff_ratio: 0.1, threshold: 0.2, max_diff_pixels: 0,
                              expected_size: [10, 10], actual_size: [10, 10], **extra)
  end

  before do
    RaiderReporter.reset!
    @stderr = $stderr
    $stderr = err
  end

  after do
    $stderr = @stderr
    RaiderReporter.reset!
  end

  it "returns false and warns outside a test" do
    expect(record).to be(false)
    expect(err.string).to include("[raider_reporter]").and include("outside")
  end

  it "rejects an unknown status with a warning" do
    collector.start_run
    collector.start_test
    expect(record(status: "weird")).to be(false)
    expect(err.string).to include("[raider_reporter]").and include("status")
  end

  ["../x", "/abs", "a//b", "a" * 101, ""].each do |name|
    it "rejects the name #{name[0, 12].inspect}" do
      collector.start_run
      collector.start_test
      expect(record(name: name)).to be(false)
      expect(collector.finish_test(**fields).comparisons).to be_nil
    end
  end

  it "rejects negative numbers and malformed sizes" do
    collector.start_run
    collector.start_test
    expect(record(max_diff_ratio: -1)).to be(false)
    expect(record(expected_size: [1])).to be(false)
    expect(collector.finish_test(**fields).comparisons).to be_nil
  end

  it "attaches a valid comparison to the result" do
    collector.start_run
    collector.start_test
    expect(record(name: "pages/home")).to be(true)
    comparisons = collector.finish_test(**fields).comparisons
    expect(comparisons.map(&:name)).to eq(["pages/home"])
    expect(comparisons.first.to_h.keys.first).to eq("name")
  end

  it "keeps only the comparisons of the last attempt" do
    collector.start_run
    collector.start_test
    record(name: "first")
    collector.start_test
    record(name: "second")
    expect(collector.finish_test(**fields).comparisons.map(&:name)).to eq(["second"])
  end

  it "does not leak comparisons into the next test" do
    collector.start_run
    collector.start_test
    record
    collector.finish_test(**fields)
    collector.start_test
    expect(collector.finish_test(**fields).comparisons).to be_nil
  end

  it "keeps 50 per result in the payload, failed ones first" do
    collector.start_run
    collector.start_test
    50.times { |i| record(name: "ok#{i}", status: "passed") }
    record(name: "bad", status: "failed")
    collector.finish_test(**fields)
    run = collector.finish_run(ci: nil, git: nil, environment: {})
    names = RaiderReporter::Payload.new(run).to_h(mode: :local)["results"].first["comparisons"].map { |c| c["name"] }
    expect(names.length).to eq(50)
    expect(names.first).to eq("bad")
  end
end
