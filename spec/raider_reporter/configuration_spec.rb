# frozen_string_literal: true

RSpec.describe RaiderReporter::Configuration do
  it "reads token and endpoint from env with defaults" do
    config = described_class.new("RAIDER_TOKEN" => "t", "RAIDER_ENDPOINT" => "https://x")
    expect([config.token, config.endpoint, config.output_dir, config.clean_output_dir])
      .to eq(["t", "https://x", "raider-results", true])
    expect(config.max_attachment_bytes).to eq(5 * 1024 * 1024)
  end

  it "uploads only with both token and endpoint present" do
    expect(described_class.new("RAIDER_TOKEN" => "t", "RAIDER_ENDPOINT" => "https://x").upload?).to be(true)
    expect(described_class.new("RAIDER_TOKEN" => "t").upload?).to be(false)
    expect(described_class.new("RAIDER_TOKEN" => " ", "RAIDER_ENDPOINT" => "https://x").upload?).to be(false)
    expect(described_class.new({}).upload?).to be(false)
  end

  it "treats unexpanded Azure macros as missing" do
    config = described_class.new("RAIDER_TOKEN" => "$(RAIDER_TOKEN)", "RAIDER_ENDPOINT" => "$(RAIDER_ENDPOINT)")
    expect([config.token, config.endpoint]).to eq([nil, nil])
    expect(config.upload?).to be(false)
    expect(described_class.new("RAIDER_TOKEN" => "$(RAIDER_TOKEN)", "RAIDER_ENDPOINT" => "https://x").upload?).to be(false)
  end

  it "writes the HTML report by default" do
    expect(described_class.new({}).html_report).to be(true)
  end

  it "turns quarantine on for RAIDER_QUARANTINE 1 or true, in any case" do
    %w[1 true TRUE True].each do |value|
      expect(described_class.new("RAIDER_QUARANTINE" => value).quarantine).to be(true), value
    end
    ["0", "false", "yes", "", " ", "$(RAIDER_QUARANTINE)"].each do |value|
      expect(described_class.new("RAIDER_QUARANTINE" => value).quarantine).to be(false), value.inspect
    end
    expect(described_class.new({}).quarantine).to be(false)
  end

  it "quarantines only with quarantine on and both token and endpoint present" do
    on = { "RAIDER_QUARANTINE" => "1", "RAIDER_TOKEN" => "t", "RAIDER_ENDPOINT" => "https://x" }
    expect(described_class.new(on).quarantine?).to be(true)
    expect(described_class.new(on.except("RAIDER_TOKEN")).quarantine?).to be(false)
    expect(described_class.new(on.except("RAIDER_QUARANTINE")).quarantine?).to be(false)
    configured = described_class.new("RAIDER_TOKEN" => "t", "RAIDER_ENDPOINT" => "https://x")
    configured.quarantine = true
    expect(configured.quarantine?).to be(true)
  end

  it "reads the exec summary path from RAIDER_EXEC_SUMMARY" do
    expect(described_class.new("RAIDER_EXEC_SUMMARY" => "/tmp/s.json").exec_summary_path).to eq("/tmp/s.json")
    expect(described_class.new({}).exec_summary_path).to be_nil
    expect(described_class.new("RAIDER_EXEC_SUMMARY" => "$(RAIDER_EXEC_SUMMARY)").exec_summary_path).to be_nil
  end
end
