# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../support/fake_raider"

RSpec.describe "raider-reporter exec" do
  let(:lib_dir) { File.expand_path("../../lib", __dir__) }
  let(:exe) { File.expand_path("../../exe/raider-reporter", __dir__) }
  let(:clean_env) do
    { "RAIDER_TOKEN" => nil, "RAIDER_ENDPOINT" => nil, "RAIDER_QUARANTINE" => nil, "RAIDER_EXEC_SUMMARY" => nil,
      "GITHUB_ACTIONS" => nil, "GITHUB_JOB" => nil, "TF_BUILD" => nil }
  end

  def raider_exec(*args, env: {}, chdir: Dir.pwd)
    Open3.capture3(clean_env.merge(env), RbConfig.ruby, "-I", lib_dir, exe, "exec", *args, chdir: chdir)
  end

  def ruby(script) = [RbConfig.ruby, "-rjson", "-e", script]

  # A child that writes the summary a formatter would write, then exits.
  def summarizing(exit_code, failures, quarantined, errors)
    ruby(<<~RUBY)
      File.write(ENV.fetch("RAIDER_EXEC_SUMMARY"), JSON.generate("framework_failures" => #{failures},
        "quarantined" => #{quarantined}, "errors_outside_tests" => #{errors}))
      exit #{exit_code}
    RUBY
  end

  describe "decision table" do
    [
      ["the command exits 0", [0, 0, 0, 0], 0, false],
      ["the command exits 0 even with real failures in the summary", [0, 2, 1, 0], 0, false],
      ["every counted failure is quarantined", [1, 2, 2, 0], 0, true],
      ["a real failure sits next to a quarantined one", [1, 2, 1, 0], 1, false],
      ["errors happened outside tests", [1, 1, 1, 1], 1, false],
      ["the framework counted no failures", [1, 0, 0, 0], 1, false],
      ["the command exits 2, even if the summary looks quarantined-only", [2, 1, 1, 0], 2, false]
    ].each do |label, (code, failures, quarantined, errors), expected, notice|
      it "exits #{expected} when #{label}" do
        _out, err, status = raider_exec("--", *summarizing(code, failures, quarantined, errors))

        expect(status.exitstatus).to eq(expected), err
        if notice
          expect(err).to include("raider-reporter: #{quarantined} quarantined failure(s) did not fail the build\n")
        else
          expect(err).not_to include("did not fail the build")
        end
      end
    end

    it "keeps the command's code when there is no summary" do
      _out, _err, status = raider_exec("--", *ruby("exit 1"))
      expect(status.exitstatus).to eq(1)
    end

    {
      "truncated JSON" => "{",
      "string counts" => '{"framework_failures":"1","quarantined":"1","errors_outside_tests":0}',
      "a conflict" => '{"conflict":true}'
    }.each do |label, text|
      it "keeps the command's code for a summary with #{label}" do
        script = "File.write(ENV.fetch('RAIDER_EXEC_SUMMARY'), #{text.inspect}); exit 1"
        _out, err, status = raider_exec("--", *ruby(script))
        expect(status.exitstatus).to eq(1)
        expect(err).not_to include("did not fail the build")
      end
    end
  end

  it "exits 128 + the signal number when the command is killed" do
    _out, _err, status = raider_exec("--", *ruby('Process.kill("KILL", Process.pid); sleep 5'))
    expect(status.exitstatus).to eq(137)
  end

  it "forwards TERM to the command and exits with the command's code" do
    script = 'trap("TERM") { puts "child got TERM"; exit 7 }; puts "ready"; $stdout.flush; sleep 10'
    Open3.popen3(clean_env, RbConfig.ruby, "-I", lib_dir, exe, "exec", "--", *ruby(script)) do |_in, out, _err, thread|
      expect(out.gets).to eq("ready\n")
      Process.kill("TERM", thread.pid)
      expect(out.read).to eq("child got TERM\n")
      expect(thread.value.exitstatus).to eq(7)
    end
  end

  [[], ["--"], ["rspec"]].each do |args|
    it "prints usage and exits 2 for #{(['exec'] + args).join(' ')}" do
      _out, err, status = raider_exec(*args)
      expect(status.exitstatus).to eq(2)
      expect(err).to include("Usage: raider-reporter exec -- <command> [args...]")
    end
  end

  it "exits 127 with the error when the command cannot be started" do
    _out, err, status = raider_exec("--", "raider-no-such-command-xyz")
    expect(status.exitstatus).to eq(127)
    expect(err).to include("[raider_reporter] exec: cannot run raider-no-such-command-xyz:")
  end

  it "streams output, passes the environment plus RAIDER_EXEC_SUMMARY, and removes the summary afterwards" do
    script = 'puts ENV.fetch("RAIDER_EXEC_SUMMARY"); puts ENV.fetch("FROM_PARENT"); warn "to stderr"'
    out, err, status = raider_exec("--", *ruby(script), env: { "FROM_PARENT" => "yes" })

    path, from_parent = out.lines.map(&:chomp)
    expect(status.exitstatus).to eq(0)
    expect(from_parent).to eq("yes")
    expect(err).to include("to stderr")
    expect(File.basename(path)).to eq("summary.json")
    expect(File).not_to exist(File.dirname(path))
  end

  it "runs the command without a shell" do
    out, = raider_exec("--", *ruby("puts ARGV.inspect"), "a b", "$HOME", "*")
    expect(out).to eq(%(["a b", "$HOME", "*"]\n))
  end

  describe "end to end with RSpec and a quarantine list" do
    let(:rspec) { Gem.bin_path("rspec-core", "rspec") }

    def suite(dir, source)
      File.write(File.join(dir, "q_spec.rb"), source)
      [RbConfig.ruby, "-I", lib_dir, rspec, "--require", "raider_reporter/rspec", "--format", "progress",
       "--format", "RaiderReporter::RSpec::Formatter", "q_spec.rb"]
    end

    def key(name) = RaiderReporter.test_key("q_spec.rb", name)

    it "exits 0 when the only failure is quarantined, and 1 once a real failure joins it" do
      Dir.mktmpdir do |dir|
        FakeRaider.with_quarantine([key("Q is flaky")]) do |env, _server|
          only_flaky = suite(dir, <<~RUBY)
            RSpec.describe "Q" do
              it("passes") { expect(1).to eq(1) }
              it("is flaky") { expect(1).to eq(2) }
            end
          RUBY
          _out, err, status = raider_exec("--", *only_flaky, env: env, chdir: dir)
          expect(status.exitstatus).to eq(0), err
          expect(err).to include("raider-reporter: 1 quarantined failure(s) did not fail the build")
          run = JSON.parse(File.read(File.join(dir, "raider-results", "run.json")))
          expect(run["schema_version"]).to eq(2)

          mixed = suite(dir, <<~RUBY)
            RSpec.describe "Q" do
              it("is flaky") { expect(1).to eq(2) }
              it("is broken") { expect(1).to eq(3) }
            end
          RUBY
          _out, err, status = raider_exec("--", *mixed, env: env, chdir: dir)
          expect(status.exitstatus).to eq(1)
          expect(err).not_to include("did not fail the build")
        end
      end
    end

    it "does not exit 0 when an error outside examples comes with a quarantined failure" do
      Dir.mktmpdir do |dir|
        FakeRaider.with_quarantine([key("Q is flaky")]) do |env, _server|
          command = suite(dir, <<~RUBY)
            RSpec.describe "Q" do
              after(:context) { raise "teardown exploded" }
              it("is flaky") { expect(1).to eq(2) }
            end
          RUBY
          _out, err, status = raider_exec("--", *command, env: env, chdir: dir)
          expect(status.exitstatus).to eq(1)
          expect(err).not_to include("did not fail the build")
        end
      end
    end

    it "exits 1 when the list cannot be fetched (fail-open)" do
      Dir.mktmpdir do |dir|
        command = suite(dir, %(RSpec.describe("Q") { it("is flaky") { expect(1).to eq(2) } }\n))
        env = { "RAIDER_TOKEN" => "tok", "RAIDER_ENDPOINT" => "http://127.0.0.1:9", "RAIDER_QUARANTINE" => "1" }
        _out, err, status = raider_exec("--", *command, env: env, chdir: dir)
        expect(status.exitstatus).to eq(1)
        expect(err).to include("quarantine list unavailable (")
      end
    end
  end
end
