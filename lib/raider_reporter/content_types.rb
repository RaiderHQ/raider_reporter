# frozen_string_literal: true

module RaiderReporter
  module ContentTypes
    BY_EXTENSION = {
      ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif",
      ".webp" => "image/webp", ".mp4" => "video/mp4", ".webm" => "video/webm", ".mov" => "video/quicktime",
      ".txt" => "text/plain", ".log" => "text/plain", ".html" => "text/html", ".json" => "application/json"
    }.freeze
    BY_SYMBOL = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", mp4: "video/mp4",
                  webm: "video/webm", text: "text/plain", html: "text/html", json: "application/json" }.freeze

    MIME = %r{\A[\w.+-]+/[\w.+-]+\z}

    module_function

    def resolve(type, path)
      if type.is_a?(String)
        return type if type.match?(MIME)

        type = nil
      end
      return BY_SYMBOL.fetch(type) if BY_SYMBOL.key?(type)

      from_ext = BY_EXTENSION[File.extname(path.to_s).downcase]
      return from_ext if from_ext && (type.nil? || from_ext.start_with?("#{type}/"))
      return "video/mp4" if type == :video
      return "image/png" if type == :image

      "application/octet-stream"
    end
  end
end
