# frozen_string_literal: true

require "webmock/rspec"
require "raider_reporter"

RSpec.describe RaiderReporter::Comment::GithubClient do
  subject(:client) { described_class.new(token: "gh", repository: "Raider/demo", api_url: "https://api.github.test/") }

  let(:base) { "https://api.github.test/repos/Raider/demo" }
  let(:marker) { "<!-- raider-reporter:build-comment -->" }
  let(:headers) do
    { "Authorization" => "Bearer gh", "Accept" => "application/vnd.github+json", "X-GitHub-Api-Version" => "2022-11-28" }
  end

  def list(page, comments)
    stub_request(:get, "#{base}/issues/7/comments").with(query: { per_page: 100, page: page }, headers: headers)
                                                  .to_return(status: 200, body: comments.to_json)
  end

  it "creates a comment when none carries the marker" do
    list(1, [{ id: 1, body: "hello" }])
    post = stub_request(:post, "#{base}/issues/7/comments").with(headers: headers, body: { body: "#{marker}\nx" }.to_json)
                                                           .to_return(status: 201, body: { html_url: "https://gh/c/9" }.to_json)
    expect(client.upsert_comment(7, "#{marker}\nx", marker)).to eq("https://gh/c/9")
    expect(post).to have_been_requested
  end

  it "updates the marked comment found on page 2" do
    list(1, Array.new(100) { |i| { id: i + 1, body: "c#{i}" } })
    list(2, [{ id: 500, body: "other" }, { id: 501, body: "#{marker}\nold" }])
    patch = stub_request(:patch, "#{base}/issues/comments/501").with(body: { body: "#{marker}\nnew" }.to_json)
                                                               .to_return(status: 200, body: { html_url: "https://gh/c/501" }.to_json)
    expect(client.upsert_comment(7, "#{marker}\nnew", marker)).to eq("https://gh/c/501")
    expect(patch).to have_been_requested
  end

  it "stops listing after 10 pages and creates" do
    (1..10).each { |p| list(p, Array.new(100) { |i| { id: (p * 1000) + i, body: "c" } }) }
    stub_request(:post, "#{base}/issues/7/comments").to_return(status: 201, body: { html_url: "u" }.to_json)
    expect(client.upsert_comment(7, "#{marker}\nx", marker)).to eq("u")
    expect(a_request(:get, /comments\?.*page=11/)).not_to have_been_made
  end

  it "raises Forbidden on 403 and 404" do
    stub_request(:get, "#{base}/issues/7/comments").with(query: hash_including({})).to_return(status: 403, body: "{}")
    expect { client.upsert_comment(7, "b", marker) }.to raise_error(described_class::Forbidden)
    stub_request(:post, "#{base}/statuses/abc").to_return(status: 404, body: "{}")
    expect { client.set_status("abc", state: "success", target_url: "u", description: "d", context: "c") }
      .to raise_error(described_class::Forbidden)
  end

  it "raises Error on timeout and other failures" do
    stub_request(:get, "#{base}/issues/7/comments").with(query: hash_including({})).to_timeout
    expect { client.upsert_comment(7, "b", marker) }.to raise_error(described_class::Error)
    stub_request(:get, "#{base}/issues/7/comments").with(query: hash_including({})).to_return(status: 500, body: "x")
    expect { client.upsert_comment(7, "b", marker) }.to raise_error(described_class::Error, /500/)
  end

  it "posts a commit status with the description truncated to 140 characters" do
    stub = stub_request(:post, "#{base}/statuses/abc123").with(headers: headers) do |req|
      body = JSON.parse(req.body)
      body["description"].length == 140 && body["state"] == "failure" && body["context"] == "raider/tests" &&
        body["target_url"] == "https://r/b/1"
    end.to_return(status: 201, body: "{}")
    client.set_status("abc123", state: "failure", target_url: "https://r/b/1", description: "x" * 300,
                                context: "raider/tests")
    expect(stub).to have_been_requested
  end
end
