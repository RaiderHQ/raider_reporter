# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "RaiderReporter::RSpec::Formatter" do
  let(:lib_dir) { File.expand_path("../../../lib", __dir__) }
  let(:fixture) { File.expand_path("../../fixtures/sample_suite/sample_spec.rb", __dir__) }

  def run_suite(dir, extra_env = {}, extra_args = [])
    FileUtils.cp(fixture, File.join(dir, "sample_spec.rb"))
    env = { "RAIDER_TOKEN" => nil, "RAIDER_ENDPOINT" => nil }.merge(extra_env)
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
