# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"

module RaiderReporter
  module Writers
    class Uploader
      Result = Data.define(:ok, :url, :error)

      def initialize(config, timeout: 30)
        @config = config
        @timeout = timeout
      end

      def upload(payload)
        uri = runs_uri
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{@config.token}"
        request["User-Agent"] = "raider_reporter/#{VERSION}"
        boundary = "----raider#{SecureRandom.hex(12)}"
        body = "".b
        add_field(body, boundary, "payload", JSON.generate(payload.to_h(mode: :upload)))
        payload.attachment_entries.each do |entry|
          add_file(body, boundary, entry[:part], entry[:attachment])
        end
        body << "--#{boundary}--\r\n".b
        request.body = body
        request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: @timeout, read_timeout: @timeout) do |http|
          http.request(request)
        end
        to_result(response)
      rescue StandardError => e
        Result.new(ok: false, url: nil, error: "#{e.class}: #{e.message}")
      end

      private

      def add_field(body, boundary, name, value)
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n".b
        body << value.to_s.b << "\r\n".b
      end

      def add_file(body, boundary, name, attachment)
        filename = File.basename(attachment.source_path).delete("\"\r\n")
        body << ("--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"; filename=\"#{filename}\"\r\n" \
                 "Content-Type: #{attachment.content_type}\r\n\r\n").b
        body << File.binread(attachment.source_path) << "\r\n".b
      end

      def runs_uri
        uri = URI.parse(@config.endpoint.to_s.strip.chomp("/") + "/api/v1/runs")
        raise ArgumentError, "RAIDER_ENDPOINT must start with http:// or https://" unless uri.is_a?(URI::HTTP)

        uri
      end

      def to_result(response)
        if response.is_a?(Net::HTTPSuccess)
          Result.new(ok: true, url: JSON.parse(response.body.to_s)["url"], error: nil)
        else
          Result.new(ok: false, url: nil, error: "HTTP #{response.code}: #{response.body.to_s[0, 200]}")
        end
      end
    end
  end
end
