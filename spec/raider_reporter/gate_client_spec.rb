# frozen_string_literal: true

require "webmock/rspec"
require "raider_reporter"
require "raider_reporter/gate_client"

RSpec.describe RaiderReporter::GateClient do
  subject(:client) { described_class.new(endpoint: "https://raider.test/", token: "rt-secret") }

  let(:url) { "https://raider.test/api/v1/builds/gate" }
  let(:key) { "github_actions:RaiderHQ/demo:99:1" }
  let(:body) do
    { "state" => "pending", "build_state" => "incomplete", "shards" => { "received" => 1, "expected" => 2 },
      "rules" => [], "url" => "https://raider.test/projects/demo/builds/7" }
  end

  def stub_gate
    stub_request(:get, url).with(query: { "build_key" => key })
  end

  it "sends the token and an escaped build key and returns the verdict" do
    stub = stub_request(:get, "#{url}?build_key=github_actions%3ARaiderHQ%2Fdemo%3A99%3A1")
           .with(headers: { "Authorization" => "Bearer rt-secret", "Accept" => "application/json",
                            "User-Agent" => "raider_reporter/#{RaiderReporter::VERSION}" })
           .to_return(status: 200, body: JSON.generate(body))

    response = client.fetch(key)

    expect(stub).to have_been_requested
    expect(response).to have_attributes(kind: :verdict, data: body, code: 200, reason: nil)
  end

  it "uses 10-second open and read timeouts and no automatic retry" do
    options = nil
    allow(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, **kwargs, &block|
      options = kwargs.empty? ? args.last : kwargs
      original.call(*args, **kwargs, &block)
    end
    stub_gate.to_return(status: 200, body: JSON.generate(body))

    client.fetch(key)

    expect(options).to include(open_timeout: 10, read_timeout: 10, max_retries: 0)
  end

  {
    401 => [:rejected, nil], 403 => [:rejected, nil], 404 => [:not_found, nil],
    429 => [:retry, "HTTP 429"], 500 => [:retry, "HTTP 500"], 503 => [:retry, "HTTP 503"],
    418 => [:error, "RaiderReporter::GateClient::InvalidResponse: unexpected HTTP 418"]
  }.each do |code, (kind, reason)|
    it "classifies HTTP #{code} as #{kind}" do
      stub_gate.to_return(status: code, body: "{}")
      expect(client.fetch(key)).to have_attributes(kind: kind, code: code, reason: reason)
    end
  end

  it "classifies a timeout and a refused connection as retryable" do
    stub_gate.to_timeout
    expect(client.fetch(key)).to have_attributes(kind: :retry, reason: start_with("Net::OpenTimeout"))
    stub_gate.to_raise(Errno::ECONNREFUSED)
    expect(client.fetch(key)).to have_attributes(kind: :retry, reason: start_with("Errno::ECONNREFUSED"))
  end

  it "returns an error for a body that is not JSON" do
    stub_gate.to_return(status: 200, body: "<html>")
    expect(client.fetch(key)).to have_attributes(kind: :error, reason: start_with("JSON::ParserError: "))
  end

  it "redacts the token from an unparseable-JSON error" do
    stub_gate.to_return(status: 200, body: "rt-secret oops")
    response = client.fetch(key)
    expect(response.kind).to eq(:error)
    expect(response.reason).to start_with("JSON::ParserError: ")
    expect(response.reason).to include("[REDACTED]")
    expect(response.reason).not_to include("rt-secret")
  end

  [{ "state" => "maybe", "rules" => [] }, { "state" => "passed" }, ["passed"]].each do |payload|
    it "returns an error for an unexpected shape #{payload.inspect}" do
      stub_gate.to_return(status: 200, body: JSON.generate(payload))
      expect(client.fetch(key)).to have_attributes(
        kind: :error, reason: "RaiderReporter::GateClient::InvalidResponse: invalid gate response"
      )
    end
  end

  it "raises ArgumentError for an endpoint that is not http(s)" do
    expect { described_class.new(endpoint: "raider.test", token: "t").fetch(key) }
      .to raise_error(ArgumentError, "RAIDER_ENDPOINT must start with http:// or https://")
  end
end
