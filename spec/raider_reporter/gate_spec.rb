# frozen_string_literal: true

require "webmock/rspec"
require "stringio"
require "raider_reporter"
require "raider_reporter/gate"

RSpec.describe RaiderReporter::Gate do
  let(:fixtures) { File.expand_path("../fixtures/github_events", __dir__) }
  let(:env) do
    { "GITHUB_ACTIONS" => "true", "GITHUB_REPOSITORY" => "RaiderHQ/demo", "GITHUB_RUN_ID" => "99",
      "GITHUB_RUN_ATTEMPT" => "1", "RAIDER_TOKEN" => "rt-secret", "RAIDER_ENDPOINT" => "https://raider.test" }
  end
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:clock) { [0.0] }
  let(:sleeps) { [] }
  let(:build_url) { "https://raider.test/projects/demo/builds/7" }
  let(:failed_rules) do
    [{ "rule" => "pass_rate", "outcome" => "failed", "detail" => "96% < 98%" },
     { "rule" => "new_failures", "outcome" => "failed", "detail" => "2 new failures vs main" },
     { "rule" => "new_flaky", "outcome" => "passed", "detail" => "0 new flaky tests" }]
  end

  def run_gate
    sleeper = lambda do |seconds|
      sleeps << seconds
      clock[0] += seconds
    end
    described_class.new(env: env, out: out, err: err, clock: -> { clock[0] }, sleeper: sleeper).run
  end

  def gate_stub(build_key = "github_actions:RaiderHQ/demo:99:1")
    stub_request(:get, "https://raider.test/api/v1/builds/gate")
      .with(query: { "build_key" => build_key }, headers: { "Authorization" => "Bearer rt-secret" })
  end

  def reply(state, rules: [], received: 2, expected: 2, build_state: "passed")
    { status: 200, body: JSON.generate("state" => state, "build_state" => build_state,
                                       "shards" => { "received" => received, "expected" => expected },
                                       "rules" => rules, "url" => build_url) }
  end

  describe "verdicts" do
    it "waits through pending, then exits 0 on passed and lists every rule" do
      rules = [{ "rule" => "pass_rate", "outcome" => "passed", "detail" => "99% ≥ 98%" },
               { "rule" => "new_failures", "outcome" => "skipped", "detail" => "no baseline build on main" }]
      stub = gate_stub.to_return(reply("pending", received: 1, build_state: "incomplete"), reply("passed", rules: rules))

      expect(run_gate).to eq(0)
      expect(stub).to have_been_requested.twice
      expect(sleeps).to eq([10])
      expect(out.string).to eq("raider-reporter gate: waiting for the verdict (build incomplete: 1 of 2 shards)\n" \
                               "raider-reporter gate: passed\n" \
                               "  ✓ pass rate: 99% ≥ 98%\n" \
                               "  – new failures: no baseline build on main\n")
      expect(err.string).to eq("")
    end

    it "exits 1 on failed, naming each failed rule and the build URL on stderr" do
      gate_stub.to_return(reply("failed", rules: failed_rules))

      expect(run_gate).to eq(1)
      expect(out.string).to eq("")
      expect(err.string).to eq("raider-reporter gate: failed\n" \
                               "  ✗ pass rate: 96% < 98%\n" \
                               "  ✗ new failures: 2 new failures vs main\n" \
                               "  #{build_url}\n")
    end

    it "exits 0 when the project has no gate rules" do
      gate_stub.to_return(reply("none"))
      expect(run_gate).to eq(0)
      expect(out.string).to eq("raider-reporter gate: no gate rules for this project\n")
      expect(err.string).to eq("")
    end
  end

  describe "waiting" do
    it "says it is analysing results when every shard is in but the verdict is pending (Review Focus 3)" do
      gate_stub.to_return(reply("pending", build_state: "passed"), reply("passed"))
      expect(run_gate).to eq(0)
      expect(out.string).to start_with("raider-reporter gate: waiting for the verdict (analysing results)\n")
    end

    it "says analysing results when the shard total is unknown (Review Focus 2)" do
      gate_stub.to_return(reply("pending", received: 1, expected: nil), reply("none"))
      run_gate
      expect(out.string).to start_with("raider-reporter gate: waiting for the verdict (analysing results)\n")
      expect(out.string).not_to include("shards")
    end

    it "prints the waiting line at most once a minute" do
      gate_stub.to_return(*Array.new(8) { reply("pending") }, reply("none"))
      expect(run_gate).to eq(0)
      expect(out.string.scan("waiting for the verdict").size).to eq(2)
      expect(sleeps).to eq([10] * 8)
    end

    it "times out with exit 2 after RAIDER_GATE_TIMEOUT seconds, naming the last pending detail" do
      env["RAIDER_GATE_TIMEOUT"] = "25"
      stub = gate_stub.to_return(reply("pending", received: 3, expected: 4, build_state: "incomplete"))

      expect(run_gate).to eq(2)
      expect(sleeps).to eq([10, 10, 5])
      expect(stub).to have_been_requested.times(4)
      expect(err.string).to eq("raider-reporter gate: no verdict after 25s (build incomplete: 3 of 4 shards)\n")
    end

    it "waits 600 seconds by default, polling every 10" do
      gate_stub.to_return(reply("pending"))
      expect(run_gate).to eq(2)
      expect(sleeps.sum).to eq(600)
      expect(sleeps.uniq).to eq([10])
      expect(err.string).to eq("raider-reporter gate: no verdict after 600s (analysing results)\n")
    end
  end

  describe "retries and stops" do
    it "retries 429, 5xx and network errors within the time limit" do
      stub = gate_stub.to_return({ status: 429, body: "" }, { status: 503, body: "" })
                      .then.to_timeout.then.to_raise(Errno::ECONNREFUSED).then.to_return(reply("none"))
      expect(run_gate).to eq(0)
      expect(stub).to have_been_requested.times(5)
      expect(sleeps).to eq([10, 10, 10, 10])
    end

    it "names the last error when no pending answer ever came" do
      env["RAIDER_GATE_TIMEOUT"] = "15"
      gate_stub.to_return(status: 502, body: "")
      expect(run_gate).to eq(2)
      expect(err.string).to eq("raider-reporter gate: no verdict after 15s (HTTP 502)\n")
    end

    {
      401 => "token rejected (HTTP 401)",
      403 => "token rejected (HTTP 403)",
      404 => "build not found (did the tests upload?)"
    }.each do |code, message|
      it "exits 2 at once on HTTP #{code}" do
        stub = gate_stub.to_return(status: code, body: "{}")
        expect(run_gate).to eq(2)
        expect(stub).to have_been_requested.once
        expect(sleeps).to eq([])
        expect(err.string).to eq("raider-reporter gate: #{message}\n")
      end
    end

    it "exits 2 at once on unparseable JSON without printing the token" do
      stub = gate_stub.to_return(status: 200, body: "rt-secret oops")
      expect(run_gate).to eq(2)
      expect(stub).to have_been_requested.once
      expect(err.string).to start_with("raider-reporter gate: JSON::ParserError: ")
      expect(err.string).to include("[REDACTED]")
      expect(err.string).not_to include("rt-secret")
    end

    it "redacts the token from a network error in the timeout message (Review Focus 4)" do
      env["RAIDER_GATE_TIMEOUT"] = "1"
      gate_stub.to_raise(SocketError.new("getaddrinfo failed for rt-secret"))
      expect(run_gate).to eq(2)
      expect(err.string).to eq("raider-reporter gate: no verdict after 1s (SocketError: getaddrinfo failed for [REDACTED])\n")
    end

    it "reports any other error as class and message, token redacted (Review Focus 4)" do
      gate_stub.to_raise(RuntimeError.new("boom rt-secret"))
      expect(run_gate).to eq(2)
      expect(err.string).to eq("raider-reporter gate: RuntimeError: boom [REDACTED]\n")
    end
  end

  describe "configuration" do
    it "exits 2 without a CI build key" do
      env.replace("RAIDER_TOKEN" => "rt-secret", "RAIDER_ENDPOINT" => "https://raider.test")
      expect(run_gate).to eq(2)
      expect(err.string).to eq("raider-reporter gate: no CI build key (run this in GitHub Actions or Azure Pipelines)\n")
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    [%w[RAIDER_TOKEN], %w[RAIDER_ENDPOINT], %w[RAIDER_TOKEN RAIDER_ENDPOINT]].each do |names|
      it "exits 2 when #{names.join(' and ')} is missing" do
        names.each { |name| env.delete(name) }
        expect(run_gate).to eq(2)
        expect(err.string).to eq("raider-reporter gate: RAIDER_TOKEN and RAIDER_ENDPOINT are required\n")
      end
    end

    it "counts an undefined Azure macro as a missing token" do
      env["RAIDER_TOKEN"] = "$(RAIDER_TOKEN)"
      expect(run_gate).to eq(2)
      expect(err.string).to eq("raider-reporter gate: RAIDER_TOKEN and RAIDER_ENDPOINT are required\n")
    end

    %w[0 3601 -5 abc 1.5 60s 10m].each do |value|
      it "rejects RAIDER_GATE_TIMEOUT=#{value} with exit 2 and makes no request" do
        env["RAIDER_GATE_TIMEOUT"] = value
        expect(run_gate).to eq(2)
        expect(err.string).to eq("raider-reporter gate: RAIDER_GATE_TIMEOUT must be a whole number of seconds from 1 to 3600\n")
        expect(a_request(:any, /.*/)).not_to have_been_made
      end
    end

    { "1" => 1, "3600" => 3600, " 30 " => 30, "" => 600, "$(RAIDER_GATE_TIMEOUT)" => 600 }.each do |value, seconds|
      it "accepts RAIDER_GATE_TIMEOUT=#{value.inspect} as #{seconds}s" do
        env["RAIDER_GATE_TIMEOUT"] = value
        gate_stub.to_return(reply("pending"))
        expect(run_gate).to eq(2)
        expect(sleeps.sum).to eq(seconds)
      end
    end

    it "rejects an endpoint that is not http(s)" do
      env["RAIDER_ENDPOINT"] = "raider.test"
      expect(run_gate).to eq(2)
      expect(err.string).to eq("raider-reporter gate: ArgumentError: RAIDER_ENDPOINT must start with http:// or https://\n")
    end
  end

  describe "raider/gate status on GitHub" do
    let(:gh) { "https://api.github.test/repos/RaiderHQ/demo" }
    let(:posts) { [] }

    before do
      env.merge!("GITHUB_TOKEN" => "gh-secret", "GITHUB_API_URL" => "https://api.github.test", "GITHUB_EVENT_NAME" => "push",
                 "GITHUB_EVENT_PATH" => File.join(fixtures, "push.json"), "GITHUB_SHA" => "pushsha333")
      stub_request(:post, "#{gh}/statuses/pushsha333").to_return do |request|
        posts << JSON.parse(request.body).values_at("state", "description", "target_url")
        { status: 201, body: "{}" }
      end
    end

    it "posts pending before polling, then failure with the failed rule text" do
      gate_stub.to_return(reply("failed", rules: failed_rules))
      expect(run_gate).to eq(1)
      expect(posts).to eq([["pending", "Waiting for the Raider verdict", nil],
                           ["failure", "pass rate: 96% < 98%; new failures: 2 new failures vs main", build_url]])
    end

    it "posts success on passed" do
      gate_stub.to_return(reply("passed"))
      run_gate
      expect(posts.last).to eq(["success", "Gate passed", build_url])
    end

    it "turns pending into success with No gate rules" do
      gate_stub.to_return(reply("none"))
      run_gate
      expect(posts.last).to eq(["success", "No gate rules", build_url])
    end

    it "posts error on timeout, linking the build page it saw" do
      env["RAIDER_GATE_TIMEOUT"] = "5"
      gate_stub.to_return(reply("pending"))
      expect(run_gate).to eq(2)
      expect(posts.last).to eq(["error", "No verdict", build_url])
    end

    it "posts error when the token is rejected, so no pending status is left behind" do
      gate_stub.to_return(status: 401, body: "{}")
      expect(run_gate).to eq(2)
      expect(posts).to eq([["pending", "Waiting for the Raider verdict", nil], ["error", "No verdict", nil]])
    end

    it "posts nothing when it exits before polling" do
      env["RAIDER_GATE_TIMEOUT"] = "0"
      run_gate
      expect(posts).to eq([])
    end

    it "truncates the failure description to 140 characters" do
      rules = Array.new(20) { |i| { "rule" => "pass_rate", "outcome" => "failed", "detail" => "#{i}% < 98%" } }
      gate_stub.to_return(reply("failed", rules: rules))
      run_gate
      expect(posts.last[1].length).to eq(140)
    end

    it "warns without the token and keeps the exit code when a status cannot be posted (Review Focus 4)" do
      stub_request(:post, "#{gh}/statuses/pushsha333").to_return(status: 500, body: "nope gh-secret")
      gate_stub.to_return(reply("failed", rules: failed_rules))

      expect(run_gate).to eq(1)
      warnings = err.string.lines.grep(/could not post/)
      expect(warnings).to eq(["raider-reporter gate: could not post the raider/gate status " \
                              "(RaiderReporter::Comment::GithubClient::Error: HTTP 500: nope [REDACTED])\n"] * 2)
      expect(err.string).not_to include("gh-secret")
    end

    it "posts to the PR head commit on pull_request events (Review Focus 5)" do
      env.merge!("GITHUB_EVENT_NAME" => "pull_request", "GITHUB_EVENT_PATH" => File.join(fixtures, "pull_request.json"))
      head = stub_request(:post, "#{gh}/statuses/headsha222").to_return(status: 201, body: "{}")
      gate_stub.to_return(reply("none"))

      expect(run_gate).to eq(0)
      expect(head).to have_been_requested.twice
      expect(posts).to eq([])
    end
  end

  describe "raider/gate status on Azure Pipelines" do
    let(:env) do
      { "TF_BUILD" => "True", "SYSTEM_COLLECTIONURI" => "https://dev.azure.com/raider-test/",
        "SYSTEM_TEAMPROJECT" => "My Project", "SYSTEM_TEAMPROJECTID" => "6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c",
        "BUILD_REPOSITORY_NAME" => "web tests", "BUILD_REPOSITORY_ID" => "1c2bd1a0-3f63-4d93-9c3c-2b4f2b1d8f11",
        "BUILD_REPOSITORY_PROVIDER" => "TfsGit", "BUILD_BUILDID" => "42", "SYSTEM_STAGEATTEMPT" => "2",
        "BUILD_REASON" => "PullRequest", "SYSTEM_PULLREQUEST_PULLREQUESTID" => "7",
        "SYSTEM_PULLREQUEST_SOURCEBRANCH" => "refs/heads/feature/login",
        "SYSTEM_PULLREQUEST_TARGETBRANCH" => "refs/heads/main", "SYSTEM_PULLREQUEST_SOURCECOMMITID" => "headsha",
        "SYSTEM_ACCESSTOKEN" => "az-secret", "RAIDER_TOKEN" => "rt-secret", "RAIDER_ENDPOINT" => "https://raider.test" }
    end
    let(:build_key) do
      "azure_pipelines:dev.azure.com/raider-test/6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c/1c2bd1a0-3f63-4d93-9c3c-2b4f2b1d8f11:42:2"
    end
    let(:pr_base) do
      "https://dev.azure.com/raider-test/6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c/_apis/git/repositories/" \
        "1c2bd1a0-3f63-4d93-9c3c-2b4f2b1d8f11/pullRequests/7"
    end

    it "posts a pending then failed PR status named gate" do
      states = []
      stub_request(:post, "#{pr_base}/statuses").with(query: { "api-version" => "7.1" }).to_return do |request|
        body = JSON.parse(request.body)
        states << [body["state"], body.dig("context", "name")]
        { status: 200, body: "{}" }
      end
      gate_stub(build_key).to_return(reply("failed", rules: failed_rules))

      expect(run_gate).to eq(1)
      expect(states).to eq([%w[pending gate], %w[failed gate]])
    end
  end
end
