# frozen_string_literal: true

require "webmock/rspec"
require "raider_reporter"
require "raider_reporter/gate_status"

RSpec.describe RaiderReporter::GateStatus do
  let(:fixtures) { File.expand_path("../fixtures/github_events", __dir__) }
  let(:warnings) { [] }
  let(:gh) { "https://api.github.test/repos/RaiderHQ/demo" }
  let(:github_env) do
    { "GITHUB_ACTIONS" => "true", "GITHUB_TOKEN" => "gh-secret", "GITHUB_REPOSITORY" => "RaiderHQ/demo",
      "GITHUB_API_URL" => "https://api.github.test", "GITHUB_SHA" => "mergesha111",
      "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_EVENT_PATH" => File.join(fixtures, "pull_request.json") }
  end

  def status_for(env)
    described_class.new(env: env, warn: ->(message) { warnings << message })
  end

  def record_posts(url, query: nil)
    posts = []
    stub = stub_request(:post, url)
    stub = stub.with(query: query) if query
    stub.to_return do |request|
      posts << JSON.parse(request.body)
      { status: 201, body: "{}" }
    end
    posts
  end

  describe "GitHub Actions" do
    it "posts to the pull request head commit on pull_request events, never the merge commit" do
      posts = record_posts("#{gh}/statuses/headsha222")
      status = status_for(github_env)

      expect(status).to be_active
      status.post(:pending, "Waiting for the Raider verdict")
      status.post(:failure, "pass rate: 96% < 98%", target_url: "https://raider.test/b/1")

      expect(posts).to eq([
        { "state" => "pending", "target_url" => nil, "context" => "raider/gate",
          "description" => "Waiting for the Raider verdict" },
        { "state" => "failure", "target_url" => "https://raider.test/b/1", "context" => "raider/gate",
          "description" => "pass rate: 96% < 98%" }
      ])
      expect(a_request(:post, "#{gh}/statuses/mergesha111")).not_to have_been_made
      expect(warnings).to eq([])
    end

    it "posts to GITHUB_SHA on push events" do
      posts = record_posts("#{gh}/statuses/pushsha333")
      env = github_env.merge("GITHUB_EVENT_NAME" => "push", "GITHUB_EVENT_PATH" => File.join(fixtures, "push.json"),
                             "GITHUB_SHA" => "pushsha333")

      status_for(env).post(:success, "Gate passed", target_url: "https://raider.test/b/1")

      expect(posts.map { |post| post.values_at("state", "description") }).to eq([%w[success Gate\ passed]])
    end

    it "maps error and truncates the description to 140 characters" do
      posts = record_posts("#{gh}/statuses/headsha222")
      status = status_for(github_env)
      status.post(:error, "No verdict")
      status.post(:failure, "x" * 300)
      expect(posts.map { |post| post["state"] }).to eq(%w[error failure])
      expect(posts.last["description"].length).to eq(140)
    end

    [
      ["GITHUB_TOKEN", { "GITHUB_TOKEN" => "" }],
      ["GITHUB_REPOSITORY", { "GITHUB_REPOSITORY" => nil }],
      ["a commit", { "GITHUB_EVENT_NAME" => "push", "GITHUB_SHA" => nil }]
    ].each do |label, overrides|
      it "is inactive and posts nothing without #{label}" do
        status = status_for(github_env.merge(overrides))
        expect(status).not_to be_active
        expect(status.post(:pending, "Waiting for the Raider verdict")).to be_nil
        expect(a_request(:any, /.*/)).not_to have_been_made
      end
    end

    it "warns with the client's redacted error and does not raise when a post fails" do
      stub_request(:post, "#{gh}/statuses/headsha222").to_return(status: 500, body: "boom gh-secret")
      expect(status_for(github_env).post(:pending, "Waiting for the Raider verdict")).to be_nil
      expect(warnings).to eq(["could not post the raider/gate status " \
                              "(RaiderReporter::Comment::GithubClient::Error: HTTP 500: boom [REDACTED])"])
    end

    it "warns on a read-only token" do
      stub_request(:post, "#{gh}/statuses/headsha222").to_return(status: 403, body: "{}")
      status_for(github_env).post(:pending, "Waiting for the Raider verdict")
      expect(warnings).to eq(["could not post the raider/gate status (RaiderReporter::Comment::GithubClient::Forbidden: HTTP 403)"])
    end
  end

  describe "Azure Pipelines" do
    let(:azure_env) do
      { "TF_BUILD" => "True", "SYSTEM_COLLECTIONURI" => "https://dev.azure.com/raider-test/",
        "SYSTEM_TEAMPROJECT" => "My Project", "SYSTEM_TEAMPROJECTID" => "6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c",
        "BUILD_REPOSITORY_NAME" => "web tests", "BUILD_REPOSITORY_ID" => "1c2bd1a0-3f63-4d93-9c3c-2b4f2b1d8f11",
        "BUILD_REPOSITORY_PROVIDER" => "TfsGit", "BUILD_BUILDID" => "42", "SYSTEM_STAGEATTEMPT" => "2",
        "BUILD_REASON" => "PullRequest", "SYSTEM_PULLREQUEST_PULLREQUESTID" => "7",
        "SYSTEM_PULLREQUEST_SOURCEBRANCH" => "refs/heads/feature/login",
        "SYSTEM_PULLREQUEST_TARGETBRANCH" => "refs/heads/main", "SYSTEM_PULLREQUEST_SOURCECOMMITID" => "headsha",
        "SYSTEM_ACCESSTOKEN" => "az-secret" }
    end
    let(:pr_base) do
      "https://dev.azure.com/raider-test/6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c/_apis/git/repositories/" \
        "1c2bd1a0-3f63-4d93-9c3c-2b4f2b1d8f11/pullRequests/7"
    end

    it "posts a PR status named raider/gate with Azure's state names" do
      posts = record_posts("#{pr_base}/statuses", query: { "api-version" => "7.1" })
      status = status_for(azure_env)

      expect(status).to be_active
      { pending: "pending", success: "succeeded", failure: "failed", error: "error" }.each_key do |state|
        status.post(state, "d", target_url: "https://raider.test/b/1")
      end

      expect(posts.map { |post| post["state"] }).to eq(%w[pending succeeded failed error])
      expect(posts.first).to eq("state" => "pending", "description" => "d", "targetUrl" => "https://raider.test/b/1",
                                "context" => { "genre" => "raider", "name" => "gate" })
      expect(a_request(:post, "#{pr_base}/statuses").with(query: hash_including({}),
                                                          headers: { "Authorization" => "Bearer az-secret" })).to have_been_made.times(4)
    end

    it "posts nothing on a build that is not an Azure Repos pull request" do
      status = status_for(azure_env.merge("BUILD_REASON" => "IndividualCI"))
      expect(status).not_to be_active
      status.post(:pending, "Waiting for the Raider verdict")
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "is inactive when SYSTEM_ACCESSTOKEN is an undefined macro" do
      expect(status_for(azure_env.merge("SYSTEM_ACCESSTOKEN" => "$(System.AccessToken)"))).not_to be_active
    end
  end

  it "is inactive outside CI" do
    expect(status_for({})).not_to be_active
  end
end
