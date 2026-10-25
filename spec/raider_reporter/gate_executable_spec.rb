# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "socket"
require_relative "../support/fake_raider"

RSpec.describe "raider-reporter gate (child process)" do
  let(:lib_dir) { File.expand_path("../../lib", __dir__) }
  let(:exe) { File.expand_path("../../exe/raider-reporter", __dir__) }
  let(:ci_env) do
    { "GITHUB_ACTIONS" => "true", "GITHUB_REPOSITORY" => "RaiderHQ/demo", "GITHUB_RUN_ID" => "99",
      "GITHUB_RUN_ATTEMPT" => "1", "GITHUB_TOKEN" => nil, "GITHUB_EVENT_PATH" => nil, "GITHUB_EVENT_NAME" => nil,
      "GITHUB_SHA" => nil, "TF_BUILD" => nil, "RAIDER_GATE_TIMEOUT" => nil }
  end

  def body(state, rules = [])
    { "state" => state, "build_state" => "passed", "shards" => { "received" => 1, "expected" => nil },
      "rules" => rules, "url" => "http://raider.local/projects/demo/builds/1" }
  end

  def gate_against(reply, env: {})
    server = FakeRaider.new { |_method, path| path.start_with?("/api/v1/builds/gate?") ? [200, JSON.generate(reply)] : [404, "{}"] }
    full_env = ci_env.merge("RAIDER_TOKEN" => "tok", "RAIDER_ENDPOINT" => server.url).merge(env)
    out, err, status = Open3.capture3(full_env, RbConfig.ruby, "-I", lib_dir, exe, "gate")
    [out, err, status.exitstatus, server.requests]
  ensure
    server&.close
  end

  it "exits 0 on passed and asks for this CI build with the project token" do
    out, err, code, requests = gate_against(body("passed", [{ "rule" => "pass_rate", "outcome" => "passed", "detail" => "100% ≥ 98%" }]))

    expect([code, err]).to eq([0, ""])
    expect(out).to eq("raider-reporter gate: passed\n  ✓ pass rate: 100% ≥ 98%\n")
    expect(requests.map { |request| request[:path] })
      .to eq(["/api/v1/builds/gate?build_key=github_actions%3ARaiderHQ%2Fdemo%3A99%3A1"])
    expect(requests.first[:headers]["authorization"]).to eq("Bearer tok")
  end

  it "exits 0 for a project without gate rules" do
    out, _err, code, = gate_against(body("none"))
    expect([code, out]).to eq([0, "raider-reporter gate: no gate rules for this project\n"])
  end

  it "exits 1 when the gate failed" do
    out, err, code, = gate_against(body("failed", [{ "rule" => "pass_rate", "outcome" => "failed", "detail" => "75% < 98%" }]))
    expect([code, out]).to eq([1, ""])
    expect(err).to eq("raider-reporter gate: failed\n  ✗ pass rate: 75% < 98%\n  http://raider.local/projects/demo/builds/1\n")
  end

  it "exits 2 when no verdict arrives before RAIDER_GATE_TIMEOUT" do
    out, err, code, = gate_against(body("pending"), env: { "RAIDER_GATE_TIMEOUT" => "1" })
    expect(code).to eq(2)
    expect(out).to eq("raider-reporter gate: waiting for the verdict (analysing results)\n")
    expect(err).to eq("raider-reporter gate: no verdict after 1s (analysing results)\n")
  end

  it "exits 2 when Raider is unreachable" do
    port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
    env = ci_env.merge("RAIDER_TOKEN" => "tok", "RAIDER_ENDPOINT" => "http://127.0.0.1:#{port}", "RAIDER_GATE_TIMEOUT" => "1")
    _out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib_dir, exe, "gate")
    expect(status.exitstatus).to eq(2)
    expect(err).to start_with("raider-reporter gate: no verdict after 1s (Errno::ECONNREFUSED")
  end
end
