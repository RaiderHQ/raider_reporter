# frozen_string_literal: true

require "raider_reporter/ci_detector"

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
                              "build_url" => "https://github.com/RaiderHQ/demo/actions/runs/42", "build_id" => "42")
    expect(detector.git).to eq("branch" => "main", "commit_sha" => "abc", "commit_message" => "Local commit")
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
end
