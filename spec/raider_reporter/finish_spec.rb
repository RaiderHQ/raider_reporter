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
end
