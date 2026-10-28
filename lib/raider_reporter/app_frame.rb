# frozen_string_literal: true

require "rbconfig"

module RaiderReporter
  # Finds the first project frame of a raw backtrace, so the server can group
  # failures by where the project's own code raised them.
  module AppFrame
    MAX_LENGTH = 500

    # Returns "relative/path.rb:42:in 'Class#method'" or nil when no line
    # of the backtrace lies in project code.
    def self.from(backtrace, root:)
      return nil if backtrace.nil? || backtrace.empty? || root.nil?

      base = "#{File.expand_path(root.to_s).chomp("/")}/"
      excluded = excluded_prefixes
      Array(backtrace).each do |line|
        line = line.to_s
        relative = relative_path(line, base, excluded)
        return Text.utf8("#{relative}#{line[line[/\A(.+?):\d+/, 1].length..]}")[0, MAX_LENGTH] if relative
      end
      nil
    end

    # Rewrites every backtrace line that lies in project code to
    # "relative/path.rb:42:in '...'"; all other lines are returned unchanged.
    def self.relativize(backtrace, root:)
      return [] if backtrace.nil? || backtrace.empty?
      return backtrace if root.nil?

      base = "#{File.expand_path(root.to_s).chomp("/")}/"
      excluded = excluded_prefixes
      Array(backtrace).map do |line|
        text = line.to_s
        relative = relative_path(text, base, excluded)
        relative ? "#{relative}#{text[text[/\A(.+?):\d+/, 1].length..]}" : line
      end
    end

    # The project-relative path of a backtrace line's file, or nil when the
    # line is not in project code.
    def self.relative_path(line, base, excluded)
      path = line[/\A(.+?):\d+/, 1]
      return nil if path.nil? || path.start_with?("<internal:", "(", "-")

      absolute = File.expand_path(path, base)
      return nil unless File.file?(absolute)

      absolute = inside_root(absolute, base)
      return nil unless absolute
      return nil if excluded.any? { |prefix| absolute.start_with?(prefix) }

      relative = absolute.delete_prefix(base)
      return nil if relative.start_with?("vendor/", ".bundle/") || relative.include?("/.bundle/")

      relative
    end
    private_class_method :relative_path

    # Returns the path (rewritten under base when only the real paths match,
    # e.g. a symlinked tmpdir) or nil when it lies outside the root.
    def self.inside_root(absolute, base)
      return absolute if absolute.start_with?(base)

      real_base = "#{File.realpath(base)}/"
      real = File.realpath(absolute)
      real.start_with?(real_base) ? "#{base}#{real.delete_prefix(real_base)}" : nil
    rescue SystemCallError
      nil
    end
    private_class_method :inside_root

    def self.excluded_prefixes
      dirs = Array(Gem.path) + [RbConfig::CONFIG["rubylibdir"]]
      dirs.compact.map(&:to_s).reject(&:empty?).map { |dir| "#{File.expand_path(dir).chomp("/")}/" }
    end
    private_class_method :excluded_prefixes
  end
end
