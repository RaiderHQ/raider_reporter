# frozen_string_literal: true

require "raider_reporter"

RSpec.describe RaiderReporter::Writers::Html do
  around { |example| Dir.mktmpdir { |dir| @root = dir; example.run } }

  let(:dir) { File.join(@root, "myproj", "raider-results").tap { |d| FileUtils.mkdir_p(d) } }
  let(:html) { File.read(File.join(dir, "index.html")) }

  def result(name, status, **extra)
    { "identifier" => "spec/#{name}_spec.rb:1", "full_name" => name, "file_path" => "spec/#{name}_spec.rb",
      "line_number" => 1, "status" => status, "duration_ms" => 1200, "attempts" => 1, "tags" => [],
      "attachments" => [] }.merge(extra)
  end

  def write_run(file, results, run: {})
    File.write(File.join(dir, file), JSON.generate(
      "schema_version" => 1, "client_run_id" => file,
      "run" => { "started_at" => "2026-10-18T10:00:00.000Z", "finished_at" => "2026-10-18T10:01:05.000Z" }.merge(run),
      "results" => results
    ))
  end

  it "returns nil and writes nothing when the folder has no run files" do
    expect(described_class.new.write(dir)).to be_nil
    expect(File).not_to exist(File.join(dir, "index.html"))
  end

  it "writes a self-contained page with totals, failures first, and the project name" do
    failure = { "message" => "expected true", "exception_class" => "RSpec::Expectations::ExpectationNotMetError",
                "backtrace" => ["spec/login_spec.rb:9:in 'block'"] }
    write_run("run.json", [result("login", "failed", "failure" => failure, "attempts" => 2), result("home", "passed")],
              run: { "git" => { "branch" => "main", "commit_sha" => "abcdef1234567" },
                     "ci" => { "provider" => "github_actions", "build_url" => "https://github.com/o/r/actions/runs/1" } })

    path = described_class.new.write(dir)

    expect(path).to eq(File.join(dir, "index.html"))
    expect(html).to include(described_class::MARKER, "<title>myproj · Raider report</title>")
    expect(html).to include("1 passed", "1 failed", "50%", "1m 5s", "main", "abcdef1", "GitHub Actions")
    expect(html.index("login")).to be < html.index("home")
    expect(html).to include("ExpectationNotMetError", "expected true", "spec/login_spec.rb:9", "2 attempts")
    expect(html).to match(/<details[^>]*open[^>]*>\s*<summary[^>]*>Failed/)
    expect(html.scan(%r{https?://[^"'\s<)]+})).to eq(["https://github.com/o/r/actions/runs/1"])
  end

  it "merges every shard file into one report" do
    write_run("run-0.json", [result("a", "passed")])
    write_run("run-1.json", [result("b", "failed")])

    described_class.new.write(dir)

    expect(html).to include("spec/a_spec.rb", "spec/b_spec.rb", "1 passed", "1 failed")
  end

  it "escapes every run value" do
    evil = "</pre><script>alert(1)</script>"
    write_run("run.json", [result(evil, "failed",
                                  "failure" => { "message" => evil, "exception_class" => evil, "backtrace" => [evil] },
                                  "attachments" => [{ "name" => evil, "content_type" => "text/plain",
                                                      "path" => "attachments/0-log.txt" }])],
              run: { "git" => { "branch" => evil } })

    described_class.new.write(dir)

    expect(html).not_to include("<script>alert(1)")
    expect(html).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
  end

  it "inlines images, links other files, encodes path segments, and drops unsafe paths" do
    attachments = [
      { "name" => "screenshot", "content_type" => "image/png", "path" => "attachments/0-my shot#1.png" },
      { "name" => "log", "content_type" => "text/plain", "path" => "attachments/1-log.txt" },
      { "name" => "up", "content_type" => "text/plain", "path" => "../secret.txt" },
      { "name" => "abs", "content_type" => "text/plain", "path" => "/etc/passwd" }
    ]
    write_run("run.json", [result("shots", "failed", "attachments" => attachments)])

    described_class.new.write(dir)

    expect(html).to include('<img loading="lazy" src="attachments/0-my%20shot%231.png"')
    expect(html).to include('<a href="attachments/1-log.txt">log</a>')
    expect(html).not_to include("secret.txt", "/etc/passwd")
  end

  it "leaves out empty sections and renders a run with no results" do
    write_run("run.json", [])

    described_class.new.write(dir)

    expect(html).to include("No results", "—")
    expect(html).not_to match(/<summary[^>]*>(Failed|Passed|Pending|Skipped)/)
  end

  it "skips unreadable run files and names them in the footer" do
    write_run("run.json", [result("ok", "passed")])
    File.write(File.join(dir, "run-1.json"), "{ truncated")
    File.write(File.join(dir, "run-2.json"), JSON.generate("schema_version" => 1))

    described_class.new.write(dir)

    expect(html).to include("spec/ok_spec.rb", "Skipped unreadable run files: run-1.json, run-2.json")
  end

  it "caps each section at ROW_LIMIT rows" do
    stub_const("#{described_class}::ROW_LIMIT", 2)
    write_run("run.json", Array.new(5) { |i| result("t#{i}", "passed") })

    described_class.new.write(dir)

    expect(html.scan('class="r ').size).to eq(2)
    expect(html).to include("3 more not shown")
  end

  it "replaces its own index.html atomically and leaves no temp file" do
    write_run("run.json", [result("a", "passed")])
    described_class.new.write(dir)
    write_run("run.json", [result("b", "passed")])

    described_class.new.write(dir)

    expect(html).to include("spec/b_spec.rb")
    expect(Dir.children(dir).grep(/tmp/)).to be_empty
  end

  it "refuses to overwrite an index.html it did not write" do
    write_run("run.json", [result("a", "passed")])
    File.write(File.join(dir, "index.html"), "<html>mine</html>")

    expect { described_class.new.write(dir) }.to raise_error(described_class::ForeignFile, /not written by raider_reporter/)
    expect(html).to eq("<html>mine</html>")
  end

  it "ignores files that only look like run files" do
    write_run("run.json", [result("a", "passed")])
    File.write(File.join(dir, "runner.json"), "{}")

    described_class.new.write(dir)

    expect(html).not_to include("Skipped unreadable")
  end
end
