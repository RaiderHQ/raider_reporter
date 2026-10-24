# frozen_string_literal: true

require "webmock/rspec"
require_relative "../support/fake_raider"

RSpec.describe RaiderReporter::Quarantine do
  let(:url) { "https://raider.test/api/v1/quarantine" }
  let(:warnings) { [] }
  let(:warn) { ->(message) { warnings << message } }
  let(:key) { RaiderReporter.test_key("spec/login_spec.rb", "Login works") }
  let(:body) do
    JSON.generate("quarantined" => [{ "test_key" => key, "expires_at" => "2026-11-07T12:00:00Z" },
                                    { "test_key" => 42 }, { "expires_at" => "x" }, "junk"])
  end

  def config(endpoint: "https://raider.test/", token: "tok", quarantine: true)
    RaiderReporter::Configuration.new({}).tap do |c|
      c.endpoint = endpoint
      c.token = token
      c.quarantine = quarantine
    end
  end

  it "returns the frozen set of test keys and sends the token" do
    stub = stub_request(:get, url)
           .with(headers: { "Authorization" => "Bearer tok", "Accept" => "application/json" })
           .to_return(status: 200, body: body)

    keys = described_class.load(config, warn: warn)

    expect(keys).to eq(Set[key])
    expect(keys).to be_frozen
    expect(stub).to have_been_requested.once
    expect(warnings).to be_empty
  end

  it "makes no request when quarantine is off or the token is missing" do
    expect(described_class.load(config(quarantine: false), warn: warn)).to be_empty
    expect(described_class.load(config(token: nil), warn: warn)).to be_empty
    expect(a_request(:any, /raider\.test/)).not_to have_been_made
    expect(warnings).to be_empty
  end

  {
    "a 401" => [->(s) { s.to_return(status: 401, body: '{"error":"unauthorized"}') }, "HTTP 401"],
    "a 500" => [->(s) { s.to_return(status: 500, body: "boom") }, "HTTP 500"],
    "invalid JSON" => [->(s) { s.to_return(status: 200, body: "<html>") }, "invalid JSON"],
    "a list that is not an array" => [->(s) { s.to_return(status: 200, body: '{"quarantined":"x"}') }, "unexpected response"],
    "a JSON array body" => [->(s) { s.to_return(status: 200, body: "[]") }, "unexpected response"],
    "a timeout" => [->(s) { s.to_timeout }, /Net::OpenTimeout|execution expired/]
  }.each do |label, (respond, reason)|
    it "quarantines nothing and warns once on #{label}" do
      respond.call(stub_request(:get, url))

      expect(described_class.load(config, warn: warn)).to eq(Set.new)
      expect(warnings.size).to eq(1)
      expect(warnings.first).to start_with("quarantine list unavailable (").and end_with("); no tests quarantined")
      expect(warnings.first).to match(reason)
    end
  end

  it "rejects a non-http endpoint without a request" do
    expect(described_class.load(config(endpoint: "localhost:3000"), warn: warn)).to be_empty
    expect(warnings).to eq(["quarantine list unavailable (RAIDER_ENDPOINT must start with http:// or https://); " \
                            "no tests quarantined"])
  end

  it "never puts the token in the warning" do
    stub_request(:get, url).to_raise(StandardError.new("boom s3cr3t"))
    described_class.load(config(token: "s3cr3t"), warn: warn)
    expect(warnings.first).to include("[REDACTED]")
    expect(warnings.first).not_to include("s3cr3t")
  end

  it "starts the request with 3 second open and read timeouts" do
    stub_request(:get, url).to_return(status: 200, body: body)
    expect(Net::HTTP).to receive(:start)
      .with("raider.test", 443, hash_including(open_timeout: 3, read_timeout: 3)).and_call_original

    described_class.load(config, warn: warn)
  end

  context "against a real socket" do
    around do |example|
      WebMock.allow_net_connect!
      example.run
    ensure
      WebMock.disable_net_connect!
    end

    before { stub_const("RaiderReporter::Quarantine::TIMEOUT", 0.5) }

    %i[hang trickle].each do |behaviour|
      it "gives up on a server that #{behaviour}s instead of answering" do
        server = FakeRaider.new { [behaviour] }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        keys = described_class.load(config(endpoint: server.url), warn: warn)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
        expect(keys).to be_empty
        expect(warnings.size).to eq(1)
      ensure
        server&.close
      end
    end
  end

  describe "RaiderReporter.quarantined_keys" do
    around do |example|
      RaiderReporter.reset!
      example.run
    ensure
      RaiderReporter.reset!
    end

    it "is fetched once per process, when the run starts" do
      stub = stub_request(:get, url).to_return(status: 200, body: body)
      RaiderReporter.configure do |c|
        c.token = "tok"
        c.endpoint = "https://raider.test"
        c.quarantine = true
      end

      collector = RaiderReporter.start_collector!
      expect(stub).not_to have_been_requested
      collector.start_run
      RaiderReporter.start_collector!.start_run

      expect(stub).to have_been_requested.once
      expect(RaiderReporter.collector.quarantined?("spec/login_spec.rb", "Login works")).to be(true)
    end
  end
end
