# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"
require "fileutils"

RSpec.describe RaiderReporter::FailedSteps do
  let(:warnings) { [] }
  let(:spec_file) { "spec/login_spec.rb" }
  let(:spec_source) { (1..12).map { |n| "# line #{n}\n" }.join }
  let(:ranges) do
    [
      { "stepId" => "s1", "start" => 4, "end" => 4, "title" => "Open https://shop.test/login" },
      { "stepId" => "s2", "start" => 5, "end" => 6, "title" => "Type \"ana@shop.test\" into Email" },
      { "stepId" => "s3", "start" => 9, "end" => 9, "title" => "Click \"Save\"" }
    ]
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @root = dir
      example.run
    end
  end

  def write(rel, body)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, body)
    path
  end

  def write_sidecar(overrides = {}, step_lines: :default)
    write(spec_file, spec_source)
    map = { "fileSha256" => Digest::SHA256.hexdigest(spec_source), "ranges" => ranges }
    sidecar = { "version" => 1, "file" => spec_file, "steps" => [] }
    sidecar["stepLines"] = step_lines == :default ? map : step_lines unless step_lines.nil?
    write(".raider/tests/#{spec_file}.json", JSON.generate(sidecar.merge(overrides)))
  end

  def result(backtrace: ["#{spec_file}:9:in 'block (2 levels) in <top (required)>'"], app_frame: nil,
             status: "failed", file_path: spec_file)
    failure = RaiderReporter::Failure.new(message: "boom", exception_class: "RuntimeError",
                                          backtrace: backtrace, app_frame: app_frame)
    RaiderReporter::TestResult.new(identifier: "./#{file_path}[1:1]", full_name: "Login saves", file_path: file_path,
                                   line_number: 3, status: status, duration_ms: 1, attempts: 1, tags: [],
                                   failure: status == "passed" ? nil : failure, attachments: [])
  end

  def steps_for(test_result)
    described_class.new(root: @root, warn: ->(message) { warnings << message }).steps_for(test_result)
  end

  let(:items) do
    [{ "id" => "s1", "title" => "Open https://shop.test/login" },
     { "id" => "s2", "title" => "Type \"ana@shop.test\" into Email" },
     { "id" => "s3", "title" => "Click \"Save\"" }]
  end

  it "names the step whose lines hold the first backtrace frame in the spec file" do
    write_sidecar
    expect(steps_for(result)).to eq("items" => items, "failed" => 2)
    expect(warnings).to be_empty
  end

  it "skips helper frames before the spec frame" do
    write_sidecar
    backtrace = ["pages/login_page.rb:12:in 'LoginPage#save'", "./#{spec_file}:5:in 'block (2 levels)'"]
    expect(steps_for(result(backtrace: backtrace))["failed"]).to eq(1)
  end

  it "uses app_frame when no backtrace frame is in the spec file" do
    write_sidecar
    steps = steps_for(result(backtrace: ["gems/x.rb:1:in 'y'"], app_frame: "#{spec_file}:4:in 'block'"))
    expect(steps["failed"]).to eq(0)
  end

  it "ignores an app_frame outside the spec file" do
    write_sidecar
    steps = steps_for(result(backtrace: [], app_frame: "pages/login_page.rb:9:in 'save'"))
    expect(steps).to eq("items" => items, "failed" => nil)
  end

  it "always sends failed, as null, when the line is outside every step" do
    write_sidecar
    steps = steps_for(result(backtrace: ["#{spec_file}:7:in 'block'"]))
    expect(steps).to have_key("failed")
    expect(steps["failed"]).to be_nil
    expect(JSON.generate(steps)).to include('"failed":null')
  end

  it "lists items in file order, once per step" do
    ranges.reverse!
    ranges << { "stepId" => "s2", "start" => 11, "end" => 11, "title" => "again" }
    write_sidecar
    expect(steps_for(result)["items"].map { |item| item["id"] }).to eq(%w[s1 s2 s3])
  end

  it "sends nothing without a sidecar, quietly" do
    write(spec_file, spec_source)
    expect(steps_for(result)).to be_nil
    expect(warnings).to be_empty
  end

  it "sends nothing for a sidecar without stepLines or without titles" do
    write_sidecar(step_lines: nil)
    expect(steps_for(result)).to be_nil
    ranges[1].delete("title")
    write_sidecar
    expect(steps_for(result)).to be_nil
    expect(warnings).to be_empty
  end

  it "sends nothing when the spec file changed since the map was made" do
    write_sidecar
    write(spec_file, "#{spec_source}# edited\n")
    expect(steps_for(result)).to be_nil
  end

  it "sends nothing when the sidecar is for another file" do
    write_sidecar({ "file" => "spec/other_spec.rb" })
    expect(steps_for(result)).to be_nil
  end

  it "warns once per run for malformed sidecars and maps" do
    write(".raider/tests/#{spec_file}.json", "{ not json")
    finder = described_class.new(root: @root, warn: ->(message) { warnings << message })
    expect(finder.steps_for(result)).to be_nil
    write_sidecar(step_lines: { "fileSha256" => "x", "ranges" => [{ "stepId" => "s1", "start" => 0, "end" => 1 }] })
    expect(finder.steps_for(result)).to be_nil
    expect(warnings.size).to eq(1)
    expect(warnings.first).to include(spec_file)
  end

  it "refuses a symlinked sidecar or a symlinked folder on the way" do
    outside = write("elsewhere.json", JSON.generate("file" => spec_file))
    write(spec_file, spec_source)
    FileUtils.mkdir_p(File.join(@root, ".raider/tests/spec"))
    File.symlink(outside, File.join(@root, ".raider/tests/#{spec_file}.json"))
    expect(steps_for(result)).to be_nil
    FileUtils.rm_rf(File.join(@root, ".raider"))
    FileUtils.mkdir_p(File.join(@root, ".raider"))
    File.symlink(File.join(@root, "spec"), File.join(@root, ".raider/tests"))
    expect(steps_for(result)).to be_nil
  end

  it "refuses a sidecar over 1 MB" do
    write_sidecar({ "padding" => "x" * described_class::MAX_SIDECAR_BYTES })
    expect(steps_for(result)).to be_nil
    expect(warnings.first).to include("larger than")
  end

  it "never reads outside .raider/tests for an unsafe file_path" do
    write(".raider/auth/session.json", JSON.generate("file" => "../auth/session"))
    expect(steps_for(result(file_path: "../auth/session"))).to be_nil
    expect(steps_for(result(file_path: "/etc/passwd"))).to be_nil
  end

  it "sends nothing over 200 steps, and truncates titles to 500 characters" do
    ranges.replace((1..201).map { |n| { "stepId" => "s#{n}", "start" => n, "end" => n, "title" => "t" } })
    write_sidecar
    expect(steps_for(result)).to be_nil

    ranges.replace([{ "stepId" => "s1", "start" => 9, "end" => 9, "title" => "é" * 600 }])
    write_sidecar
    expect(steps_for(result)["items"].first["title"].length).to eq(500)
  end

  it "gives passed and quarantined results no steps" do
    write_sidecar
    expect(steps_for(result(status: "passed"))).to be_nil
    expect(steps_for(result(status: "quarantined"))).to be_nil
  end

  describe ".apply" do
    it "sets steps on failed results only and keeps the rest of the run" do
      write_sidecar
      run = RaiderReporter::Run.new(client_run_id: "c", started_at: nil, finished_at: nil, ci: nil, git: nil,
                                    environment: {}, shard: nil, results: [result, result(status: "passed")])
      applied = described_class.apply(run, root: @root, warn: ->(_) {})
      expect(applied.results.map(&:steps)).to eq([{ "items" => items, "failed" => 2 }, nil])
      expect(RaiderReporter::Payload.new(applied).schema_version).to eq(1)
    end
  end
end
