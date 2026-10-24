# frozen_string_literal: true

require "webmock/rspec"

RSpec.describe "RaiderReporter.finish!" do
  let(:out) { StringIO.new }

  around do |example|
    Dir.mktmpdir do |dir|
      RaiderReporter.reset!
      RaiderReporter.configure do |c|
        c.output_dir = File.join(dir, "raider-results")
        c.token = "secret"
        c.endpoint = "https://raider.test"
      end
      example.run
    ensure
      RaiderReporter.reset!
    end
  end

  def run_one_test
    collector = RaiderReporter.start_collector!
    collector.start_run
    collector.start_test
    collector.finish_test(identifier: "i", full_name: "n", file_path: "f", line_number: 1, status: "passed",
                          duration_ms: 1, attempts: 1, tags: [], failure: nil)
  end

  it "prints the report URL after a successful upload" do
    stub_request(:post, "https://raider.test/api/v1/runs")
      .to_return(status: 201, body: { run_id: 9, url: "https://raider.test/runs/9" }.to_json)
    run_one_test
    RaiderReporter.finish!(out)
    expect(out.string).to include("Raider report: https://raider.test/runs/9")
  end

  it "prints the build URL when the server returns a build" do
    body = { run_id: 9, url: "https://raider.test/runs/9", build: { id: 5, url: "https://raider.test/builds/5" } }
    stub_request(:post, "https://raider.test/api/v1/runs").to_return(status: 201, body: body.to_json)
    run_one_test
    RaiderReporter.finish!(out)
    expect(out.string).to eq("Raider report: https://raider.test/builds/5\n")
  end

  it "prints the report line to stderr by default and keeps stdout clean" do
    stub_request(:post, "https://raider.test/api/v1/runs")
      .to_return(status: 201, body: { run_id: 9, url: "https://raider.test/runs/9" }.to_json)
    run_one_test
    expect { RaiderReporter.finish! }
      .to output("Raider report: https://raider.test/runs/9\n").to_stderr
      .and output("").to_stdout
  end

  it "falls back to the run URL when the server returns no build" do
    stub_request(:post, "https://raider.test/api/v1/runs")
      .to_return(status: 201, body: { run_id: 9, url: "https://raider.test/runs/9" }.to_json)
    run_one_test
    RaiderReporter.finish!(out)
    expect(out.string).to eq("Raider report: https://raider.test/runs/9\n")
  end

  it "warns and does not raise when the upload fails" do
    stub_request(:post, "https://raider.test/api/v1/runs").to_return(status: 500, body: "")
    run_one_test
    expect { RaiderReporter.finish!(out) }.to output(/\[raider_reporter\] upload failed: HTTP 500/).to_stderr
  end

  it "skips upload without a token" do
    RaiderReporter.configuration.token = nil
    run_one_test
    RaiderReporter.finish!(out)
    expect(a_request(:any, /raider.test/)).not_to have_been_made
    expect(File).to exist(File.join(RaiderReporter.configuration.output_dir, "run.json"))
  end

  it "prints the run id when the server returns no url" do
    stub_request(:post, "https://raider.test/api/v1/runs").to_return(status: 201, body: { run_id: 9 }.to_json)
    run_one_test
    RaiderReporter.finish!(out)
    expect(out.string).to eq("Raider report uploaded (run 9)\n")
  end

  it "prints a plain confirmation when the server returns neither url nor run id" do
    stub_request(:post, "https://raider.test/api/v1/runs").to_return(status: 201, body: "{}")
    run_one_test
    RaiderReporter.finish!(out)
    expect(out.string).to eq("Raider report uploaded\n")
  end

  it "treats a nil environment as empty" do
    RaiderReporter.configuration.token = nil
    RaiderReporter.configuration.environment = nil
    run_one_test
    RaiderReporter.finish!(out)
    json = JSON.parse(File.read(File.join(RaiderReporter.configuration.output_dir, "run.json")))
    expect(json["run"]["environment"].keys).to eq(%w[ruby os])
  end

  context "HTML report" do
    let(:results_dir) { RaiderReporter.configuration.output_dir }

    before { RaiderReporter.configuration.token = nil }

    it "writes index.html next to run.json" do
      run_one_test
      RaiderReporter.finish!(out)

      expect(File.read(File.join(results_dir, "index.html"))).to include(RaiderReporter::Writers::Html::MARKER)
    end

    it "skips the report when html_report is false" do
      RaiderReporter.configuration.html_report = false
      run_one_test
      RaiderReporter.finish!(out)

      expect(File).to exist(File.join(results_dir, "run.json"))
      expect(File).not_to exist(File.join(results_dir, "index.html"))
    end

    it "keeps run.json and warns when the report fails" do
      allow_any_instance_of(RaiderReporter::Writers::Html).to receive(:write).and_raise(IOError, "disk full")
      run_one_test

      expect { RaiderReporter.finish!(out) }
        .to output(/\[raider_reporter\] HTML report failed: IOError: disk full/).to_stderr
      expect(File).to exist(File.join(results_dir, "run.json"))
    end

    it "still uploads and prints the success line when the report fails" do
      RaiderReporter.configuration.token = "secret"
      stub_request(:post, "https://raider.test/api/v1/runs")
        .to_return(status: 201, body: { run_id: 9, url: "https://raider.test/runs/9" }.to_json)
      allow_any_instance_of(RaiderReporter::Writers::Html).to receive(:write).and_raise(IOError, "disk full")
      run_one_test

      expect { RaiderReporter.finish!(out) }.to output(/HTML report failed/).to_stderr
      expect(out.string).to include("Raider report: https://raider.test/runs/9")
    end
  end

  context "exec summary" do
    let(:summary_path) { File.join(File.dirname(RaiderReporter.configuration.output_dir), "summary.json") }

    before do
      RaiderReporter.configuration.token = nil
      RaiderReporter.configuration.exec_summary_path = summary_path
    end

    def summary = JSON.parse(File.read(summary_path))

    it "writes the framework counts and the number of quarantined results" do
      collector = RaiderReporter.start_collector!
      collector.start_run
      collector.start_test
      collector.finish_test(identifier: "i", full_name: "n", file_path: "f", line_number: 1, status: "quarantined",
                            duration_ms: 1, attempts: 1, tags: [], failure: nil)
      collector.record_framework_counts(failures: 1, errors_outside_tests: 0)

      RaiderReporter.finish!(out)

      expect(summary).to eq("framework_failures" => 1, "quarantined" => 1, "errors_outside_tests" => 0, "pid" => Process.pid)
    end

    it "writes nothing when the framework never reported its counts" do
      run_one_test
      RaiderReporter.finish!(out)
      expect(File).not_to exist(summary_path)
    end

    it "writes nothing without RAIDER_EXEC_SUMMARY" do
      RaiderReporter.configuration.exec_summary_path = nil
      run_one_test
      RaiderReporter.collector.record_framework_counts(failures: 0, errors_outside_tests: 0)
      RaiderReporter.finish!(out)
      expect(File).not_to exist(summary_path)
    end

    it "still writes the summary when raider-results cannot be written" do
      File.write(RaiderReporter.configuration.output_dir, "a file, not a directory")
      run_one_test
      RaiderReporter.collector.record_framework_counts(failures: 0, errors_outside_tests: 0)

      expect { RaiderReporter.finish!(out) }.to output(/could not write/).to_stderr
      expect(summary["framework_failures"]).to eq(0)
    end

    it "warns and carries on when the summary cannot be written" do
      RaiderReporter.configuration.exec_summary_path = File.join(summary_path, "missing", "summary.json")
      run_one_test
      RaiderReporter.collector.record_framework_counts(failures: 0, errors_outside_tests: 0)

      expect { RaiderReporter.finish!(out) }.to output(/could not write the exec summary: Errno::ENOENT/).to_stderr
      expect(File).to exist(File.join(RaiderReporter.configuration.output_dir, "run.json"))
    end
  end
end
