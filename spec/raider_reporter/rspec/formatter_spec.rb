# frozen_string_literal: true

require "open3"
require "rbconfig"
require "raider_reporter/rspec/formatter"

RSpec.describe "RaiderReporter::RSpec::Formatter" do
  let(:lib_dir) { File.expand_path("../../../lib", __dir__) }
  let(:fixture) { File.expand_path("../../fixtures/sample_suite/sample_spec.rb", __dir__) }

  def run_suite(dir, extra_env = {}, extra_args = [])
    FileUtils.cp(fixture, File.join(dir, "sample_spec.rb"))
    env = { "RAIDER_TOKEN" => nil, "RAIDER_ENDPOINT" => nil, "GITHUB_ACTIONS" => nil, "GITHUB_JOB" => nil }.merge(extra_env)
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
end
