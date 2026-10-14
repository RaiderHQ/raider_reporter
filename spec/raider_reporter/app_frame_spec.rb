# frozen_string_literal: true

RSpec.describe RaiderReporter::AppFrame do
  let(:root) { "/proj" }
  let(:project_line) { "/proj/spec/pages/login_page.rb:42:in 'LoginPage#submit'" }

  def frame(backtrace, root: "/proj") = described_class.from(backtrace, root: root)

  it "returns the first project frame, relative to the root" do
    backtrace = ["/gems/capybara-3/lib/capybara/node.rb:10:in 'find'", project_line, "/proj/spec/login_spec.rb:5:in 'block'"]
    expect(frame(backtrace)).to eq("spec/pages/login_page.rb:42:in 'LoginPage#submit'")
  end

  it "skips vendor and .bundle paths inside the root" do
    backtrace = ["/proj/vendor/bundle/ruby/gems/x/lib/x.rb:1:in 'a'", "/proj/.bundle/gems/y.rb:2:in 'b'", project_line]
    expect(frame(backtrace)).to eq("spec/pages/login_page.rb:42:in 'LoginPage#submit'")
  end

  it "skips Gem.path entries and the ruby library dir even inside the root" do
    allow(Gem).to receive(:path).and_return(["/proj/gemhome"])
    stub_const("RbConfig::CONFIG", RbConfig::CONFIG.merge("rubylibdir" => "/proj/rubylib"))
    backtrace = ["/proj/gemhome/gems/z/lib/z.rb:3:in 'c'", "/proj/rubylib/set.rb:4:in 'd'", project_line]
    expect(frame(backtrace)).to eq("spec/pages/login_page.rb:42:in 'LoginPage#submit'")
  end

  it "skips <internal:...> lines" do
    expect(frame(["<internal:kernel>:187:in 'loop'", project_line])).to eq("spec/pages/login_page.rb:42:in 'LoginPage#submit'")
  end

  it "returns nil for nil, empty or fully external backtraces" do
    expect(frame(nil)).to be_nil
    expect(frame([])).to be_nil
    expect(frame(["/gems/a/lib/a.rb:1:in 'x'", "<internal:kernel>:1:in 'y'"])).to be_nil
  end

  it "does not treat a sibling that shares the root as a prefix as inside it" do
    expect(frame(["/projX/spec/a_spec.rb:1:in 'block'"])).to be_nil
  end

  it "passes the backtick style through unchanged" do
    expect(frame(["/proj/spec/a_spec.rb:7:in `block (2 levels) in <top (required)>'"]))
      .to eq("spec/a_spec.rb:7:in `block (2 levels) in <top (required)>'")
  end

  it "keeps already-relative paths that resolve inside the root" do
    expect(frame(["spec/a_spec.rb:7:in 'block'"], root: Dir.pwd)).to eq("spec/a_spec.rb:7:in 'block'")
  end

  it "truncates results to 500 characters" do
    long = "/proj/spec/a_spec.rb:1:in '#{"x" * 600}'"
    expect(frame([long]).length).to eq(500)
  end
end
