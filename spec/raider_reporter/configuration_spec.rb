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
end
