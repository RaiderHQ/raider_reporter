# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "RaiderReporter::Cucumber::Formatter" do
  let(:lib_dir) { File.expand_path("../../../lib", __dir__) }
  let(:fixture_dir) { File.expand_path("../../fixtures/cucumber", __dir__) }

  # Runs cucumber from the fixture project; returns [stdout, stderr, status, results by full_name].
  def run_cucumber(*targets, extra_args: [], format_args: nil)
    Dir.mktmpdir do |out|
      env = { "RAIDER_TOKEN" => nil, "RAIDER_ENDPOINT" => nil, "GITHUB_ACTIONS" => nil,
              "GITHUB_JOB" => nil, "FIXTURE_OUT" => out }
      # Cucumber allows only one formatter per stream, so ours must be given --out.
      format_args ||= ["--format", "RaiderReporter::Cucumber::Formatter", "--out", File.join(out, "formatter.out"),
                       "--format", "progress"]
      stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, "-I", lib_dir, Gem.bin_path("cucumber", "cucumber"),
        "-r", "features", "--publish-quiet", *format_args, *extra_args, *targets, chdir: fixture_dir
      )
      run_json = File.join(out, "run.json")
      json = File.exist?(run_json) ? JSON.parse(File.read(run_json)) : nil
      @last = { stdout: stdout, stderr: stderr, status: status, json: json }
      by_name = json ? json["results"].to_h { |r| [r["full_name"], r] } : {}
      [stdout, stderr, status, by_name]
    end
  end

  def line_of(feature, text)
    File.readlines(File.join(fixture_dir, feature)).index { |l| l.include?(text) } + 1
  end

  describe "scenarios in login.feature" do
    let(:run) { run_cucumber("features/login.feature") }
    let(:stdout) { run[0] }
    let(:stderr) { run[1] }
    let(:status) { run[2] }
    let(:results) { run[3] }

    it "reports a passing scenario with its identity" do
      result = results.fetch("Login: A user can login")
      line = line_of("features/login.feature", "Scenario: A user can login")

      expect(result).to include("status" => "passed", "file_path" => "features/login.feature",
                                "line_number" => line, "identifier" => "features/login.feature:#{line}")
      expect(result["failure"]).to be_nil
      expect(result["duration_ms"]).to be_a(Integer)
      expect(result["attempts"]).to eq(1)
    end

    it "reports a raising step as failed, naming the step and keeping the exception" do
      result = results.fetch("Login: A user is rejected")
      step_line = line_of("features/login.feature", "When I fail on purpose")

      expect(result["status"]).to eq("failed")
      expect(result["failure"]["message"]).to start_with("When I fail on purpose (features/login.feature:#{step_line})\n\n")
      expect(result["failure"]["message"]).to end_with("bad credentials")
      expect(result["failure"]["exception_class"]).to eq("ArgumentError")
      expect(result["failure"]["backtrace"].size).to be_between(1, 50)
    end

    it "maps pending and undefined steps to pending without a failure" do
      %w[pending undefined].each do |kind|
        result = results.fetch("Login: A step is #{kind}")
        expect(result["status"]).to eq("pending")
        expect(result["failure"]).to be_nil
      end
    end

    it "maps ambiguous step definitions to failed" do
      result = results.fetch("Login: A step is ambiguous")
      expect(result["status"]).to eq("failed")
      expect(result["failure"]["message"]).to start_with("When I am ambiguous (features/login.feature:")
    end

    it "does not let steps after a failed step change the scenario status" do
      expect(results.fetch("Login: A user is rejected")["status"]).to eq("failed")
    end

    it "keeps cucumber's exit status and progress output" do
      expect(status.exitstatus).to eq(1), stderr
      expect(stdout).to include("scenarios (")
      expect(stdout).to match(/\d+ steps \(/)
    end
  end

  describe "Scenario Outline rows" do
    let(:results) { run_cucumber("features/outline.feature")[3] }
    let(:first_row_line) { line_of("features/outline.feature", "| alice |") }

    it "emits one result per Examples row, named by table and row number" do
      expect(results.keys).to contain_exactly(
        "Greetings: Greet users (Admins, row 1)", "Greetings: Greet users (Admins, row 2)",
        "Greetings: Greet users (Examples, row 1)", "Greetings: Greet users (Examples, row 2)"
      )
    end

    it "uses each row's own line as line_number and identifier" do
      alice = results.fetch("Greetings: Greet users (Admins, row 1)")
      bob = results.fetch("Greetings: Greet users (Admins, row 2)")
      carol = results.fetch("Greetings: Greet users (Examples, row 1)")

      expect(alice).to include("line_number" => line_of("features/outline.feature", "| alice |"),
                               "identifier" => "features/outline.feature:#{line_of('features/outline.feature', '| alice |')}")
      expect(bob["line_number"]).to eq(line_of("features/outline.feature", "| bob   |"))
      expect(carol["line_number"]).to eq(line_of("features/outline.feature", "| carol |"))
    end

    it "merges feature, scenario and Examples tags, sorted, unique and without @" do
      expect(results.fetch("Greetings: Greet users (Admins, row 1)")["tags"]).to eq(%w[admin login smoke])
      expect(results.fetch("Greetings: Greet users (Examples, row 2)")["tags"]).to eq(%w[login smoke])
    end
  end

  it "scrubs binary bytes from exception messages and still writes the run" do
    # Cucumber's own console formatters choke on invalid UTF-8, so ours runs alone here.
    results = run_cucumber("features/binary.feature", format_args: ["--format", "RaiderReporter::Cucumber::Formatter"])[3]
    result = results.fetch("Binary: A step raises binary text")

    expect(result["status"]).to eq("failed")
    expect(result["failure"]["message"]).to include("bad ").and include(" byte")
    expect(result["failure"]["message"]).to be_valid_encoding
  end

  it "names a failing Background step, not the first scenario step" do
    results = run_cucumber("features/background.feature")[3]
    result = results.fetch("Background: Never gets going")
    line = line_of("features/background.feature", "And I fail on purpose")

    expect(result["status"]).to eq("failed")
    expect(result["failure"]["message"]).to start_with("And I fail on purpose (features/background.feature:#{line})\n\n")
  end

  it "reports a raising After hook as failed even though every step passed" do
    results = run_cucumber("features/after_hook.feature")[3]
    result = results.fetch("Teardown: Steps pass, teardown fails")

    expect(result["status"]).to eq("failed")
    expect(result["failure"]["message"]).to start_with("After hook")
    expect(result["failure"]["message"]).to end_with("teardown exploded")
  end

  describe "file_path stability" do
    it "is project-relative when cucumber is given a ./ path" do
      results = run_cucumber("./features/login.feature")[3]
      expect(results.fetch("Login: A user can login")).to include("file_path" => "features/login.feature")
      expect(results.fetch("Login: A user can login")["identifier"]).to start_with("features/login.feature:")
    end

    it "is project-relative when cucumber is given an absolute path" do
      results = run_cucumber(File.join(fixture_dir, "features/login.feature"))[3]
      expect(results.fetch("Login: A user can login")).to include("file_path" => "features/login.feature")
    end
  end

  it "writes nothing to its own IO, even with --out" do
    Dir.mktmpdir do |dir|
      out_file = File.join(dir, "formatter.out")
      stdout, _stderr, _status, = run_cucumber(
        "features/login.feature",
        format_args: ["--format", "RaiderReporter::Cucumber::Formatter", "--out", out_file, "--format", "progress"]
      )

      expect(!File.exist?(out_file) || File.zero?(out_file)).to be(true)
      expect(stdout).to include("scenarios (")
      expect(stdout).not_to include("raider")
      expect(stdout).not_to include("{")
    end
  end
end
