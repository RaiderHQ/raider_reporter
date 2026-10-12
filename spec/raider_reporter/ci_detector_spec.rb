# frozen_string_literal: true

require "raider_reporter/ci_detector"
require "tmpdir"

RSpec.describe RaiderReporter::CiDetector do
  let(:git_calls) { [] }
  let(:git) do
    lambda do |*args|
      git_calls << args
      { %w[rev-parse --abbrev-ref HEAD] => "local-branch", %w[rev-parse HEAD] => "localsha",
        %w[log -1 --pretty=%s] => "Local commit" }[args]
    end
  end

  it "detects GitHub Actions on a push" do
    env = { "GITHUB_ACTIONS" => "true", "GITHUB_SERVER_URL" => "https://github.com",
            "GITHUB_REPOSITORY" => "RaiderHQ/demo", "GITHUB_RUN_ID" => "42",
            "GITHUB_REF_NAME" => "main", "GITHUB_HEAD_REF" => "", "GITHUB_SHA" => "abc" }
    detector = described_class.new(env: env, git: git)
    expect(detector.ci).to eq("provider" => "github_actions",
                              "build_url" => "https://github.com/RaiderHQ/demo/actions/runs/42", "build_id" => "42",
                              "attempt" => "1", "build_key" => "github_actions:RaiderHQ/demo:42:1",
                              "repository" => "RaiderHQ/demo")
    expect(detector.git).to eq("branch" => "main", "commit_sha" => "abc", "commit_message" => "Local commit")
  end

  it "adds attempt, job and a build key on GitHub Actions" do
    env = { "GITHUB_ACTIONS" => "true", "GITHUB_SERVER_URL" => "https://github.com",
            "GITHUB_REPOSITORY" => "RaiderHQ/demo", "GITHUB_RUN_ID" => "42", "GITHUB_RUN_ATTEMPT" => "2",
            "GITHUB_JOB" => "rspec", "GITHUB_SHA" => "abc" }
    ci = described_class.new(env: env, git: git).ci
    expect(ci).to include("attempt" => "2", "job" => "rspec",
                          "build_key" => "github_actions:RaiderHQ/demo:42:2")
  end

  it "defaults the attempt to 1 and omits the build key without a run id" do
    with_attempt = described_class.new(env: { "GITHUB_ACTIONS" => "true", "GITHUB_REPOSITORY" => "R/d", "GITHUB_RUN_ID" => "7" }, git: git).ci
    expect(with_attempt["build_key"]).to eq("github_actions:R/d:7:1")
    without_id = described_class.new(env: { "GITHUB_ACTIONS" => "true" }, git: git).ci
    expect(without_id).not_to have_key("build_key")
  end

  it "uses the PR head branch on pull_request events" do
    env = { "GITHUB_ACTIONS" => "true", "GITHUB_REF_NAME" => "7/merge", "GITHUB_HEAD_REF" => "feature-x",
            "GITHUB_SHA" => "abc" }
    expect(described_class.new(env: env, git: git).git["branch"]).to eq("feature-x")
  end

  it "falls back to local git outside CI" do
    detector = described_class.new(env: {}, git: git)
    expect(detector.ci).to be_nil
    expect(detector.git).to eq("branch" => "local-branch", "commit_sha" => "localsha", "commit_message" => "Local commit")
  end

  it "returns nil git info when git is unavailable" do
    expect(described_class.new(env: {}, git: ->(*) {}).git).to be_nil
  end

  it "drops the branch on a detached HEAD" do
    detached = ->(*args) { args == %w[rev-parse --abbrev-ref HEAD] ? "HEAD" : git.call(*args) }
    info = described_class.new(env: {}, git: detached).git
    expect(info).not_to have_key("branch")
    expect(info["commit_sha"]).to eq("localsha")
  end

  it "reads git output without mixing in stderr" do
    ok = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return(["feature-z\n", "warning: noise\n", ok])
    expect(described_class.new(env: {}).git["branch"]).to eq("feature-z")
  end

  describe "GitHub event data" do
    def fixture(name)
      JSON.parse(File.read(File.expand_path("../fixtures/github_events/#{name}.json", __dir__)))
    end

    let(:pr_env) do
      { "GITHUB_ACTIONS" => "true", "GITHUB_REPOSITORY" => "RaiderHQ/demo", "GITHUB_RUN_ID" => "42",
        "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_HEAD_REF" => "feature-x", "GITHUB_SHA" => "mergesha" }
    end

    it "reports the default branch on a push, without a pr" do
      env = { "GITHUB_ACTIONS" => "true", "GITHUB_EVENT_NAME" => "push", "GITHUB_REF_NAME" => "main", "GITHUB_SHA" => "abc" }
      info = described_class.new(env: env, git: git, event_reader: -> { fixture("push") }).git
      expect(info).to eq("branch" => "main", "commit_sha" => "abc", "commit_message" => "Local commit",
                         "default_branch" => "main")
    end

    it "reports the PR identity and head commit on pull_request" do
      info = described_class.new(env: pr_env, git: git, event_reader: -> { fixture("pull_request") }).git
      expect(info).to include("branch" => "feature-x", "commit_sha" => "headsha222", "default_branch" => "main",
                              "pr" => { "number" => 7, "base_branch" => "main", "head_branch" => "feature-x",
                                        "head_sha" => "headsha222" })
    end

    it "reports no pr when the event lacks the head sha or the head/base refs" do
      [%w[head sha], %w[head ref], %w[base ref]].each do |side, key|
        event = fixture("pull_request")
        event["pull_request"][side].delete(key)
        info = described_class.new(env: pr_env, git: git, event_reader: -> { event }).git
        expect(info["pr"]).to be_nil, "expected no pr without #{side}.#{key}"
      end
    end

    it "reports the PR on pull_request_target and for fork PRs" do
      env = pr_env.merge("GITHUB_EVENT_NAME" => "pull_request_target", "GITHUB_HEAD_REF" => "patch-1")
      info = described_class.new(env: env, git: git, event_reader: -> { fixture("fork_pull_request") }).git
      expect(info["pr"]).to eq("number" => 12, "base_branch" => "main", "head_branch" => "patch-1",
                               "head_sha" => "forksha444")
      expect(info["commit_sha"]).to eq("forksha444")
    end

    it "adds the repository to ci" do
      expect(described_class.new(env: pr_env, git: git, event_reader: -> {}).ci["repository"]).to eq("RaiderHQ/demo")
    end

    it "leaves today's output unchanged when the event is missing" do
      env = { "GITHUB_ACTIONS" => "true", "GITHUB_REF_NAME" => "main", "GITHUB_SHA" => "abc" }
      info = described_class.new(env: env, git: git, event_reader: -> {}).git
      expect(info).to eq("branch" => "main", "commit_sha" => "abc", "commit_message" => "Local commit")
    end

    it "ignores an invalid or unreadable event file" do
      Dir.mktmpdir do |dir|
        bad = File.join(dir, "event.json")
        File.write(bad, "{not json")
        env = pr_env.merge("GITHUB_EVENT_PATH" => bad)
        expect(described_class.new(env: env, git: git).git).to eq(
          "branch" => "feature-x", "commit_sha" => "mergesha", "commit_message" => "Local commit"
        )
        env = pr_env.merge("GITHUB_EVENT_PATH" => File.join(dir, "nope.json"))
        expect(described_class.new(env: env, git: git).git).not_to have_key("pr")
      end
    end

    it "reads the event from GITHUB_EVENT_PATH by default" do
      path = File.expand_path("../fixtures/github_events/pull_request.json", __dir__)
      info = described_class.new(env: pr_env.merge("GITHUB_EVENT_PATH" => path), git: git).git
      expect(info["pr"]["number"]).to eq(7)
    end

    it "drops pr when the number is not numeric" do
      event = fixture("pull_request")
      event["pull_request"]["number"] = "seven"
      info = described_class.new(env: pr_env, git: git, event_reader: -> { event }).git
      expect(info).not_to have_key("pr")
      expect(info["commit_sha"]).to eq("mergesha")
    end

    it "ignores pr data on non-PR events" do
      env = pr_env.merge("GITHUB_EVENT_NAME" => "push")
      info = described_class.new(env: env, git: git, event_reader: -> { fixture("pull_request") }).git
      expect(info).not_to have_key("pr")
    end

    it "takes the commit message from HEAD^2 when HEAD is a merge commit" do
      fake = lambda do |*args|
        { %w[rev-list --parents -n 1 HEAD] => "merge p1 p2", %w[log -1 --format=%s HEAD^2] => "Author's message",
          %w[log -1 --pretty=%s] => "Merge abc into def" }[args] || git.call(*args)
      end
      info = described_class.new(env: pr_env, git: fake, event_reader: -> { fixture("pull_request") }).git
      expect(info["commit_message"]).to eq("Author's message")
    end

    it "keeps the current message when HEAD is not a merge commit" do
      fake = lambda do |*args|
        { %w[rev-list --parents -n 1 HEAD] => "c p1" }[args] || git.call(*args)
      end
      info = described_class.new(env: pr_env, git: fake, event_reader: -> { fixture("pull_request") }).git
      expect(info["commit_message"]).to eq("Local commit")
    end
  end

  describe "Azure Pipelines" do
    let(:azure_env) do
      { "TF_BUILD" => "True", "SYSTEM_COLLECTIONURI" => "https://dev.azure.com/raider-test/",
        "SYSTEM_TEAMPROJECT" => "My Project", "SYSTEM_TEAMPROJECTID" => "6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c",
        "BUILD_REPOSITORY_NAME" => "web tests", "BUILD_REPOSITORY_ID" => "1c2bd1a0-3f63-4d93-9c3c-2b4f2b1d8f11",
        "BUILD_REPOSITORY_PROVIDER" => "TfsGit", "BUILD_BUILDID" => "42", "SYSTEM_STAGEATTEMPT" => "2",
        "SYSTEM_JOBDISPLAYNAME" => "tests", "BUILD_REASON" => "PullRequest",
        "BUILD_SOURCEBRANCH" => "refs/pull/7/merge", "BUILD_SOURCEVERSION" => "mergesha",
        "SYSTEM_PULLREQUEST_PULLREQUESTID" => "7", "SYSTEM_PULLREQUEST_SOURCEBRANCH" => "refs/heads/feature/login",
        "SYSTEM_PULLREQUEST_TARGETBRANCH" => "refs/heads/main", "SYSTEM_PULLREQUEST_SOURCECOMMITID" => "headsha" }
    end
    let(:ci_env) do
      azure_env.merge("BUILD_REASON" => "IndividualCI", "BUILD_SOURCEBRANCH" => "refs/heads/release/1.2",
                      "BUILD_SOURCEVERSION" => "abc").reject { |k, _| k.start_with?("SYSTEM_PULLREQUEST") }
    end

    def detect(env, git_stub = git) = described_class.new(env: env, git: git_stub)

    it "reports ci for an Azure Repos PR build" do
      expect(detect(azure_env).ci).to eq(
        "provider" => "azure_pipelines",
        "build_url" => "https://dev.azure.com/raider-test/My%20Project/_build/results?buildId=42",
        "build_id" => "42", "attempt" => "2", "job" => "tests",
        "build_key" => "azure_pipelines:dev.azure.com/raider-test/6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c/1c2bd1a0-3f63-4d93-9c3c-2b4f2b1d8f11:42:2",
        "repository" => "My Project/web tests"
      )
    end

    it "reports git with the PR url, head sha and HEAD^2 message, without a default branch" do
      fake = lambda do |*args|
        { %w[rev-list --parents -n 1 HEAD] => "merge p1 p2", %w[log -1 --format=%s HEAD^2] => "Author's message" }[args] || git.call(*args)
      end
      expect(detect(azure_env, fake).git).to eq(
        "branch" => "feature/login", "commit_sha" => "headsha", "commit_message" => "Author's message",
        "pr" => { "number" => 7, "base_branch" => "main", "head_branch" => "feature/login", "head_sha" => "headsha",
                  "url" => "https://dev.azure.com/raider-test/My%20Project/_git/web%20tests/pullrequest/7" }
      )
    end

    it "handles a CI (push) build and defaults the attempt to 1" do
      env = ci_env.tap { |e| e.delete("SYSTEM_STAGEATTEMPT") }
      detector = detect(env)
      expect(detector.ci["attempt"]).to eq("1")
      info = detector.git
      expect(info).to include("branch" => "release/1.2", "commit_sha" => "abc")
      expect(info).not_to have_key("pr")
    end

    it "falls back to git for the branch on a tag build" do
      detached = ->(*args) { args == %w[rev-parse --abbrev-ref HEAD] ? "HEAD" : git.call(*args) }
      info = detect(ci_env.merge("BUILD_SOURCEBRANCH" => "refs/tags/v1"), detached).git
      expect(info).not_to have_key("branch")
      expect(detect(ci_env.merge("BUILD_SOURCEBRANCH" => "refs/tags/v1")).git["branch"]).to eq("local-branch")
    end

    it "reports ci but no pr for a GitHub-hosted repo built by Azure" do
      env = azure_env.merge("BUILD_REPOSITORY_PROVIDER" => "GitHub", "SYSTEM_PULLREQUEST_PULLREQUESTNUMBER" => "9")
      detector = detect(env)
      expect(detector.ci["provider"]).to eq("azure_pipelines")
      expect(detector.git).not_to have_key("pr")
    end

    it "reports no pr for an invalid pull request id" do
      %w[abc 0].each do |id|
        expect(detect(azure_env.merge("SYSTEM_PULLREQUEST_PULLREQUESTID" => id)).git).not_to have_key("pr")
      end
    end

    it "supports the legacy visualstudio.com collection without a trailing slash" do
      ci = detect(azure_env.merge("SYSTEM_COLLECTIONURI" => "https://raider-test.visualstudio.com")).ci
      expect(ci["build_url"]).to eq("https://raider-test.visualstudio.com/My%20Project/_build/results?buildId=42")
      expect(ci["build_key"]).to start_with("azure_pipelines:raider-test.visualstudio.com/6ce954b1")
    end

    it "omits the build key without BUILD_REPOSITORY_ID" do
      ci = detect(azure_env.tap { |e| e.delete("BUILD_REPOSITORY_ID") }).ci
      expect(ci).not_to have_key("build_key")
      expect(ci).to include("build_id" => "42", "provider" => "azure_pipelines")
    end

    it "treats unexpanded macros as missing" do
      ci = detect(azure_env.merge("BUILD_REPOSITORY_ID" => "$(Build.Repository.ID)")).ci
      expect(ci).not_to have_key("build_key")
    end

    it "prefers GitHub when both providers are set" do
      env = azure_env.merge("GITHUB_ACTIONS" => "true", "GITHUB_REPOSITORY" => "R/d", "GITHUB_RUN_ID" => "7")
      expect(detect(env).ci["provider"]).to eq("github_actions")
    end
  end

  describe "GitHub PR url" do
    let(:env) do
      { "GITHUB_ACTIONS" => "true", "GITHUB_SERVER_URL" => "https://github.com", "GITHUB_REPOSITORY" => "RaiderHQ/demo",
        "GITHUB_EVENT_NAME" => "pull_request", "GITHUB_HEAD_REF" => "feature-x", "GITHUB_SHA" => "mergesha" }
    end
    let(:event) { JSON.parse(File.read(File.expand_path("../fixtures/github_events/pull_request.json", __dir__))) }

    it "adds the pull request url" do
      pr = described_class.new(env: env, git: git, event_reader: -> { event }).git["pr"]
      expect(pr["url"]).to eq("https://github.com/RaiderHQ/demo/pull/7")
    end

    it "omits the url without server url or repository" do
      %w[GITHUB_SERVER_URL GITHUB_REPOSITORY].each do |key|
        pr = described_class.new(env: env.reject { |k, _| k == key }, git: git, event_reader: -> { event }).git["pr"]
        expect(pr).not_to have_key("url")
      end
    end
  end
end
