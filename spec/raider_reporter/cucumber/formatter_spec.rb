# frozen_string_literal: true

require "open3"
require "tmpdir"
require "rbconfig"
require "raider_reporter/cucumber/formatter"
require_relative "../../support/fake_raider"

RSpec.describe "RaiderReporter::Cucumber::Formatter" do
  let(:lib_dir) { File.expand_path("../../../lib", __dir__) }
  let(:fixture_dir) { File.expand_path("../../fixtures/cucumber", __dir__) }

  # Runs cucumber from the fixture project; returns [stdout, stderr, status, results by full_name].
  def run_cucumber(*targets, extra_args: [], format_args: nil, mode: "formatter", extra_env: {}, out_dir: nil)
    with_out_dir(out_dir) do |out|
      env = { "RAIDER_TOKEN" => nil, "RAIDER_ENDPOINT" => nil, "RAIDER_QUARANTINE" => nil, "RAIDER_EXEC_SUMMARY" => nil,
              "GITHUB_ACTIONS" => nil, "GITHUB_JOB" => nil, "FIXTURE_OUT" => out, "FIXTURE_MODE" => mode }.merge(extra_env)
      # Cucumber allows only one formatter per stream, so ours must be given --out.
      format_args ||= if mode == "plugin"
                        ["--format", "progress"]
                      else
                        ["--format", "RaiderReporter::Cucumber::Formatter", "--out", File.join(out, "formatter.out"),
                         "--format", "progress"]
                      end
      stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, "-I", lib_dir, Gem.bin_path("cucumber", "cucumber"),
        "-r", "features", "--publish-quiet", *format_args, *extra_args, *targets, chdir: fixture_dir
      )
      run_json = File.join(out, "run.json")
      json = File.exist?(run_json) ? JSON.parse(File.read(run_json)) : nil
      runs = Dir.glob(File.join(out, "run*.json")).to_h { |f| [File.basename(f), JSON.parse(File.read(f))] }
      files = Dir.glob(File.join(out, "**", "*")).select { |f| File.file?(f) }.map { |f| f.delete_prefix("#{out}/") }
      @last = { stdout: stdout, stderr: stderr, status: status, json: json, runs: runs, files: files }
      by_name = json ? json["results"].to_h { |r| [r["full_name"], r] } : {}
      [stdout, stderr, status, by_name]
    end
  end

  def with_out_dir(out_dir, &block)
    return yield(out_dir) if out_dir

    Dir.mktmpdir(&block)
  end

  # Fixture env for scenarios that count attempts or attach a screenshot.
  def attempt_env(dir)
    png = File.join(dir, "shot.png")
    File.binwrite(png, "\x89PNG fake")
    { "FIXTURE_COUNTER" => File.join(dir, "counter"), "FIXTURE_PNG" => png }
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

    it "reports the step definition frame as app_frame" do
      failure = results.fetch("Login: A user is rejected")["failure"]
      expect(failure["app_frame"]).to match(%r{\Afeatures/step_definitions/steps\.rb:\d+:in })
    end

    it "still reports the failure when AppFrame.from raises" do
      boom = File.join(fixture_dir, "features/support/zz_boom.rb")
      File.write(boom, "RaiderReporter::AppFrame.define_singleton_method(:from) { |*, **| raise 'nope' }\n")
      begin
        failure = run_cucumber("features/login.feature")[3].fetch("Login: A user is rejected")["failure"]
        expect(failure["message"]).to end_with("bad credentials")
        expect(failure).not_to have_key("app_frame")
      ensure
        FileUtils.rm_f(boom)
      end
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

    it "does not let steps after a failed step change the scenario status or message" do
      result = results.fetch("Login: A user is rejected")
      expect(result["status"]).to eq("failed")
      expect(result["failure"]["message"]).to start_with("When I fail on purpose")
      expect(result["failure"]["message"]).not_to include("I see the dashboard")
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

  describe "Examples tables sharing a label" do
    let(:results) { run_cucumber("features/examples_tables.feature")[3] }

    it "numbers every same-label table by position and keeps unique labels unchanged" do
      expect(results.keys).to contain_exactly(
        "Tables: Same labels (Examples 1, row 1)", "Tables: Same labels (Examples 2, row 1)",
        "Tables: Same labels (Named, row 1)"
      )
    end

    it "gives each table its own tags" do
      expect(results.fetch("Tables: Same labels (Examples 1, row 1)")["tags"]).to eq(%w[smoke])
      expect(results.fetch("Tables: Same labels (Examples 2, row 1)")["tags"]).to eq(%w[regression])
      expect(results.fetch("Tables: Same labels (Named, row 1)")["tags"]).to eq([])
    end
  end

  it "reports a scenario skipped by skip_this_scenario as skipped" do
    result = run_cucumber("features/skipped.feature")[3].fetch("Skipping: Skipped on purpose")
    expect(result).to include("status" => "skipped")
    expect(result["failure"]).to be_nil
  end

  describe "relative_path" do
    it "falls back to the given path when relative_path_from raises ArgumentError" do
      formatter = RaiderReporter::Cucumber::Formatter.allocate
      allow_any_instance_of(Pathname).to receive(:relative_path_from).and_raise(ArgumentError, "different prefix")

      expect(formatter.send(:relative_path, "./features/a.feature")).to eq("features/a.feature")
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

  it "names a failing Before hook" do
    result = run_cucumber("features/before_hook.feature")[3].fetch("Setup: Setup fails")
    expect(result["status"]).to eq("failed")
    expect(result["failure"]["message"]).to start_with("Before hook (features/support/env.rb:").and end_with("setup exploded")
  end

  it "names a failing AfterStep hook as an After hook" do
    result = run_cucumber("features/after_step.feature")[3].fetch("Step teardown: Step teardown fails")
    expect(result["status"]).to eq("failed")
    expect(result["failure"]["message"]).to start_with("After hook (features/support/env.rb:").and end_with("after step exploded")
  end

  it "still reports scenarios, with fallback names, when the AST lookup fails" do
    # The stub also breaks cucumber's own console formatters, so ours runs alone.
    _stdout, stderr, status, results = run_cucumber(
      "features/login.feature", extra_env: { "FIXTURE_BREAK_AST" => "1" },
                                format_args: ["--format", "RaiderReporter::Cucumber::Formatter"]
    )

    expect(status.exitstatus).to eq(1), stderr
    expect(stderr).to include("[raider_reporter]")
    expect(results.keys).to include("A user can login", "A user is rejected")
    expect(results.fetch("A user can login")["status"]).to eq("passed")
    failed = results.fetch("A user is rejected")
    expect(failed["status"]).to eq("failed")
    # No keyword without the AST, but the step text and location survive.
    expect(failed["failure"]["message"]).to start_with("I fail on purpose (features/login.feature:")
  end

  describe "plugin mode (no --format)" do
    it "reports pass, fail and outline rows while progress output stays untouched" do
      stdout, stderr, status, results = run_cucumber("features/login.feature", "features/outline.feature", mode: "plugin")

      expect(stderr).not_to include("All but one formatter")
      expect(status.exitstatus).to eq(1), stderr
      expect(stdout).to include("scenarios (")
      expect(results.fetch("Login: A user can login")["status"]).to eq("passed")
      expect(results.fetch("Login: A user is rejected")["status"]).to eq("failed")
      expect(results.keys.grep(/Greetings/).size).to eq(4)
      expect(results.fetch("Greetings: Greet users (Admins, row 1)")["tags"]).to eq(%w[admin login smoke])
    end

    it "registers one listener when --format and the plugin are both active" do
      Dir.mktmpdir do |out|
        _stdout, _stderr, _status, results = run_cucumber(
          "features/login.feature", mode: "both",
          format_args: ["--format", "RaiderReporter::Cucumber::Formatter", "--out", File.join(out, "f.out"),
                        "--format", "progress"]
        )
        run = @last[:json]["results"]
        expect(run.size).to eq(5)
        expect(run.map { |r| r["identifier"] }.uniq.size).to eq(5)
        expect(results.size).to eq(5)
      end
    end

    it "can be required outside a cucumber run without raising" do
      output, status = Open3.capture2e(RbConfig.ruby, "-I", lib_dir, "-e", 'require "raider_reporter/cucumber"; puts :ok')
      expect(status.success?).to be(true), output
      expect(output).to include("ok")
    end
  end

  describe "LoadError guard" do
    it "explains a missing cucumber gem" do
      output, status = Open3.capture2e(
        { "RUBYOPT" => nil, "RUBYLIB" => nil }, RbConfig.ruby, "--disable-gems", "-I", lib_dir, "-e", 'require "raider_reporter/cucumber"'
      )
      expect(status.success?).to be(false)
      expect(output).to include("raider_reporter/cucumber needs the cucumber gem (>= 9, < 12)")
    end

    it "re-raises an unrelated LoadError even if its message mentions cucumber" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "cucumber.rb"), 'require "cucumber_helper_that_is_missing"')
        output, status = Open3.capture2e(RbConfig.ruby, "-I", dir, "-I", lib_dir, "-e", 'require "raider_reporter/cucumber"')
        expect(status.success?).to be(false)
        expect(output).to include("cucumber_helper_that_is_missing")
        expect(output).not_to include("needs the cucumber gem")
      end
    end
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

  describe "retries" do
    it "keeps one result per scenario with the final status and the attempt count" do
      Dir.mktmpdir do |dir|
        results = run_cucumber("features/retry.feature", extra_args: ["--retry", "1"], extra_env: attempt_env(dir))[3]

        expect(@last[:json]["results"].size).to eq(2)
        expect(results.fetch("Retry: Flaky then fine")).to include("status" => "passed", "attempts" => 2)
        expect(results.fetch("Retry: Flaky then fine")["failure"]).to be_nil
        expect(results.fetch("Retry: Never recovers")).to include("status" => "failed", "attempts" => 2)
        expect(results.fetch("Retry: Never recovers")["failure"]["message"]).to start_with("When I fail on purpose")
      end
    end

    it "works in plugin mode and reports attempts 1 without --retry" do
      Dir.mktmpdir do |dir|
        results = run_cucumber("features/retry.feature", mode: "plugin", extra_args: ["--retry", "1"],
                                                         extra_env: attempt_env(dir))[3]
        expect(results.fetch("Retry: Flaky then fine")).to include("status" => "passed", "attempts" => 2)
      end
      results = run_cucumber("features/login.feature")[3]
      expect(results.fetch("Login: A user can login")["attempts"]).to eq(1)
    end
  end

  describe "attachments" do
    def attachment_names(result) = result["attachments"].map { |a| a["name"] }

    %w[formatter plugin].each do |mode|
      it "copies a RaiderReporter.attach file under attachments/ (#{mode} mode)" do
        Dir.mktmpdir do |dir|
          results = run_cucumber("features/attachments.feature", mode: mode, extra_env: attempt_env(dir))[3]
          result = results.fetch("Attachments: Raider attach in a step")

          expect(result["attachments"].size).to eq(1)
          expect(result["attachments"].first).to include("name" => "screenshot", "content_type" => "image/png")
          expect(result["attachments"].first["path"]).to match(%r{\Aattachments/\d+-shot\.png\z})
          expect(@last[:files]).to include(result["attachments"].first["path"])
        end
      end

      it "captures cucumber's own attach of an existing file by its basename (#{mode} mode)" do
        Dir.mktmpdir do |dir|
          results = run_cucumber("features/attachments.feature", mode: mode, extra_env: attempt_env(dir))[3]
          attachment = results.fetch("Attachments: Cucumber attach of a file")["attachments"].fetch(0)

          expect(attachment).to include("name" => "shot.png", "content_type" => "image/png")
        end
      end
    end

    it "ignores cucumber attach of inline text without warning" do
      Dir.mktmpdir do |dir|
        _out, stderr, status, results = run_cucumber("features/attachments.feature", mode: "plugin",
                                                                                     extra_env: attempt_env(dir))
        expect(results.fetch("Attachments: Cucumber attach of inline text")["attachments"]).to eq([])
        expect(stderr.scan("[raider_reporter]").size).to be <= 1
        expect(status.exitstatus).to eq(1) # only the flaky scenario fails, without --retry
      end
    end

    it "drops attachments from earlier attempts" do
      Dir.mktmpdir do |dir|
        results = run_cucumber("features/attachments.feature", mode: "plugin", extra_args: ["--retry", "1"],
                                                               extra_env: attempt_env(dir))[3]
        flaky = results.fetch("Attachments: Attach then flake")

        expect(flaky).to include("status" => "passed", "attempts" => 2)
        expect(flaky["attachments"]).to eq([])
        expect(@last[:files].grep(/shot\.png/).size).to eq(2) # only the two scenarios that attach once keep theirs
      end
    end

    it "keeps the final attempt's attachment when the last attempt fails" do
      Dir.mktmpdir do |dir|
        results = run_cucumber("features/attachments.feature", mode: "plugin", extra_env: attempt_env(dir))[3]
        flaky = results.fetch("Attachments: Attach then flake")

        expect(flaky).to include("status" => "failed", "attempts" => 1)
        expect(attachment_names(flaky)).to eq(["screenshot"])
      end
    end
  end

  describe "dry run" do
    %w[formatter plugin].each do |mode|
      it "writes no run.json and exits 0 (#{mode} mode)" do
        _out, stderr, status, = run_cucumber("features/login.feature", mode: mode, extra_args: ["--dry-run"])

        expect(status.exitstatus).to eq(0), stderr
        expect(@last[:files]).to be_empty
      end
    end
  end

  describe "shards" do
    it "writes run-<n>.json per parallel_tests process with shard fields" do
      Dir.mktmpdir do |out|
        base = { "PARALLEL_TEST_GROUPS" => "2" }
        run_cucumber("features/login.feature", mode: "plugin", out_dir: out, extra_env: base.merge("TEST_ENV_NUMBER" => ""))
        run_cucumber("features/outline.feature", mode: "plugin", out_dir: out, extra_env: base.merge("TEST_ENV_NUMBER" => "2"))

        expect(@last[:runs].keys).to contain_exactly("run-1.json", "run-2.json")
        expect(@last[:runs]["run-1.json"]["run"]["shard"]).to include("index" => 1, "total" => 2)
        expect(@last[:runs]["run-2.json"]["run"]["shard"]).to include("index" => 2, "total" => 2)
        expect(@last[:runs]["run-1.json"]["results"].map { |r| r["file_path"] }.uniq).to eq(["features/login.feature"])
        expect(@last[:runs]["run-2.json"]["results"].map { |r| r["file_path"] }.uniq).to eq(["features/outline.feature"])
      end
    end
  end

  describe "fail-open" do
    def normalized(stdout) = stdout.gsub(/\d+m\d+\.\d+s/, "XmY.Zs")

    %w[formatter plugin].each do |mode|
      it "warns on stderr but leaves cucumber's exit status and stdout unchanged when the collector raises (#{mode})" do
        base_stdout, _stderr, base_status, = run_cucumber("features/login.feature", mode: mode)
        stdout, stderr, status, = run_cucumber("features/login.feature", mode: mode, extra_env: { "RAIDER_FIXTURE_BOOM" => "1" })

        expect(stderr).to include("[raider_reporter]")
        expect(status.exitstatus).to eq(base_status.exitstatus)
        expect(normalized(stdout)).to eq(normalized(base_stdout))
      end
    end
  end

  describe "attach capture isolation" do
    it "ignores a log of an existing path and captures a Pathname attach" do
      Dir.mktmpdir do |dir|
        results = run_cucumber("features/attach_edges.feature", mode: "plugin", extra_env: attempt_env(dir))[3]

        expect(results.fetch("Attach edges: Log of a path")["attachments"]).to eq([])
        expect(results.fetch("Attach edges: Pathname attach")["attachments"].first).to include("name" => "shot.png")
      end
    end

    it "still reports everything, with one warning, when installing the attach hook fails" do
      Dir.mktmpdir do |dir|
        _out, stderr, status, results = run_cucumber(
          "features/attach_edges.feature", mode: "plugin",
                                           extra_env: attempt_env(dir).merge("FIXTURE_BREAK_CAPTURE" => "1")
        )
        expect(status.exitstatus).to eq(0), stderr
        expect(results.size).to eq(3)
        expect(stderr.scan("[raider_reporter]").size).to eq(1)
        expect(results.values.flat_map { |r| r["attachments"] }).to eq([])
      end
    end

    it "warns once and still runs when registering the plugin hook fails inside a run" do
      _out, stderr, status, results = run_cucumber("features/login.feature:3", mode: "plugin",
                                                                            extra_env: { "FIXTURE_BREAK_INSTALL" => "1" })
      expect(status.exitstatus).to eq(0), stderr
      expect(results).to be_empty
      expect(stderr.scan("[raider_reporter]").size).to eq(1)
      expect(stderr).to include("registry is gone")
    end

    it "records nothing when cucumber's own attach raises" do
      Dir.mktmpdir do |dir|
        results = run_cucumber("features/attach_edges.feature:9", mode: "plugin",
                                                                  extra_env: attempt_env(dir).merge("FIXTURE_BREAK_RUNTIME_ATTACH" => "1"))[3]
        result = results.fetch("Attach edges: Cucumber attach file")
        expect(result["status"]).to eq("failed")
        expect(result["attachments"]).to eq([])
      end
    end

    it "keeps the step passing when RaiderReporter.attach raises inside the capture" do
      Dir.mktmpdir do |dir|
        _out, stderr, status, results = run_cucumber(
          "features/attach_edges.feature:9", mode: "plugin",
                                             extra_env: attempt_env(dir).merge("FIXTURE_BREAK_ATTACH" => "1")
        )
        expect(status.exitstatus).to eq(0), stderr
        expect(results.fetch("Attach edges: Cucumber attach file")).to include("status" => "passed", "attachments" => [])
        expect(stderr).to include("[raider_reporter]")
      end
    end

    it "passes the return value of attach through unchanged" do
      base = Class.new { def attach(*) = :cucumber_result }
      world = Class.new(base) { prepend RaiderReporter::Cucumber::Formatter::AttachCapture }

      expect(world.new.attach("inline", "text/plain")).to eq(:cucumber_result)
    end

    it "forwards every argument cucumber passes, including a filename and future ones" do
      seen = nil
      base = Class.new { def attach(*args, **) = args }
      world = Class.new(base) { prepend RaiderReporter::Cucumber::Formatter::AttachCapture }
      allow(RaiderReporter::Cucumber::Formatter).to receive(:record_attachment) { |*a| seen = a }

      expect(world.new.attach("/tmp/a.png", "image/png", "shot.png", :future)).to eq(["/tmp/a.png", "image/png", "shot.png", :future])
      expect(seen).to eq(["/tmp/a.png", "image/png"])
    end

    it "does not leak the dry-run flag into the next run" do
      Dir.mktmpdir do |dir|
        bus = Object.new
        config = Struct.new(:event_bus).new(bus)
        RaiderReporter.reset!
        RaiderReporter.configure { |c| c.output_dir = dir }
        RaiderReporter.dry_run = true
        RaiderReporter::Cucumber::Formatter.release(config)
        RaiderReporter.start_collector!.start_run
        RaiderReporter.finish!(StringIO.new)

        expect(File).to exist(File.join(dir, "run.json"))
      ensure
        RaiderReporter.reset!
      end
    end
  end

  describe "quarantine" do
    let(:key) { RaiderReporter.test_key("features/quarantine.feature", "Quarantine: A known flaky failure") }

    it "reports a quarantined scenario as quarantined with its step-first failure, and writes schema 2" do
      FakeRaider.with_quarantine([key]) do |env, server|
        _stdout, stderr, status, results = run_cucumber("features/quarantine.feature", extra_env: env)

        expect(status.exitstatus).to eq(1), stderr
        expect(@last[:json]["schema_version"]).to eq(2)
        expect(results.fetch("Quarantine: A stable check")["status"]).to eq("passed")
        flaky = results.fetch("Quarantine: A known flaky failure")
        expect(flaky["status"]).to eq("quarantined")
        expect(flaky["failure"]["message"]).to start_with("When I fail on purpose (features/quarantine.feature:")
        expect(flaky["failure"]["exception_class"]).to eq("ArgumentError")
        expect(server.requests.count { |r| r[:method] == "GET" }).to eq(1)
      end
    end

    it "quarantines in plugin mode too and leaves other statuses alone" do
      FakeRaider.with_quarantine([key]) do |env, _server|
        _stdout, _stderr, _status, results = run_cucumber("features/quarantine.feature", mode: "plugin", extra_env: env)
        expect(results.transform_values { |r| r["status"] })
          .to eq("Quarantine: A stable check" => "passed", "Quarantine: A known flaky failure" => "quarantined")
      end
    end

    it "keeps the failure failed when the scenario is not on the list" do
      FakeRaider.with_quarantine(["0" * 64]) do |env, _server|
        _stdout, _stderr, _status, results = run_cucumber("features/quarantine.feature", extra_env: env)
        expect(results.fetch("Quarantine: A known flaky failure")["status"]).to eq("failed")
        expect(@last[:json]["schema_version"]).to eq(1)
      end
    end
  end

  describe "exec summary" do
    def summary_of(feature = "features/login.feature", *args, extra_env: {})
      Dir.mktmpdir do |dir|
        path = File.join(dir, "summary.json")
        run_cucumber(feature, extra_args: args, extra_env: extra_env.merge("RAIDER_EXEC_SUMMARY" => path))
        JSON.parse(File.read(path)).except("pid")
      end
    end

    it "counts failed and ambiguous scenarios" do
      expect(summary_of).to eq("framework_failures" => 2, "quarantined" => 0, "errors_outside_tests" => 0)
    end

    it "also counts pending and undefined scenarios under --strict" do
      expect(summary_of("features/login.feature", "--strict"))
        .to eq("framework_failures" => 4, "quarantined" => 0, "errors_outside_tests" => 0)
    end

    it "reports an error outside tests when --fail-fast stops before every scenario ran" do
      expect(summary_of("features/login.feature", "--fail-fast"))
        .to eq("framework_failures" => 1, "quarantined" => 0, "errors_outside_tests" => 1)
    end

    it "counts a quarantined scenario as both a framework failure and quarantined" do
      key = RaiderReporter.test_key("features/quarantine.feature", "Quarantine: A known flaky failure")
      FakeRaider.with_quarantine([key]) do |env, _server|
        expect(summary_of("features/quarantine.feature", extra_env: env))
          .to eq("framework_failures" => 1, "quarantined" => 1, "errors_outside_tests" => 0)
      end
    end
  end
end
