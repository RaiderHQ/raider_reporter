# frozen_string_literal: true

RSpec.describe "RaiderReporter.attach" do
  let(:err) { StringIO.new }

  before do
    RaiderReporter.reset!
    @stderr = $stderr
    $stderr = err
  end

  after do
    $stderr = @stderr
    RaiderReporter.reset!
  end

  it "returns false and warns when no formatter collector is running" do
    expect(RaiderReporter.attach("screenshot", __FILE__, type: :png)).to be(false)
    expect(err.string).to include("[raider_reporter]").and include("outside")
  end

  it "returns false and warns when the file does not exist" do
    collector = RaiderReporter.start_collector!
    collector.start_run
    collector.start_test
    expect(RaiderReporter.attach("screenshot", "/nope/missing.png", type: :png)).to be(false)
    expect(err.string).to include("missing.png")
  end

  it "records an attachment with a resolved content type" do
    collector = RaiderReporter.start_collector!
    collector.start_run
    collector.start_test
    Dir.mktmpdir do |dir|
      path = File.join(dir, "clip.webm")
      File.binwrite(path, "v")
      expect(RaiderReporter.attach("video", path, type: :video)).to be(true)
      result = collector.finish_test(identifier: "i", full_name: "n", file_path: "f", line_number: 1,
                                     status: "passed", duration_ms: 1, attempts: 1, tags: [], failure: nil)
      expect(result.attachments.first.content_type).to eq("video/webm")
    end
  end

  it "maps explicit types" do
    expect(RaiderReporter::ContentTypes.resolve(:png, "a.bin")).to eq("image/png")
    expect(RaiderReporter::ContentTypes.resolve(:video, "a.mov")).to eq("video/quicktime")
    expect(RaiderReporter::ContentTypes.resolve(:video, "a.unknown")).to eq("video/mp4")
    expect(RaiderReporter::ContentTypes.resolve("text/csv", "a")).to eq("text/csv")
    expect(RaiderReporter::ContentTypes.resolve(nil, "a.json")).to eq("application/json")
    expect(RaiderReporter::ContentTypes.resolve(nil, "a.zzz")).to eq("application/octet-stream")
  end
end
