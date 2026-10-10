# frozen_string_literal: true

require "webmock/rspec"
require "raider_reporter/writers/uploader"

RSpec.describe RaiderReporter::Writers::Uploader do
  let(:config) do
    RaiderReporter::Configuration.new("RAIDER_TOKEN" => "secret", "RAIDER_ENDPOINT" => "https://raider.test/")
  end
  let(:url) { "https://raider.test/api/v1/runs" }

  def payload(dir)
    src = File.join(dir, "shot.png")
    File.binwrite(src, "PNG")
    att = RaiderReporter::Attachment.new(name: "screenshot", source_path: src, content_type: "image/png")
    result = RaiderReporter::TestResult.new(identifier: "i", full_name: "n", file_path: "f", line_number: 1,
                                            status: "failed", duration_ms: 1, attempts: 1, tags: [],
                                            failure: nil, attachments: [att])
    RaiderReporter::Payload.new(RaiderReporter::Run.new(client_run_id: "u", started_at: Time.now.utc,
                                                         finished_at: Time.now.utc, ci: nil, git: nil,
                                                         environment: {}, results: [result]))
  end

  it "posts multipart payload and parts with the bearer token" do
    stub_request(:post, url).to_return(status: 201, body: { run_id: 1, url: "https://raider.test/r/1" }.to_json)
    Dir.mktmpdir do |dir|
      result = described_class.new(config).upload(payload(dir))
      expect(result.ok).to be(true)
      expect(result.url).to eq("https://raider.test/r/1")
    end
    expect(a_request(:post, url).with { |req|
      req.headers["Authorization"] == "Bearer secret" &&
        req.headers["Content-Type"].start_with?("multipart/form-data") &&
        req.body.include?('name="payload"') && req.body.include?('name="att_0"') &&
        req.body.include?('"part":"att_0"')
    }).to have_been_made.once
  end

  it "treats 200 (duplicate run) as success" do
    stub_request(:post, url).to_return(status: 200, body: { run_id: 1, url: "https://raider.test/r/1" }.to_json)
    Dir.mktmpdir { |dir| expect(described_class.new(config).upload(payload(dir)).ok).to be(true) }
  end

  it "reports non-2xx responses without raising" do
    stub_request(:post, url).to_return(status: 413, body: '{"error":"payload too large"}')
    Dir.mktmpdir do |dir|
      result = described_class.new(config).upload(payload(dir))
      expect(result.ok).to be(false)
      expect(result.error).to include("413").and include("payload too large")
    end
  end

  it "reports timeouts without raising" do
    stub_request(:post, url).to_timeout
    Dir.mktmpdir { |dir| expect(described_class.new(config).upload(payload(dir)).error).to match(/timeout|Timeout/) }
  end

  it "reports a malformed endpoint without raising" do
    config.endpoint = "localhost:3000"
    Dir.mktmpdir { |dir| expect(described_class.new(config).upload(payload(dir)).ok).to be(false) }
  end
end
