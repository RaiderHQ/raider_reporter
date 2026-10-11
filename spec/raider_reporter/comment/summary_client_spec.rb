# frozen_string_literal: true

require "webmock/rspec"
require "raider_reporter"

RSpec.describe RaiderReporter::Comment::SummaryClient do
  subject(:client) { described_class.new(endpoint: "https://raider.test/", token: "tok") }

  let(:url) { "https://raider.test/api/v1/builds/summary" }

  it "returns a Summary on 200 and sends the bearer token" do
    stub = stub_request(:get, url).with(query: { build_key: "a b&c" }, headers: { "Authorization" => "Bearer tok" })
                                 .to_return(status: 200, body: { state: "failed", markdown: "md", url: "https://r/b/1" }.to_json)
    summary = client.fetch("a b&c")
    expect(summary).to eq(described_class::Summary.new(state: "failed", markdown: "md", url: "https://r/b/1"))
    expect(stub).to have_been_requested
    expect(client.last_error).to be_nil
  end

  it "returns nil with a reason on 401" do
    stub_request(:get, url).with(query: { build_key: "k" }).to_return(status: 401, body: '{"error":"unauthorized"}')
    expect(client.fetch("k")).to be_nil
    expect(client.last_error).to match(/401/)
  end

  it "returns nil with a reason on 404" do
    stub_request(:get, url).with(query: { build_key: "k" }).to_return(status: 404, body: '{"error":"not found"}')
    expect(client.fetch("k")).to be_nil
    expect(client.last_error).to match(/404/)
  end

  it "returns nil on other non-2xx" do
    stub_request(:get, url).with(query: { build_key: "k" }).to_return(status: 500, body: "boom")
    expect(client.fetch("k")).to be_nil
    expect(client.last_error).to match(/500/)
  end

  it "returns nil on timeout" do
    stub_request(:get, url).with(query: { build_key: "k" }).to_timeout
    expect(client.fetch("k")).to be_nil
    expect(client.last_error).to be_a(String)
  end

  it "returns nil on bad JSON or missing fields" do
    stub_request(:get, url).with(query: { build_key: "k" }).to_return(status: 200, body: "<html>")
    expect(client.fetch("k")).to be_nil
    expect(client.last_error).to match(/invalid/i)
    stub_request(:get, url).with(query: { build_key: "k" }).to_return(status: 200, body: '{"state":"failed"}')
    expect(client.fetch("k")).to be_nil
  end

  it "rejects a non-http endpoint" do
    bad = described_class.new(endpoint: "ftp://x", token: "tok")
    expect(bad.fetch("k")).to be_nil
    expect(bad.last_error).to match(/http/)
  end

  it "never puts the token in last_error" do
    c = described_class.new(endpoint: "https://raider.test", token: "s3cr3t-token")
    stub_request(:get, url).with(query: { build_key: "k" }).to_return(status: 500, body: "echo s3cr3t-token")
    expect(c.fetch("k")).to be_nil
    expect(c.last_error).not_to include("s3cr3t-token")
    stub_request(:get, url).with(query: { build_key: "k" }).to_raise(StandardError.new("boom s3cr3t-token"))
    expect(c.fetch("k")).to be_nil
    expect(c.last_error).not_to include("s3cr3t-token")
  end
end
