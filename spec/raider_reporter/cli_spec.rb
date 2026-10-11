# frozen_string_literal: true

require "webmock/rspec"
require "open3"
require "stringio"
require "tmpdir"
require "raider_reporter"
require "raider_reporter/cli"

RSpec.describe RaiderReporter::CLI do
  let(:fixtures) { File.expand_path("../fixtures/github_events", __dir__) }
  let(:env) do
    { "GITHUB_ACTIONS" => "true", "GITHUB_TOKEN" => "gh", "GITHUB_REPOSITORY" => "RaiderHQ/demo",
      "GITHUB_EVENT_PATH" => File.join(fixtures, "pull_request.json"), "GITHUB_EVENT_NAME" => "pull_request",
      "GITHUB_RUN_ID" => "99", "GITHUB_RUN_ATTEMPT" => "1", "RAIDER_TOKEN" => "rt",
      "RAIDER_ENDPOINT" => "https://raider.test", "GITHUB_API_URL" => "https://api.github.test" }
  end
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:argv) { ["comment"] }
  let(:markdown) { "<!-- raider-reporter:build-comment -->\n**Raider: failed** - 2 failed, 148 passed, 3 skipped (1m 12s)\n" }
  let(:state) { "failed" }
  let(:gh) { "https://api.github.test/repos/RaiderHQ/demo" }

  def run_cli
    described_class.new(argv, env: env, out: out, err: err).run
  end

  def stub_summary(state: self.state, markdown: self.markdown)
    stub_request(:get, "https://raider.test/api/v1/builds/summary")
      .with(query: { build_key: "github_actions:RaiderHQ/demo:99:1" }, headers: { "Authorization" => "Bearer rt" })
      .to_return(status: 200, body: { state: state, markdown: markdown, url: "https://raider.test/b/1" }.to_json)
  end

  def stub_comment
    stub_request(:get, "#{gh}/issues/7/comments").with(query: hash_including({})).to_return(status: 200, body: "[]")
    stub_request(:post, "#{gh}/issues/7/comments").to_return(status: 201, body: { html_url: "https://gh/c/1" }.to_json)
  end

  def stub_status(sha = "headsha222")
    stub_request(:post, "#{gh}/statuses/#{sha}").to_return(status: 201, body: "{}")
  end

  after { expect(out.string).to eq("") }

  it "prints usage for an unknown subcommand and exits 0" do
    expect(described_class.new(["bogus"], env: env, out: out, err: err).run).to eq(0)
    expect(err.string).to include("Usage: raider-reporter comment")
  end

  it "prints usage for --help and for no arguments" do
    expect(described_class.new(["--help"], env: env, out: out, err: err).run).to eq(0)
    expect(described_class.new([], env: env, out: out, err: err).run).to eq(0)
    expect(err.string.scan("Usage:").size).to eq(2)
  end

  it "skips with a notice when the event is not a pull request" do
    env["GITHUB_EVENT_PATH"] = File.join(fixtures, "push.json")
    env["GITHUB_EVENT_NAME"] = "push"
    expect(run_cli).to eq(0)
    expect(err.string).to eq("[raider_reporter] skipped: not a pull request event\n")
  end

  it "names every missing environment variable" do
    env.delete("RAIDER_TOKEN")
    env["GITHUB_TOKEN"] = ""
    expect(run_cli).to eq(0)
    expect(err.string).to include("[raider_reporter] skipped: missing GITHUB_TOKEN, RAIDER_TOKEN")
  end

  it "notes an unreadable event file" do
    env["GITHUB_EVENT_PATH"] = "/nonexistent/event.json"
    expect(run_cli).to eq(0)
    expect(err.string).to include("not a pull request event")
  end

  it "reports an unavailable summary with the reason" do
    stub_request(:get, "https://raider.test/api/v1/builds/summary").with(query: hash_including({})).to_return(status: 404, body: "{}")
    expect(run_cli).to eq(0)
    expect(err.string).to include("[raider_reporter] summary unavailable: HTTP 404")
  end

  it "upserts the comment, sets a failure status from the headline counts and prints the success line" do
    stub_summary
    stub_comment
    status = stub_status.with(body: { state: "failure", target_url: "https://raider.test/b/1",
                                      context: "raider/tests", description: "2 failed, 148 passed, 3 skipped" }.to_json)
    expect(run_cli).to eq(0)
    expect(status).to have_been_requested
    expect(err.string).to eq("[raider_reporter] PR comment updated: https://gh/c/1\n")
  end

  {
    "passed" => ["success", "Raider: tests passed"],
    "failed" => ["failure", "Raider: tests failed"],
    "incomplete" => ["pending", "Raider: build incomplete"]
  }.each do |summary_state, (gh_state, text)|
    it "maps #{summary_state} to #{gh_state} with fixed text when the Markdown has no counts" do
      stub_summary(state: summary_state, markdown: "<!-- raider-reporter:build-comment -->\nSomething else\n")
      stub_comment
      status = stub_status.with(body: hash_including("state" => gh_state, "description" => text))
      expect(run_cli).to eq(0)
      expect(status).to have_been_requested
    end
  end

  it "maps an unknown state to pending" do
    stub_summary(state: "unknown", markdown: "x")
    stub_comment
    status = stub_status.with(body: hash_including("state" => "pending"))
    run_cli
    expect(status).to have_been_requested
  end

  it "falls back to fixed text when the headline has no counts" do
    stub_summary(markdown: "<!-- raider-reporter:build-comment -->\n**Raider: failed** - build incomplete (1m 12s)\n")
    stub_comment
    status = stub_status.with(body: hash_including("description" => "Raider: tests failed"))
    run_cli
    expect(status).to have_been_requested
  end

  it "skips a pull_request event without a head sha, exits 0 and makes no HTTP calls" do
    event = JSON.parse(File.read(File.join(fixtures, "pull_request.json")))
    event["pull_request"]["head"].delete("sha")
    path = File.join(Dir.mktmpdir, "event.json")
    File.write(path, event.to_json)
    env["GITHUB_EVENT_PATH"] = path
    expect(run_cli).to eq(0)
    expect(err.string).to eq("[raider_reporter] skipped: not a pull request event\n")
    expect(a_request(:any, /.*/)).not_to have_been_made
  end

  it "keeps the description within 140 characters" do
    stub_summary(markdown: "**Raider: failed** - #{(['1 failed'] * 40).join(', ')}\n")
    stub_comment
    status = stub_status.with { |req| JSON.parse(req.body)["description"].length <= 140 }
    run_cli
    expect(status).to have_been_requested
  end

  it "skips quietly when GitHub answers 403 or 404" do
    stub_summary
    stub_request(:get, "#{gh}/issues/7/comments").with(query: hash_including({})).to_return(status: 403, body: "{}")
    expect(run_cli).to eq(0)
    expect(err.string).to eq("[raider_reporter] skipped: token cannot write to this PR\n")
  end

  it "reports other GitHub errors as one line without a backtrace" do
    stub_summary
    stub_request(:get, "#{gh}/issues/7/comments").with(query: hash_including({})).to_return(status: 500, body: "boom")
    expect(run_cli).to eq(0)
    expect(err.string).to match(/\A\[raider_reporter\] comment failed: RaiderReporter::Comment::GithubClient::Error: HTTP 500.*\n\z/)
  end

  it "reports unexpected exceptions and still returns 0" do
    allow(RaiderReporter::GithubEvent).to receive(:load).and_raise(RuntimeError, "kaboom")
    expect(run_cli).to eq(0)
    expect(err.string).to eq("[raider_reporter] comment failed: RuntimeError: kaboom\n")
  end

  describe "executable" do
    let(:exe) { File.expand_path("../../exe/raider-reporter", __dir__) }
    let(:empty_env) { { "PATH" => ENV.fetch("PATH"), "GEM_HOME" => ENV["GEM_HOME"], "GEM_PATH" => ENV["GEM_PATH"] }.compact }

    def run_exe(*args)
      Open3.capture3(empty_env, RbConfig.ruby, exe, *args, unsetenv_others: true)
    end

    it "prints usage on --help and exits 0" do
      stdout, stderr, status = run_exe("--help")
      expect([stdout, status.exitstatus]).to eq(["", 0])
      expect(stderr).to include("Usage: raider-reporter comment")
    end

    it "prints a missing-environment notice for `comment` and exits 0" do
      stdout, stderr, status = run_exe("comment")
      expect([stdout, status.exitstatus]).to eq(["", 0])
      expect(stderr).to include("[raider_reporter] skipped: missing GITHUB_TOKEN")
    end
  end
end
