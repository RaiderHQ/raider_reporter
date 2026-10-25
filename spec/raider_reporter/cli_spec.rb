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

  after { expect(out.string).to eq("") unless RSpec.current_example.metadata[:prints] }

  it "prints usage for an unknown subcommand and exits 0" do
    expect(described_class.new(["bogus"], env: env, out: out, err: err).run).to eq(0)
    expect(err.string).to include("Usage: raider-reporter comment")
  end

  it "prints usage for --help and for no arguments" do
    expect(described_class.new(["--help"], env: env, out: out, err: err).run).to eq(0)
    expect(described_class.new([], env: env, out: out, err: err).run).to eq(0)
    expect(err.string.scan("Usage: raider-reporter comment").size).to eq(2)
    expect(err.string).to include("Usage: raider-reporter report [dir]")
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

  describe "Azure Pipelines" do
    let(:env) do
      { "TF_BUILD" => "True", "SYSTEM_COLLECTIONURI" => "https://dev.azure.com/raider-test/",
        "SYSTEM_TEAMPROJECT" => "My Project", "SYSTEM_TEAMPROJECTID" => "6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c",
        "BUILD_REPOSITORY_NAME" => "web tests", "BUILD_REPOSITORY_ID" => "1c2bd1a0-3f63-4d93-9c3c-2b4f2b1d8f11",
        "BUILD_REPOSITORY_PROVIDER" => "TfsGit", "BUILD_BUILDID" => "42", "SYSTEM_STAGEATTEMPT" => "2",
        "SYSTEM_JOBDISPLAYNAME" => "tests", "BUILD_REASON" => "PullRequest",
        "BUILD_SOURCEBRANCH" => "refs/pull/7/merge", "BUILD_SOURCEVERSION" => "mergesha",
        "SYSTEM_PULLREQUEST_PULLREQUESTID" => "7", "SYSTEM_PULLREQUEST_SOURCEBRANCH" => "refs/heads/feature/login",
        "SYSTEM_PULLREQUEST_TARGETBRANCH" => "refs/heads/main", "SYSTEM_PULLREQUEST_SOURCECOMMITID" => "headsha",
        "SYSTEM_ACCESSTOKEN" => "tok", "RAIDER_TOKEN" => "rt", "RAIDER_ENDPOINT" => "https://raider.test" }
    end
    let(:pr_base) do
      "https://dev.azure.com/raider-test/6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c/_apis/git/repositories/" \
        "1c2bd1a0-3f63-4d93-9c3c-2b4f2b1d8f11/pullRequests/7"
    end
    let(:pr_url) { "https://dev.azure.com/raider-test/My%20Project/_git/web%20tests/pullrequest/7" }
    let(:build_key) do
      "azure_pipelines:dev.azure.com/raider-test/6ce954b1-ce1f-45d1-b94d-e6bf2464ba2c/1c2bd1a0-3f63-4d93-9c3c-2b4f2b1d8f11:42:2"
    end

    def stub_azure_summary(state: self.state)
      stub_request(:get, "https://raider.test/api/v1/builds/summary")
        .with(query: { build_key: build_key }, headers: { "Authorization" => "Bearer rt" })
        .to_return(status: 200, body: { state: state, markdown: markdown, url: "https://raider.test/b/1" }.to_json)
    end

    def stub_threads(threads = [])
      stub_request(:get, "#{pr_base}/threads").with(query: { "api-version" => "7.1" }, headers: { "Authorization" => "Bearer tok" })
                                              .to_return(status: 200, body: { value: threads }.to_json)
    end

    def stub_thread_post
      stub_request(:post, "#{pr_base}/threads").with(query: { "api-version" => "7.1" }).to_return(status: 200, body: "{}")
    end

    def stub_pr_status
      stub_request(:post, "#{pr_base}/statuses").with(query: { "api-version" => "7.1" }).to_return(status: 200, body: "{}")
    end

    {
      "failed" => %w[active failed],
      "passed" => %w[closed succeeded],
      "incomplete" => %w[active pending]
    }.each do |summary_state, (thread_status, pr_state)|
      it "maps a #{summary_state} summary to thread #{thread_status} and PR status #{pr_state}" do
        stub_azure_summary(state: summary_state)
        stub_threads
        thread = stub_request(:post, "#{pr_base}/threads").with(query: { "api-version" => "7.1" }) { |r|
          JSON.parse(r.body)["status"] == thread_status
        }.to_return(status: 200, body: "{}")
        status = stub_request(:post, "#{pr_base}/statuses").with(query: { "api-version" => "7.1" }) { |r|
          body = JSON.parse(r.body)
          body["state"] == pr_state && body["description"] == "2 failed, 148 passed, 3 skipped" &&
            body["targetUrl"] == "https://raider.test/b/1"
        }.to_return(status: 200, body: "{}")
        expect(run_cli).to eq(0)
        expect(thread).to have_been_requested
        expect(status).to have_been_requested
        expect(err.string).to eq("[raider_reporter] PR thread created: #{pr_url}\n")
      end
    end

    it "updates the existing thread in place" do
      stub_azure_summary
      marker = RaiderReporter::CLI::MARKER
      stub_threads([{ id: 11, properties: { "Raider.BuildComment" => {} }, comments: [{ id: 1, content: "#{marker}\nold" }] }])
      c = stub_request(:patch, "#{pr_base}/threads/11/comments/1").with(query: { "api-version" => "7.1" }).to_return(status: 200, body: "{}")
      t = stub_request(:patch, "#{pr_base}/threads/11").with(query: { "api-version" => "7.1" }).to_return(status: 200, body: "{}")
      stub_pr_status
      expect(run_cli).to eq(0)
      expect([c, t]).to all(have_been_requested)
      expect(err.string).to eq("[raider_reporter] PR thread updated: #{pr_url}\n")
    end

    it "does not use the Azure path for GitHub Actions" do
      env["GITHUB_ACTIONS"] = "true"
      env.merge!("GITHUB_TOKEN" => "gh", "GITHUB_REPOSITORY" => "RaiderHQ/demo")
      expect(run_cli).to eq(0)
      expect(err.string).to include("skipped: missing GITHUB_EVENT_PATH")
    end

    it "skips with unsupported CI when neither provider is detected" do
      expect(described_class.new(["comment"], env: {}, out: out, err: err).run).to eq(0)
      expect(err.string).to eq("[raider_reporter] skipped: unsupported CI\n")
    end

    it "names every missing Azure variable" do
      env.delete("BUILD_REPOSITORY_ID")
      env["RAIDER_TOKEN"] = "$(RAIDER_TOKEN)"
      expect(run_cli).to eq(0)
      expect(err.string).to eq("[raider_reporter] skipped: missing BUILD_REPOSITORY_ID, RAIDER_TOKEN\n")
    end

    ["$(System.AccessToken)", nil, ""].each do |value|
      it "explains how to map SYSTEM_ACCESSTOKEN when it is #{value.inspect}" do
        value.nil? ? env.delete("SYSTEM_ACCESSTOKEN") : env["SYSTEM_ACCESSTOKEN"] = value
        expect(run_cli).to eq(0)
        expect(err.string).to include("skipped: missing SYSTEM_ACCESSTOKEN",
                                      "map it with env: SYSTEM_ACCESSTOKEN: $(System.AccessToken)")
        expect(a_request(:any, /.*/)).not_to have_been_made
      end
    end

    it "skips a push build" do
      env["BUILD_REASON"] = "IndividualCI"
      expect(run_cli).to eq(0)
      expect(err.string).to eq("[raider_reporter] skipped: not an Azure Repos pull request\n")
    end

    it "skips a GitHub-hosted repo built by Azure without crashing" do
      env["BUILD_REPOSITORY_PROVIDER"] = "GitHub"
      expect(run_cli).to eq(0)
      expect(err.string).to eq("[raider_reporter] skipped: not an Azure Repos pull request\n")
    end

    it "explains the missing permission on a Forbidden response (dev.azure.com)" do
      stub_azure_summary
      stub_request(:get, "#{pr_base}/threads").with(query: hash_including({})).to_return(status: 403, body: "{}")
      expect(run_cli).to eq(0)
      expect(err.string).to eq("[raider_reporter] skipped: the build service cannot write to this PR \u2014 grant " \
                               "\"Contribute to pull requests\" to \"My Project Build Service (raider-test)\"\n")
    end

    it "uses <project> in the Forbidden notice when SYSTEM_TEAMPROJECT is blank" do
      env.delete("SYSTEM_TEAMPROJECT")
      stub_azure_summary
      stub_request(:get, "#{pr_base}/threads").with(query: hash_including({})).to_return(status: 403, body: "{}")
      expect(run_cli).to eq(0)
      expect(err.string).to include("\"<project> Build Service (raider-test)\"")
    end

    it "prints the PR number when the PR url is unknown" do
      env.delete("SYSTEM_TEAMPROJECT")
      stub_azure_summary
      stub_threads
      stub_thread_post
      stub_pr_status
      expect(run_cli).to eq(0)
      expect(err.string).to eq("[raider_reporter] PR thread created: PR #7\n")
    end

    it "derives the org from a visualstudio.com collection" do
      env["SYSTEM_COLLECTIONURI"] = "https://raider-test.visualstudio.com"
      stub_request(:get, "https://raider.test/api/v1/builds/summary").with(query: hash_including({}))
                                                                      .to_return(status: 200, body: { state: "failed", markdown: markdown, url: "u" }.to_json)
      stub_request(:get, %r{raider-test\.visualstudio\.com/.*/threads}).to_return(status: 403, body: "{}")
      expect(run_cli).to eq(0)
      expect(err.string).to include("Build Service (raider-test)")
    end

    it "reports other client errors as comment failed" do
      stub_azure_summary
      stub_request(:get, "#{pr_base}/threads").with(query: hash_including({})).to_return(status: 500, body: "tok oops")
      expect(run_cli).to eq(0)
      expect(err.string).to start_with("[raider_reporter] comment failed: RaiderReporter::Comment::AzureClient::Error: HTTP 500")
      expect(err.string).not_to match(/\btok\b/)
    end

    it "mentions Azure Pipelines and its variables in --help" do
      described_class.new(["--help"], env: env, out: out, err: err).run
      expect(err.string).to include("Azure Pipelines", *RaiderReporter::CLI::AZURE_REQUIRED_ENV)
    end
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
      stdout, stderr, status = Open3.capture3(empty_env.merge("GITHUB_ACTIONS" => "true"), RbConfig.ruby, exe, "comment",
                                              unsetenv_others: true)
      expect([stdout, status.exitstatus]).to eq(["", 0])
      expect(stderr).to include("[raider_reporter] skipped: missing GITHUB_TOKEN")
    end

    it "reports unsupported CI for `comment` outside GitHub Actions and Azure Pipelines" do
      stdout, stderr, status = run_exe("comment")
      expect([stdout, status.exitstatus]).to eq(["", 0])
      expect(stderr).to include("[raider_reporter] skipped: unsupported CI")
    end
  end

  describe "report", :prints do
    it "rebuilds index.html and prints its path" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "run.json"), JSON.generate("schema_version" => 1, "run" => {}, "results" => []))

        code = described_class.new(["report", dir], env: {}, out: out, err: err).run

        expect(code).to eq(0)
        expect(out.string.strip).to eq(File.join(File.realpath(dir), "index.html")).or eq(File.join(dir, "index.html"))
        expect(File).to exist(File.join(dir, "index.html"))
      end
    end

    it "exits 1 when the folder has no run files" do
      Dir.mktmpdir do |dir|
        code = described_class.new(["report", dir], env: {}, out: out, err: err).run

        expect(code).to eq(1)
        expect(err.string).to include("no run*.json in")
        expect(out.string).to eq("")
      end
    end

    it "exits 1 with a message when an index.html it did not write is in the way" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "run.json"), JSON.generate("schema_version" => 1, "run" => {}, "results" => []))
        File.write(File.join(dir, "index.html"), "mine")

        code = described_class.new(["report", dir], env: {}, out: out, err: err).run

        expect(code).to eq(1)
        expect(err.string).to include("report failed", "not written by raider_reporter")
        expect(out.string).to eq("")
      end
    end

    it "defaults to raider-results" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          FileUtils.mkdir_p("raider-results")
          File.write("raider-results/run.json", JSON.generate("schema_version" => 1, "run" => {}, "results" => []))

          expect(described_class.new(["report"], env: {}, out: out, err: err).run).to eq(0)
          expect(File).to exist("raider-results/index.html")
        end
      end
    end
  end

  it "documents exec in the usage" do
    described_class.new(["--help"], env: env, out: out, err: err).run
    expect(err.string).to include("Usage: raider-reporter exec -- <command> [args...]")
  end

  it "documents gate in the usage" do
    described_class.new(["--help"], env: env, out: out, err: err).run
    expect(err.string).to include("Usage: raider-reporter gate", "RAIDER_GATE_TIMEOUT")
  end

  it "runs gate and returns its exit code" do
    expect(described_class.new(["gate"], env: {}, out: out, err: err).run).to eq(2)
    expect(err.string).to eq("raider-reporter gate: no CI build key (run this in GitHub Actions or Azure Pipelines)\n")
  end

  it "prints the gate usage for gate --help and exits 0" do
    expect(described_class.new(["gate", "--help"], env: env, out: out, err: err).run).to eq(0)
    expect(err.string).to start_with("Usage: raider-reporter gate")
  end

  it "reads quarantined counts from the headline into the commit status" do
    stub_summary(state: "passed",
                 markdown: "<!-- raider-reporter:build-comment -->\n**Raider: passed** - 1 quarantined, 148 passed (1m 12s)\n")
    stub_comment
    status = stub_status.with(body: hash_including("state" => "success", "description" => "1 quarantined, 148 passed"))
    expect(run_cli).to eq(0)
    expect(status).to have_been_requested
  end
end
