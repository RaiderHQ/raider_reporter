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
        path = line[/\A(.+?):\d+/, 1]
        next if path.nil? || path.start_with?("<internal:")

        absolute = File.expand_path(path, base)
        next unless absolute.start_with?(base)
        next if excluded.any? { |prefix| absolute.start_with?(prefix) }

        relative = absolute.delete_prefix(base)
        next if relative.start_with?("vendor/", ".bundle/") || relative.include?("/.bundle/")

        return Text.utf8("#{relative}#{line[path.length..]}")[0, MAX_LENGTH]
      end
      nil
    end

    def self.excluded_prefixes
      dirs = Array(Gem.path) + [RbConfig::CONFIG["rubylibdir"]]
      dirs.compact.map(&:to_s).reject(&:empty?).map { |dir| "#{File.expand_path(dir).chomp("/")}/" }
    end
    private_class_method :excluded_prefixes
  end
end
