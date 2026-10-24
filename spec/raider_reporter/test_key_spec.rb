# frozen_string_literal: true

RSpec.describe "RaiderReporter.test_key" do
  # The same vectors are pinned in raider_saas spec/models/test_case_spec.rb (TestCase.key_for).
  {
    ["spec/login_spec.rb", "Login works"] => "8c60bc1f23271825db4e5abf04a43fcb67242e773ec55de36fff9fa9ae14de2a",
    ["features/login.feature", "Login: A user is rejected"] =>
      "a3cf30d2a4844c2f019e8856215746a4a3ee51c5a8032d7eadef5da6e5d83212",
    ["spec/a b_spec.rb", "Ünïcode → test"] => "d370dd8cc44d6deff75f1e37427b88ad9a0fd8558c5dfc5ac943f80246ccead4"
  }.each do |(file_path, full_name), key|
    it "hashes #{file_path.inspect} and #{full_name.inspect} like the server" do
      expect(RaiderReporter.test_key(file_path, full_name)).to eq(key)
    end
  end

  it "replaces NUL in either part the way the server's ingest does, keeping the separator" do
    expect(RaiderReporter.test_key("spec/a\u0000_spec.rb", "x\u0000y"))
      .to eq(RaiderReporter.test_key("spec/a\u{FFFD}_spec.rb", "x\u{FFFD}y"))
    expect(RaiderReporter.test_key("a", "b")).not_to eq(RaiderReporter.test_key("a\u{FFFD}b", ""))
  end
end
