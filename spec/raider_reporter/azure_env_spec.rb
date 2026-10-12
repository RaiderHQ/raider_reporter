# frozen_string_literal: true

require "raider_reporter/azure_env"

RSpec.describe RaiderReporter::AzureEnv do
  describe ".azure?" do
    it "is true for TF_BUILD true in any case" do
      expect(described_class.azure?("TF_BUILD" => "True")).to be(true)
      expect(described_class.azure?("TF_BUILD" => "true")).to be(true)
    end

    it "is false when unset or when GitHub Actions is also set" do
      expect(described_class.azure?({})).to be(false)
      expect(described_class.azure?("TF_BUILD" => "True", "GITHUB_ACTIONS" => "true")).to be(false)
    end
  end

  describe ".value" do
    it "returns nil for unexpanded macros, blanks and missing values" do
      expect(described_class.value({ "A" => "$(System.AccessToken)" }, "A")).to be_nil
      expect(described_class.value({ "A" => "  " }, "A")).to be_nil
      expect(described_class.value({}, "A")).to be_nil
    end

    it "returns the stripped value otherwise" do
      expect(described_class.value({ "A" => " x " }, "A")).to eq("x")
    end
  end

  describe ".collection_base" do
    it "normalizes to exactly one trailing slash" do
      f = ->(uri) { described_class.collection_base("SYSTEM_COLLECTIONURI" => uri) }
      expect(f.("https://dev.azure.com/org")).to eq("https://dev.azure.com/org/")
      expect(f.("https://org.visualstudio.com/")).to eq("https://org.visualstudio.com/")
      expect(f.("https://dev.azure.com/org//")).to eq("https://dev.azure.com/org/")
      expect(described_class.collection_base({})).to be_nil
    end
  end

  describe ".azure_repos_pr?" do
    it "requires a PullRequest build on TfsGit" do
      expect(described_class.azure_repos_pr?("BUILD_REASON" => "PullRequest", "BUILD_REPOSITORY_PROVIDER" => "TfsGit")).to be(true)
      expect(described_class.azure_repos_pr?("BUILD_REASON" => "PullRequest", "BUILD_REPOSITORY_PROVIDER" => "GitHub")).to be(false)
      expect(described_class.azure_repos_pr?("BUILD_REASON" => "IndividualCI", "BUILD_REPOSITORY_PROVIDER" => "TfsGit")).to be(false)
    end
  end

  describe ".strip_heads" do
    it "strips refs/heads/ and rejects other refs" do
      expect(described_class.strip_heads("refs/heads/feature/x")).to eq("feature/x")
      expect(described_class.strip_heads("refs/tags/v1")).to be_nil
      expect(described_class.strip_heads("refs/pull/5/merge")).to be_nil
      expect(described_class.strip_heads(nil)).to be_nil
    end
  end
end
