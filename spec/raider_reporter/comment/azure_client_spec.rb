# frozen_string_literal: true

# REST reference (api-version 7.1 confirmed for all, including Statuses; no "-preview" needed):
#   Threads (List/Create/Update): https://learn.microsoft.com/en-us/rest/api/azure/devops/git/pull-request-threads/create?view=azure-devops-rest-7.1
#   Thread Comments (Update):     https://learn.microsoft.com/en-us/rest/api/azure/devops/git/pull-request-thread-comments/update?view=azure-devops-rest-7.1
#   Statuses (Create):            https://learn.microsoft.com/en-us/rest/api/azure/devops/git/pull-request-statuses/create?view=azure-devops-rest-7.1
require "webmock/rspec"
require "raider_reporter"

RSpec.describe RaiderReporter::Comment::AzureClient do
  subject(:client) { described_class.new(token: "tok-secret", base_url: "#{base}/") }

  let(:base) { "https://dev.azure.test/org/proj/_apis/git/repositories/repo/pullRequests/7" }
  let(:marker) { "<!-- raider-reporter:build-comment -->" }
  let(:md) { "#{marker}\n**Raider: failed**" }
  let(:prop) { { described_class::PROPERTY => { "$type" => "System.Int32", "$value" => 1 } } }
  let(:headers) { { "Authorization" => "Bearer tok-secret", "User-Agent" => "raider_reporter/#{RaiderReporter::VERSION}" } }
  let(:version) { described_class::API_VERSION }

  def stub_list(threads)
    stub_request(:get, "#{base}/threads").with(query: { "api-version" => version }, headers: headers)
                                         .to_return(status: 200, body: { value: threads, count: threads.size }.to_json)
  end

  def stub_create
    stub_request(:post, "#{base}/threads").with(query: { "api-version" => version })
                                          .to_return(status: 200, body: { id: 99 }.to_json)
  end

  it "uses 7.1 for both API versions" do
    expect(described_class::API_VERSION).to eq("7.1")
    expect(described_class::STATUS_API_VERSION).to eq("7.1")
  end

  it "creates a tagged thread when there are none" do
    stub_list([])
    expected = { comments: [{ parentCommentId: 0, content: md, commentType: 1 }], status: "active",
                 properties: prop }
    post = stub_request(:post, "#{base}/threads").with(query: { "api-version" => version }, headers: headers.merge("Content-Type" => "application/json"),
                                                       body: expected.to_json)
                                                 .to_return(status: 200, body: { id: 99 }.to_json)
    expect(client.upsert_thread(md, marker, status: "active")).to eq(:created)
    expect(post).to have_been_requested
  end

  it "updates our thread in place and sets its status" do
    stub_list([{ id: 11, properties: prop, comments: [{ id: 1, content: "#{marker}\nold", isDeleted: false }] }])
    comment = stub_request(:patch, "#{base}/threads/11/comments/1").with(query: { "api-version" => version }, headers: headers,
                                                                         body: { content: md }.to_json)
                                                                   .to_return(status: 200, body: "{}")
    thread = stub_request(:patch, "#{base}/threads/11").with(query: { "api-version" => version }, body: { status: "closed" }.to_json)
                                                       .to_return(status: 200, body: "{}")
    expect(client.upsert_thread(md, marker, status: "closed")).to eq(:updated)
    expect(comment).to have_been_requested
    expect(thread).to have_been_requested
  end

  it "ignores a human thread that quotes the marker" do
    stub_list([{ id: 5, properties: {}, comments: [{ id: 1, content: "#{marker}\nquoted" }] },
               { id: 6, comments: [{ id: 1, content: "#{marker}\nquoted" }] }])
    post = stub_create
    expect(client.upsert_thread(md, marker, status: "active")).to eq(:created)
    expect(post).to have_been_requested
  end

  it "ignores our thread when its first comment is deleted" do
    stub_list([{ id: 11, properties: prop, comments: [{ id: 1, content: "#{marker}\nold", isDeleted: true }] }])
    stub_create
    expect(client.upsert_thread(md, marker, status: "active")).to eq(:created)
  end

  it "tolerates system threads with missing comments, nil properties and odd shapes" do
    stub_list([{ id: 1 }, { id: 2, properties: nil, comments: nil }, { id: 3, properties: prop },
               { id: 4, properties: prop, comments: [] }, { id: 5, properties: prop, comments: ["x"] }, "junk", nil])
    stub_create
    expect(client.upsert_thread(md, marker, status: "active")).to eq(:created)
  end

  it "raises Error when the threads response is not { value: [...] }" do
    [[], { "value" => nil }, { "value" => {} }, {}].each do |body|
      stub_request(:get, "#{base}/threads").with(query: { "api-version" => version }).to_return(status: 200, body: body.to_json)
      expect { client.upsert_thread(md, marker, status: "active") }.to raise_error(described_class::Error, /unexpected threads/)
    end
  end

  it "posts a PR status and truncates the description to 140 characters" do
    body = { state: "failed", description: "x" * 140, targetUrl: "http://x/b/1", context: { genre: "raider", name: "tests" } }
    stub = stub_request(:post, "#{base}/statuses").with(query: { "api-version" => described_class::STATUS_API_VERSION },
                                                        headers: headers, body: body.to_json)
                                                  .to_return(status: 200, body: "{}")
    expect(client.set_status(state: "failed", description: "x" * 300, target_url: "http://x/b/1")).to be_nil
    expect(stub).to have_been_requested
  end

  it "sends the documented status body for a short description" do
    stub = stub_request(:post, "#{base}/statuses").with(
      query: { "api-version" => "7.1" },
      body: { state: "failed", description: "2 failed, 3 passed", targetUrl: "http://x/b/1",
              context: { genre: "raider", name: "tests" } }.to_json
    ).to_return(status: 200, body: "{}")
    client.set_status(state: "failed", description: "2 failed, 3 passed", target_url: "http://x/b/1")
    expect(stub).to have_been_requested
  end

  it "uses the given status name" do
    stub = stub_request(:post, "#{base}/statuses").with(
      query: { "api-version" => "7.1" },
      body: { state: "pending", description: "Waiting for the Raider verdict", targetUrl: nil,
              context: { genre: "raider", name: "gate" } }.to_json
    ).to_return(status: 200, body: "{}")
    client.set_status(state: "pending", description: "Waiting for the Raider verdict", target_url: nil, name: "gate")
    expect(stub).to have_been_requested
  end

  it "raises Forbidden on 401, 403 and 404" do
    [401, 403, 404].each do |code|
      stub_request(:get, "#{base}/threads").with(query: hash_including({})).to_return(status: code, body: "{}")
      expect { client.upsert_thread(md, marker, status: "active") }.to raise_error(described_class::Forbidden)
    end
    stub_request(:post, "#{base}/statuses").with(query: hash_including({})).to_return(status: 403, body: "{}")
    expect { client.set_status(state: "failed", description: "d", target_url: "u") }.to raise_error(described_class::Forbidden)
  end

  it "raises Error with the token redacted on a 500 and on network failures" do
    stub_request(:get, "#{base}/threads").with(query: hash_including({})).to_return(status: 500, body: "boom tok-secret")
    expect { client.upsert_thread(md, marker, status: "active") }
      .to raise_error(described_class::Error) { |e|
        expect(e.message).to include("500", "[REDACTED]")
        expect(e.message).not_to include("tok-secret")
      }
    stub_request(:get, "#{base}/threads").with(query: hash_including({})).to_timeout
    expect { client.upsert_thread(md, marker, status: "active") }.to raise_error(described_class::Error)
  end

  it "redacts a token that straddles the 200-character boundary before truncating" do
    stub_request(:get, "#{base}/threads").with(query: hash_including({}))
                                         .to_return(status: 500, body: ("a" * 195) + "tok-secret" + "z" * 50)
    expect { client.upsert_thread(md, marker, status: "active") }
      .to raise_error(described_class::Error) { |e|
        expect(e.message).not_to include("tok-", "secret")
      }
  end

  it "raises Error on invalid JSON" do
    stub_request(:get, "#{base}/threads").with(query: hash_including({})).to_return(status: 200, body: "<html>")
    expect { client.upsert_thread(md, marker, status: "active") }.to raise_error(described_class::Error, /invalid JSON/)
  end
end
