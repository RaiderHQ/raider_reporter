# frozen_string_literal: true

RSpec.describe RaiderReporter::ExecSummary do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "summary.json")
      example.run
    end
  end

  def write(pid: Process.pid, failures: 2, quarantined: 1, errors: 0)
    described_class.write(@path, framework_failures: failures, quarantined: quarantined, errors_outside_tests: errors, pid: pid)
  end

  it "writes the three counts and the writer's pid, and reads the counts back" do
    write
    expect(JSON.parse(File.read(@path))).to eq("framework_failures" => 2, "quarantined" => 1, "errors_outside_tests" => 0,
                                               "pid" => Process.pid)
    expect(described_class.read(@path)).to eq("framework_failures" => 2, "quarantined" => 1, "errors_outside_tests" => 0)
  end

  it "lets the same process overwrite its summary" do
    write
    write(failures: 3, quarantined: 3)
    expect(described_class.read(@path)).to include("framework_failures" => 3, "quarantined" => 3)
  end

  it "turns into a conflict when a second process writes, and stays one" do
    write(pid: 100)
    write(pid: 200)
    expect(JSON.parse(File.read(@path))).to eq("conflict" => true)
    write(pid: 100)
    expect(described_class.read(@path)).to be_nil
  end

  it "reads nothing from a missing, broken or wrong-typed file" do
    expect(described_class.read(@path)).to be_nil
    {
      "{" => "truncated JSON",
      "[]" => "an array",
      '{"framework_failures":"1","quarantined":1,"errors_outside_tests":0}' => "a string count",
      '{"framework_failures":1,"quarantined":1}' => "a missing key",
      '{"framework_failures":-1,"quarantined":-1,"errors_outside_tests":0}' => "negative counts",
      '{"framework_failures":1.0,"quarantined":1,"errors_outside_tests":0}' => "a float"
    }.each do |text, label|
      File.write(@path, text)
      expect(described_class.read(@path)).to be_nil, label
    end
  end
end
