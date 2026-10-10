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

  def multi_payload(dir, sizes_per_result)
    index = 0
    results = sizes_per_result.map do |sizes|
      atts = sizes.map do |bytes|
        src = File.join(dir, "f#{index += 1}.txt")
        File.binwrite(src, "x" * bytes)
        RaiderReporter::Attachment.new(name: "a#{index}", source_path: src, content_type: "text/plain")
      end
      RaiderReporter::TestResult.new(identifier: "i#{index}", full_name: "n", file_path: "f", line_number: 1,
                                     status: "failed", duration_ms: 1, attempts: 1, tags: [],
                                     failure: nil, attachments: atts)
    end
    RaiderReporter::Payload.new(RaiderReporter::Run.new(client_run_id: "u", started_at: Time.now.utc,
                                                         finished_at: Time.now.utc, ci: nil, git: nil,
                                                         environment: {}, results: results))
  end

  def uploaded_payload_json
    body = nil
    expect(a_request(:post, url).with { |req| body = req.body }).to have_been_made.once
    json = body[/name="payload"\r\n\r\n(.*?)\r\n--/m, 1]
    [JSON.parse(json), body]
  end

  it "drops attachments beyond the byte budget from the upload with one warning" do
    stub_const("#{described_class}::MAX_UPLOAD_ATTACHMENT_BYTES", 7)
    stub_request(:post, url).to_return(status: 201, body: { run_id: 1, url: "u" }.to_json)
    warnings = []
    Dir.mktmpdir do |dir|
      payload = multi_payload(dir, [[3], [3, 3]])
      expect(described_class.new(config, warn: ->(m) { warnings << m }).upload(payload).ok).to be(true)
      expect(payload.to_h(mode: :local)["results"].sum { |r| r["attachments"].size }).to eq(3)
    end
    json, body = uploaded_payload_json
    expect(json["results"].map { |r| r["attachments"].map { |a| a["part"] } }).to eq([["att_0"], ["att_1"]])
    expect(body).to include('name="att_1"')
    expect(body).not_to include('name="att_2"')
    expect(warnings.size).to eq(1)
    expect(warnings.first).to include("1 attachment")
  end

  it "drops attachments beyond the part count limit from the upload" do
    stub_const("#{described_class}::MAX_UPLOAD_ATTACHMENTS", 2)
    stub_request(:post, url).to_return(status: 201, body: { run_id: 1, url: "u" }.to_json)
    warnings = []
    Dir.mktmpdir do |dir|
      described_class.new(config, warn: ->(m) { warnings << m }).upload(multi_payload(dir, [[1, 1], [1, 1]]))
    end
    json, body = uploaded_payload_json
    expect(json["results"].map { |r| r["attachments"].size }).to eq([2, 0])
    expect(body).not_to include('name="att_2"')
    expect(warnings.first).to include("2 attachments")
  end

  it "does not warn when everything fits" do
    stub_request(:post, url).to_return(status: 201, body: { run_id: 1, url: "u" }.to_json)
    warnings = []
    Dir.mktmpdir { |dir| described_class.new(config, warn: ->(m) { warnings << m }).upload(payload(dir)) }
    expect(warnings).to be_empty
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

  it "applies the timeout to connect, write and read" do
    stub_request(:post, url).to_return(status: 201, body: { run_id: 1, url: "u" }.to_json)
    options = nil
    allow(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, **kwargs, &block|
      options = kwargs
      original.call(*args, **kwargs, &block)
    end
    Dir.mktmpdir { |dir| described_class.new(config, timeout: 7).upload(payload(dir)) }
    expect(options).to include(open_timeout: 7, read_timeout: 7, write_timeout: 7)
  end

  it "sanitizes the multipart filename" do
    stub_request(:post, url).to_return(status: 201, body: { run_id: 1, url: "u" }.to_json)
    Dir.mktmpdir do |dir|
      src = File.join(dir, "we\\ird\"na me;.png")
      File.binwrite(src, "PNG")
      att = RaiderReporter::Attachment.new(name: "s", source_path: src, content_type: "image/png")
      run = payload(dir).run
      run = run.with(results: [run.results.first.with(attachments: [att])])
      described_class.new(config).upload(RaiderReporter::Payload.new(run))
    end
    expect(a_request(:post, url).with { |req| req.body.include?('filename="we_ird_na_me_.png"') })
      .to have_been_made.once
  end

  it "reports run_id when a 2xx response has no url" do
    stub_request(:post, url).to_return(status: 201, body: { run_id: 4 }.to_json)
    Dir.mktmpdir do |dir|
      result = described_class.new(config).upload(payload(dir))
      expect([result.ok, result.url, result.run_id]).to eq([true, nil, 4])
    end
  end

  it "treats a 2xx response with a non-JSON body as success" do
    stub_request(:post, url).to_return(status: 201, body: "ok")
    Dir.mktmpdir do |dir|
      result = described_class.new(config).upload(payload(dir))
      expect([result.ok, result.url, result.run_id]).to eq([true, nil, nil])
    end
  end
end
