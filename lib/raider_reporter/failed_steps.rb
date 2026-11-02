# frozen_string_literal: true

require "digest"
require "json"
require "raider_reporter/text"

module RaiderReporter
  # Names the recorded step a failed test broke at, from the Raider desktop's sidecar
  # (.raider/tests/<spec>.json) and its stepLines map. Gives nothing unless the map was made
  # for the spec file's exact bytes, so it never points at the wrong step.
  class FailedSteps
    MAX_SIDECAR_BYTES = 1_048_576
    MAX_ITEMS = 200
    MAX_TITLE = 500
    FRAME = /\A(.+?):(\d+)(?::|\z)/
    OPEN_FLAGS = File::RDONLY | (defined?(File::NOFOLLOW) ? File::NOFOLLOW : 0)

    # A sidecar or map that is there but can't be used; warned about once per run.
    class Unusable < StandardError; end

    # Returns the run with `steps` set on each failed result whose sidecar map is current.
    def self.apply(run, root:, warn:)
      finder = new(root: root, warn: warn)
      run.with(results: run.results.map { |result| result.with(steps: finder.steps_for(result)) })
    end

    def initialize(root:, warn:)
      @root = File.expand_path(root.to_s)
      @warn = warn
      @warned = false
    end

    # {"items" => [{"id", "title"}], "failed" => index or nil}, or nil when the result gets no steps.
    def steps_for(result)
      return nil unless result.status == "failed" && result.failure

      file = result.file_path.to_s.delete_prefix("./")
      return nil unless safe_relative?(file)

      sidecar = read_sidecar(file)
      ranges = sidecar && current_ranges(sidecar, file)
      ranges && build(ranges, failing_line(result.failure, file))
    rescue StandardError => e
      warn_once(file, e)
      nil
    end

    private

    # A relative POSIX path with no empty, "." or ".." segments (the desktop's isSafeRelPath).
    def safe_relative?(file)
      return false if file.empty? || file.include?("\\") || file.include?("\0") || file.start_with?("/")
      return false if file.match?(/\A[A-Za-z]:/)

      file.split("/", -1).none? { |part| part.empty? || part == "." || part == ".." }
    end

    # The parsed sidecar, or nil when there is none or it is for another file. Only this one
    # path under .raider/ is ever read (.raider/auth/ holds live session tokens).
    def read_sidecar(file)
      parts = [".raider", "tests", *file.split("/")]
      parts[-1] = "#{parts[-1]}.json"
      path = @root
      parts.each do |part|
        path = File.join(path, part)
        stat = File.lstat(path)
        raise Unusable, "#{path} is a symlink" if stat.symlink?
      end
      raise Unusable, "#{path} is not a regular file" unless File.lstat(path).file?

      sidecar = JSON.parse(read_capped(path))
      raise Unusable, "the sidecar is not a JSON object" unless sidecar.is_a?(Hash)

      sidecar["file"] == file ? sidecar : nil
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def read_capped(path)
      File.open(path, OPEN_FLAGS) do |io|
        raise Unusable, "#{path} is larger than #{MAX_SIDECAR_BYTES} bytes" if io.size > MAX_SIDECAR_BYTES

        io.read(MAX_SIDECAR_BYTES + 1).to_s.force_encoding(Encoding::UTF_8)
      end
    end

    # The map's ranges while it is current and every range has a title; nil otherwise.
    def current_ranges(sidecar, file)
      map = sidecar["stepLines"]
      return nil if map.nil?

      ranges = valid_ranges(map)
      return nil if ranges.empty? || !ranges.all? { |range| range["title"].is_a?(String) }
      return nil unless spec_sha256(file) == map["fileSha256"]

      ranges
    end

    def valid_ranges(map)
      ranges = map.is_a?(Hash) ? map["ranges"] : nil
      raise Unusable, "stepLines is malformed" unless ranges.is_a?(Array) && map["fileSha256"].is_a?(String)

      ranges.each do |range|
        raise Unusable, "a stepLines range is malformed" unless valid_range?(range)
      end
      ranges
    end

    def valid_range?(range)
      return false unless range.is_a?(Hash)

      id = range["stepId"]
      first = range["start"]
      last = range["end"]
      id.is_a?(String) && !id.empty? && first.is_a?(Integer) && last.is_a?(Integer) && first >= 1 && last >= first
    end

    def spec_sha256(file)
      path = File.join(@root, file)
      File.file?(path) ? Digest::SHA256.file(path).hexdigest : nil
    end

    # The line of the first stored backtrace frame in the spec file, else of app_frame when it
    # is in the spec file. Helper frames before it are skipped.
    def failing_line(failure, file)
      [*Array(failure.backtrace), failure.app_frame].compact.each do |frame|
        match = FRAME.match(frame.to_s)
        return match[2].to_i if match && match[1].delete_prefix("./") == file
      end
      nil
    end

    # One item per step in file order. `failed` is always present: null means the failure was
    # outside every step (Hideout drops a steps object without the key).
    def build(ranges, line)
      ordered = ranges.sort_by { |range| range["start"] }.uniq { |range| range["stepId"] }
      return nil if ordered.size > MAX_ITEMS

      hit = line && ranges.find { |range| line.between?(range["start"], range["end"]) }
      {
        "items" => ordered.map { |range| { "id" => Text.utf8(range["stepId"]), "title" => title(range) } },
        "failed" => hit && ordered.index { |range| range["stepId"] == hit["stepId"] }
      }
    end

    def title(range)
      Text.utf8(range["title"])[0, MAX_TITLE]
    end

    def warn_once(file, error)
      return if @warned

      @warned = true
      @warn.call("could not read the recorded steps for #{file}: #{error.message}; sent without steps")
    end
  end
end
