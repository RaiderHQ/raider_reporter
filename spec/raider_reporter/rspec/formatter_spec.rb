# frozen_string_literal: true

require "open3"
require "rbconfig"
require "raider_reporter/rspec/formatter"
require_relative "../../support/fake_raider"

RSpec.describe "RaiderReporter::RSpec::Formatter" do
  let(:lib_dir) { File.expand_path("../../../lib", __dir__) }
  let(:fixture) { File.expand_path("../../fixtures/sample_suite/sample_spec.rb", __dir__) }

  def run_suite(dir, extra_env = {}, extra_args = [])
    FileUtils.cp(fixture, File.join(dir, "sample_spec.rb"))
    env = { "RAIDER_TOKEN" => nil, "RAIDER_ENDPOINT" => nil, "RAIDER_QUARANTINE" => nil, "RAIDER_EXEC_SUMMARY" => nil,
            "GITHUB_ACTIONS" => nil, "GITHUB_JOB" => nil }.merge(extra_env)
    Open3.capture2e(
      env, RbConfig.ruby, "-I", lib_dir, Gem.bin_path("rspec-core", "rspec"),
      "--require", "raider_reporter/rspec", "--format", "progress",
      "--format", "RaiderReporter::RSpec::Formatter", *extra_args, "sample_spec.rb",
      chdir: dir
    )
  end

  it "writes run.json describing every example and keeps rspec's exit status" do
    Dir.mktmpdir do |dir|
      output, status = run_suite(dir)
      expect(status.exitstatus).to eq(1), output

      json = JSON.parse(File.read(File.join(dir, "raider-results", "run.json")))
      results = json["results"].sort_by { |r| r["line_number"] }

      expect(json["schema_version"]).to eq(1)
      expect(json["client_run_id"]).to match(/\A[0-9a-f-]{36}\z/)
      expect(results.map { |r| r["status"] }).to eq(%w[passed failed passed pending skipped failed])
      expect(results[0]["tags"]).to eq(["smoke"])
      expect(results[0]["file_path"]).to eq("sample_spec.rb")
      expect(results[0]["identifier"]).to eq("./sample_spec.rb[1:1]")
      expect(results[1]["failure"]["exception_class"]).to eq("RSpec::Expectations::ExpectationNotMetError")
      expect(results[1]["failure"]["message"]).to include("expected: 2")
      expect(results[1]["attachments"]).to eq(
        [{ "name" => "screenshot", "content_type" => "image/png", "path" => "attachments/0-shot.png" }]
      )
      expect(File).to exist(File.join(dir, "raider-results", "attachments", "0-shot.png"))
      expect(results[2]["attempts"]).to eq(2)
      expect(results.map { |r| r["full_name"] }).to include("Sample passes")
      expect(results[5]["failure"]["message"]).to eq("bad ? bytes")
    end
  end

  it "reports the first project frame from the raw backtrace as app_frame" do
    Dir.mktmpdir do |dir|
      run_suite(dir)
      results = JSON.parse(File.read(File.join(dir, "raider-results", "run.json")))["results"].sort_by { |r| r["line_number"] }

      expect(results[1]["failure"]["app_frame"]).to match(/\Asample_spec\.rb:\d+:in /)
      expect(results[5]["failure"]["app_frame"]).to match(/\Asample_spec\.rb:\d+:in /)
    end
  end

  it "writes in-project backtrace frames project-relative" do
    Dir.mktmpdir do |dir|
      run_suite(dir)
      results = JSON.parse(File.read(File.join(dir, "raider-results", "run.json")))["results"].sort_by { |r| r["line_number"] }
      backtrace = results[1]["failure"]["backtrace"]

      expect(backtrace).to include(a_string_matching(/\Asample_spec\.rb:\d+/))
      expect(backtrace).not_to include(a_string_starting_with(dir))
    end
  end

  it "still reports the failure when AppFrame.from raises" do
    Dir.mktmpdir do |dir|
      boom = File.join(dir, "boom.rb")
      File.write(boom, "require 'raider_reporter'\nRaiderReporter::AppFrame.define_singleton_method(:from) { |*, **| raise 'nope' }\n")
      output, = run_suite(dir, {}, ["--require", boom])
      failure = JSON.parse(File.read(File.join(dir, "raider-results", "run.json")))["results"].find { |r| r["status"] == "failed" }["failure"]

      expect(failure["message"]).to include("expected: 2"), output
      expect(failure).not_to have_key("app_frame")
    end
  end

  it "uses the first sub-exception's backtrace when an aggregate exception has none" do
    Dir.mktmpdir do |dir|
      file = File.join(File.realpath(dir), "helper.rb")
      File.write(file, "")
      sub = StandardError.new("inner")
      sub.set_backtrace(["#{file}:3:in 'block'"])
      aggregate = Class.new(StandardError) { define_method(:all_exceptions) { [sub] } }.new("many")
      formatter = RaiderReporter::RSpec::Formatter.allocate
      allow(RaiderReporter).to receive(:project_root).and_return(File.realpath(dir))

      expect(formatter.send(:app_frame_for, aggregate)).to eq("helper.rb:3:in 'block'")
    end
  end

  it "keeps both shards' output when two processes share raider-results" do
    Dir.mktmpdir do |dir|
      run_suite(dir, { "TEST_ENV_NUMBER" => "" })
      run_suite(dir, { "TEST_ENV_NUMBER" => "2" })
      out = File.join(dir, "raider-results")

      expect(File).not_to exist(File.join(out, "run.json"))
      [1, 2].each do |i|
        json = JSON.parse(File.read(File.join(out, "run-#{i}.json")))
        expect(json["run"]["shard"]["index"]).to eq(i)
        path = json["results"].flat_map { |r| r["attachments"] }.first["path"]
        expect(path).to eq("attachments-#{i}/0-shot.png")
        expect(File).to exist(File.join(out, path))
      end
    end
  end

  it "keeps both processes' output when a matrix leg also runs parallel_tests" do
    Dir.mktmpdir do |dir|
      leg = { "RAIDER_SHARD_INDEX" => "1", "RAIDER_SHARD_TOTAL" => "1", "PARALLEL_TEST_GROUPS" => "2" }
      run_suite(dir, leg.merge("TEST_ENV_NUMBER" => ""))
      run_suite(dir, leg.merge("TEST_ENV_NUMBER" => "2"))
      out = File.join(dir, "raider-results")

      [1, 2].each do |i|
        json = JSON.parse(File.read(File.join(out, "run-#{i}.json")))
        expect(json["run"]["shard"]).to include("index" => i, "total" => 2, "label" => "local#1.#{i}")
        expect(File).to exist(File.join(out, "attachments-#{i}", "0-shot.png"))
      end
    end
  end

  it "never changes the exit status when the output dir cannot be written" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "raider-results"), "a file, not a directory")
      output, status = run_suite(dir)
      expect(status.exitstatus).to eq(1)
      expect(output).to include("[raider_reporter]")
    end
  end

  it "writes and uploads nothing on a dry run" do
    Dir.mktmpdir do |dir|
      output, status = run_suite(dir, {}, ["--dry-run"])
      expect(status.exitstatus).to eq(0), output
      expect(File).not_to exist(File.join(dir, "raider-results", "run.json"))
      expect(output).not_to include("[raider_reporter]")
    end
  end

  describe "quarantine" do
    def run_json(dir) = JSON.parse(File.read(File.join(dir, "raider-results", "run.json")))

    it "reports a quarantined failure as quarantined, keyed on the ./-stripped path, with schema 2" do
      # RSpec's metadata says ./sample_spec.rb; the payload and the server key say sample_spec.rb.
      key = RaiderReporter.test_key("sample_spec.rb", "Sample fails with a screenshot")
      Dir.mktmpdir do |dir|
        FakeRaider.with_quarantine([key]) do |env, server|
          output, status = run_suite(dir, env)

          expect(status.exitstatus).to eq(1), output
          json = run_json(dir)
          results = json["results"].sort_by { |r| r["line_number"] }
          expect(json["schema_version"]).to eq(2)
          expect(results.map { |r| r["status"] }).to eq(%w[passed quarantined passed pending skipped failed])
          expect(results[1]["identifier"]).to eq("./sample_spec.rb[1:2]")
          expect(results[1]["failure"]["message"]).to include("expected: 2")
          expect(results[1]["failure"]["app_frame"]).to match(/\Asample_spec\.rb:\d+:in /)
          expect(results[1]["attachments"].map { |a| a["name"] }).to eq(["screenshot"])
          gets = server.requests.select { |r| r[:method] == "GET" }
          expect(gets.map { |r| r[:path] }).to eq(["/api/v1/quarantine"])
          expect(gets.first[:headers]).to include("authorization" => "Bearer tok", "accept" => "application/json")
        end
      end
    end

    it "keeps failures failed and warns once when the list cannot be fetched" do
      Dir.mktmpdir do |dir|
        env = { "RAIDER_TOKEN" => "tok", "RAIDER_ENDPOINT" => "http://127.0.0.1:9", "RAIDER_QUARANTINE" => "1" }
        output, status = run_suite(dir, env)

        expect(status.exitstatus).to eq(1)
        expect(output.scan("quarantine list unavailable (").size).to eq(1), output
        json = run_json(dir)
        expect(json["schema_version"]).to eq(1)
        expect(json["results"].count { |r| r["status"] == "failed" }).to eq(2)
      end
    end

    it "makes no quarantine request when RAIDER_QUARANTINE is not set" do
      Dir.mktmpdir do |dir|
        FakeRaider.with_quarantine(["x"]) do |env, server|
          run_suite(dir, env.except("RAIDER_QUARANTINE"))
          expect(server.requests.map { |r| r[:method] }).to eq(["POST"])
        end
      end
    end
  end

  def run_source(dir, source, extra_env = {}, extra_args = [])
    File.write(File.join(dir, "inline_spec.rb"), source)
    env = { "RAIDER_TOKEN" => nil, "RAIDER_ENDPOINT" => nil, "RAIDER_QUARANTINE" => nil, "RAIDER_EXEC_SUMMARY" => nil,
            "GITHUB_ACTIONS" => nil, "GITHUB_JOB" => nil }.merge(extra_env)
    Open3.capture2e(
      env, RbConfig.ruby, "-I", lib_dir, Gem.bin_path("rspec-core", "rspec"),
      "--require", "raider_reporter/rspec", "--format", "progress",
      "--format", "RaiderReporter::RSpec::Formatter", *extra_args, "inline_spec.rb",
      chdir: dir
    )
  end

  describe "exec summary" do
    def summary_env(dir) = { "RAIDER_EXEC_SUMMARY" => File.join(dir, "summary.json") }

    def summary(dir) = JSON.parse(File.read(File.join(dir, "summary.json"))).except("pid")

    it "writes RSpec's failure count with no errors outside examples" do
      Dir.mktmpdir do |dir|
        output, = run_suite(dir, summary_env(dir))
        expect(summary(dir)).to eq({ "framework_failures" => 2, "quarantined" => 0, "errors_outside_tests" => 0 }), output
      end
    end

    it "counts the quarantined failures it reported" do
      key = RaiderReporter.test_key("sample_spec.rb", "Sample fails with a screenshot")
      Dir.mktmpdir do |dir|
        FakeRaider.with_quarantine([key]) do |env, _server|
          run_suite(dir, env.merge(summary_env(dir)))
          expect(summary(dir)).to eq("framework_failures" => 2, "quarantined" => 1, "errors_outside_tests" => 0)
        end
      end
    end

    it "counts an after(:context) error as an error outside examples" do
      Dir.mktmpdir do |dir|
        output, = run_source(dir, <<~RUBY, summary_env(dir))
          RSpec.describe "Q" do
            after(:context) { raise "teardown exploded" }
            it("fails") { expect(1).to eq(2) }
          end
        RUBY
        expect(summary(dir)).to eq({ "framework_failures" => 1, "quarantined" => 0, "errors_outside_tests" => 1 }), output
      end
    end

    it "counts a --fail-fast stop as an error outside examples" do
      Dir.mktmpdir do |dir|
        output, = run_suite(dir, summary_env(dir), ["--fail-fast"])
        expect(summary(dir)).to eq({ "framework_failures" => 1, "quarantined" => 0, "errors_outside_tests" => 1 }), output
      end
    end

    it "writes no summary on a dry run" do
      Dir.mktmpdir do |dir|
        run_suite(dir, summary_env(dir), ["--dry-run"])
        expect(File).not_to exist(File.join(dir, "summary.json"))
      end
    end
  end

  describe "live events" do
    def events_in(events_dir)
      File.readlines(File.join(events_dir, "worker-1.ndjson")).map { |line| JSON.parse(line) }
    end

    def run_with_events(dir, *args)
      events_dir = File.join(dir, "events")
      run_suite(dir, { "RAIDER_EVENTS_DIR" => events_dir }, args)
      events_in(events_dir)
    end

    it "plans exactly the filtered examples" do
      Dir.mktmpdir do |dir|
        events = run_with_events(dir, "--tag", "smoke")
        plan = events.find { |e| e["type"] == "plan" }
        ran = events.select { |e| e["type"] == "finished" }.map { |e| e["id"] }
        expect(plan["tests"].map { |t| t["id"] }).to eq(ran)
        expect(ran).to eq(["./sample_spec.rb[1:1]"])
        expect(plan["tests"][0]).to include("file" => "sample_spec.rb", "description" => "passes",
                                            "full_name" => "Sample passes")
      end
    end

    it "emits started then finished per example, ending with done" do
      Dir.mktmpdir do |dir|
        events = run_with_events(dir)
        expect(events.first["type"]).to eq("plan")
        expect(events.last).to eq("v" => 1, "type" => "done")
        body = events[1...-1]
        expect(body.map { |e| e["type"] }).to eq(%w[started finished] * 6)
        expect(body.each_slice(2).all? { |s, f| s["id"] == f["id"] }).to be(true)
      end
    end

    it "reports a retried example once with its attempts" do
      Dir.mktmpdir do |dir|
        events = run_with_events(dir)
        retried = events.select { |e| e["type"] == "finished" && e["id"] == "./sample_spec.rb[1:3]" }
        expect(retried.size).to eq(1)
        expect(retried[0]["attempts"]).to eq(2)
      end
    end

    it "emits quarantined as the finished status" do
      Dir.mktmpdir do |dir|
        key = RaiderReporter.test_key("sample_spec.rb", "Sample fails with a screenshot")
        events_dir = File.join(dir, "events")
        FakeRaider.with_quarantine([key]) do |env, _server|
          run_suite(dir, env.merge("RAIDER_EVENTS_DIR" => events_dir))
        end
        statuses = events_in(events_dir).select { |e| e["type"] == "finished" }.map { |e| e["status"] }
        expect(statuses).to include("quarantined")
      end
    end

    it "writes no events file when RAIDER_EVENTS_DIR is unset" do
      Dir.mktmpdir do |dir|
        run_suite(dir, { "RAIDER_EVENTS_DIR" => nil })
        expect(Dir.glob(File.join(dir, "**", "*.ndjson"))).to be_empty
      end
    end
  end
end
