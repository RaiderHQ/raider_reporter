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

  describe "matrix x parallel_tests" do
    let(:base) { { "RAIDER_SHARD_INDEX" => "2", "RAIDER_SHARD_TOTAL" => "2", "PARALLEL_TEST_GROUPS" => "2" } }

    it "composes the explicit and parallel indexes" do
      expect(shard(base.merge("TEST_ENV_NUMBER" => ""), job: "rspec"))
        .to eq("index" => 3, "total" => 4, "label" => "rspec#2.1")
      expect(shard(base.merge("TEST_ENV_NUMBER" => "2"), job: "rspec"))
        .to eq("index" => 4, "total" => 4, "label" => "rspec#2.2")
    end

    it "leaves total nil without RAIDER_SHARD_TOTAL" do
      env = base.merge("TEST_ENV_NUMBER" => "2").tap { |e| e.delete("RAIDER_SHARD_TOTAL") }
      expect(shard(env, job: "rspec")).to eq("index" => 4, "total" => nil, "label" => "rspec#2.2")
    end

    it "stays explicit-only without a valid PARALLEL_TEST_GROUPS" do
      env = base.merge("TEST_ENV_NUMBER" => "2").tap { |e| e.delete("PARALLEL_TEST_GROUPS") }
      expect(shard(env, job: "rspec")).to eq("index" => 2, "total" => 2, "label" => "rspec#2")
      expect(shard(env.merge("PARALLEL_TEST_GROUPS" => "0"), job: "rspec")["index"]).to eq(2)
    end
  end

  describe "Azure Pipelines" do
    let(:azure) { { "TF_BUILD" => "True", "SYSTEM_JOBPOSITIONINPHASE" => "2", "SYSTEM_TOTALJOBSINPHASE" => "3" } }

    it "maps the job position within the phase" do
      expect(shard(azure, job: "tests")).to eq("index" => 2, "total" => 3, "label" => "tests#2")
    end

    it "ignores a single-job phase" do
      expect(shard(azure.merge("SYSTEM_TOTALJOBSINPHASE" => "1"))).to be_nil
    end

    it "is ignored outside Azure" do
      expect(shard(azure.reject { |k, _| k == "TF_BUILD" })).to be_nil
    end

    it "lets explicit RAIDER_SHARD_INDEX win" do
      expect(shard(azure.merge("RAIDER_SHARD_INDEX" => "1", "RAIDER_SHARD_TOTAL" => "5"), job: "t"))
        .to eq("index" => 1, "total" => 5, "label" => "t#1")
    end

    it "composes with parallel_tests" do
      env = azure.merge("TEST_ENV_NUMBER" => "2", "PARALLEL_TEST_GROUPS" => "2")
      expect(shard(env, job: "tests")).to eq("index" => 4, "total" => 6, "label" => "tests#2.2")
    end
  end
end
