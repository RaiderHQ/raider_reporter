# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe RaiderReporter::AppFrame do
  around do |example|
    Dir.mktmpdir do |dir|
      @root = File.realpath(dir)
      %w[spec/pages/login_page.rb spec/login_spec.rb vendor/bundle/x.rb .bundle/y.rb gemhome/gems/z.rb rubylib/set.rb].each do |f|
        FileUtils.mkdir_p(File.dirname(File.join(@root, f)))
        File.write(File.join(@root, f), "")
      end
      example.run
    end
  end

  let(:root) { @root }
  let(:page_line) { "#{root}/spec/pages/login_page.rb:42:in 'LoginPage#submit'" }
  let(:page_frame) { "spec/pages/login_page.rb:42:in 'LoginPage#submit'" }

  def frame(backtrace, root: self.root) = described_class.from(backtrace, root: root)

  it "returns the first project frame, relative to the root" do
    backtrace = ["/gems/capybara-3/lib/capybara/node.rb:10:in 'find'", page_line, "#{root}/spec/login_spec.rb:5:in 'block'"]
    expect(frame(backtrace)).to eq(page_frame)
  end

  it "skips vendor and .bundle paths inside the root" do
    expect(frame(["#{root}/vendor/bundle/x.rb:1:in 'a'", "#{root}/.bundle/y.rb:2:in 'b'", page_line])).to eq(page_frame)
  end

  it "skips Gem.path entries and the ruby library dir even inside the root" do
    allow(Gem).to receive(:path).and_return(["#{root}/gemhome"])
    stub_const("RbConfig::CONFIG", RbConfig::CONFIG.merge("rubylibdir" => "#{root}/rubylib"))
    expect(frame(["#{root}/gemhome/gems/z.rb:3:in 'c'", "#{root}/rubylib/set.rb:4:in 'd'", page_line])).to eq(page_frame)
  end

  it "skips <internal:...> lines" do
    expect(frame(["<internal:kernel>:187:in 'loop'", page_line])).to eq(page_frame)
  end

  {
    "eval" => "(eval):1:in 'x'",
    "erb" => "(erb):1:in 'result'",
    "-e" => "-e:1:in '<main>'",
    "eval at (Ruby 3.3+)" => "(eval at /abs/gems/foo/lib/x.rb:5):1:in 'x'"
  }.each do |name, pseudo|
    it "skips the #{name} pseudo path and picks the next project frame" do
      expect(frame([pseudo, page_line])).to eq(page_frame)
    end
  end

  it "skips project-looking paths that are not files" do
    expect(frame(["#{root}/spec/missing.rb:1:in 'x'", page_line])).to eq(page_frame)
  end

  it "returns nil for nil, empty or fully external backtraces" do
    expect(frame(nil)).to be_nil
    expect(frame([])).to be_nil
    expect(frame(["/gems/a/lib/a.rb:1:in 'x'", "<internal:kernel>:1:in 'y'"])).to be_nil
  end

  it "does not treat a sibling that shares the root as a prefix as inside it" do
    sibling = "#{root}X"
    FileUtils.mkdir_p("#{sibling}/spec")
    File.write("#{sibling}/spec/a_spec.rb", "")
    begin
      expect(frame(["#{sibling}/spec/a_spec.rb:1:in 'block'"])).to be_nil
    ensure
      FileUtils.rm_rf(sibling)
    end
  end

  it "passes the backtick style through unchanged" do
    expect(frame(["#{root}/spec/login_spec.rb:7:in `block (2 levels) in <top (required)>'"]))
      .to eq("spec/login_spec.rb:7:in `block (2 levels) in <top (required)>'")
  end

  it "resolves relative paths against the root" do
    expect(frame(["spec/login_spec.rb:7:in 'block'"])).to eq("spec/login_spec.rb:7:in 'block'")
  end

  it "matches through a symlinked root" do
    link = "#{root}-link"
    File.symlink(root, link)
    begin
      expect(frame([page_line], root: link)).to eq(page_frame)
    ensure
      File.unlink(link)
    end
  end

  it "truncates results to 500 characters" do
    expect(frame(["#{root}/spec/login_spec.rb:1:in '#{"x" * 600}'"]).length).to eq(500)
  end

  describe ".relativize" do
    def relativize(backtrace, root: self.root) = described_class.relativize(backtrace, root: root)

    it "rewrites in-project lines relative to the root, keeping the suffix" do
      expect(relativize(["#{root}/spec/login_spec.rb:3:in 'x'"])).to eq(["spec/login_spec.rb:3:in 'x'"])
    end

    it "leaves gem, internal and vendor lines unchanged" do
      allow(Gem).to receive(:path).and_return(["#{root}/gemhome"])
      lines = ["#{root}/gemhome/gems/z.rb:3:in 'c'", "<internal:kernel>:187:in 'loop'",
               "#{root}/vendor/bundle/x.rb:1:in 'a'", "/gems/capybara-3/lib/node.rb:10:in 'find'"]
      expect(relativize(lines)).to eq(lines)
    end

    it "relativizes only the project lines of a mixed backtrace, in order" do
      lines = ["/gems/x/lib/x.rb:1:in 'a'", page_line, "<internal:kernel>:1:in 'b'"]
      expect(relativize(lines)).to eq(["/gems/x/lib/x.rb:1:in 'a'", page_frame, "<internal:kernel>:1:in 'b'"])
    end

    it "relativizes through a symlinked root" do
      link = "#{root}-link"
      File.symlink(root, link)
      begin
        expect(relativize(["#{root}/spec/login_spec.rb:5:in 'b'"], root: link)).to eq(["spec/login_spec.rb:5:in 'b'"])
      ensure
        File.delete(link)
      end
    end

    it "relativizes other lines when one line has invalid UTF-8" do
      bad = "/tmp/\xFF/bad.rb:1:in 'x'".dup.force_encoding("UTF-8")
      expect(relativize([bad, page_line])).to eq([bad, page_frame])
    end

    it "returns [] for nil or empty input and the input for a nil root" do
      expect(relativize(nil)).to eq([])
      expect(relativize([])).to eq([])
      expect(relativize([page_line], root: nil)).to eq([page_line])
    end
  end
end
