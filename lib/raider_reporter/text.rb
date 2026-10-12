# frozen_string_literal: true

module RaiderReporter
  # Text limits and cleaning shared by the framework formatters.
  module Text
    MAX_MESSAGE = 10_000
    MAX_BACKTRACE = 50

    # JSON generation raises on invalid UTF-8, which would lose the whole run.
    def self.utf8(value)
      str = value.to_s
      if [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(str.encoding)
        str.dup.force_encoding(Encoding::UTF_8).scrub("?")
      else
        str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
      end
    end
  end
end
