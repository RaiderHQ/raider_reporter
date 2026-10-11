# frozen_string_literal: true

require "raider_reporter/shard_detector"

RSpec.describe RaiderReporter::ShardDetector do
  def shard(env, job: nil) = described_class.new(env: env, job: job).shard

  it "prefers explicit RAIDER_SHARD_* values" do
    expect(shard({ "RAIDER_SHARD_INDEX" => "3", "RAIDER_SHARD_TOTAL" => "4", "TEST_ENV_NUMBER" => "2" }, job: "e2e"))
      .to eq("index" => 3, "total" => 4, "label" => "e2e#3")
  end

  it "maps parallel_tests' TEST_ENV_NUMBER, where empty means 1" do
    expect(shard({ "TEST_ENV_NUMBER" => "", "PARALLEL_TEST_GROUPS" => "2" }))
      .to eq("index" => 1, "total" => 2, "label" => "local#1")
    expect(shard({ "TEST_ENV_NUMBER" => "2" })["index"]).to eq(2)
  end

  it "returns nil when not sharded and ignores invalid values" do
    expect(shard({})).to be_nil
    expect(shard({ "RAIDER_SHARD_INDEX" => "zero" })).to be_nil
    expect(shard({ "RAIDER_SHARD_INDEX" => "0" })).to be_nil
    expect(shard({ "RAIDER_SHARD_INDEX" => "2", "RAIDER_SHARD_TOTAL" => "x" })).to eq("index" => 2, "total" => nil, "label" => "local#2")
  end

  it "treats a blank job as absent" do
    expect(shard({ "RAIDER_SHARD_INDEX" => "2" }, job: "")["label"]).to eq("local#2")
    expect(shard({ "RAIDER_SHARD_INDEX" => "2" }, job: "  ")["label"]).to eq("local#2")
  end
end
