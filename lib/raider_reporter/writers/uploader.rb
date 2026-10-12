# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"

module RaiderReporter
  module Writers
    class Uploader
      Result = Data.define(:ok, :url, :run_id, :build_url, :error)
      # Keeps uploads under the server's 50 MB request limit and multipart part limit.
      MAX_UPLOAD_ATTACHMENT_BYTES = 45 * 1024 * 1024
      MAX_UPLOAD_ATTACHMENTS = 1000
      ERROR_DETAIL_LIMIT = 200

      def initialize(config, timeout: 30, warn: RaiderReporter.method(:warn))
        @config = config
        @timeout = timeout
        @warn = warn
      end

      def upload(payload)
        uri = runs_uri
        payload = within_budget(payload)
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
                                                       open_timeout: @timeout, read_timeout: @timeout,
                                                       write_timeout: @timeout) do |http|
          http.request(request)
        end
        to_result(response)
      rescue StandardError => e
        Result.new(ok: false, url: nil, run_id: nil, build_url: nil, error: redact("#{e.class}: #{e.message}"))
      end

      private

      # Keeps the leading attachments that fit the byte and count budget and
      # rebuilds the payload without the rest, so part names stay contiguous.
      # The local run.json is written from the original payload and keeps all.
      def within_budget(payload)
        entries = payload.attachment_entries
        bytes = 0
        keep = entries.index do |entry|
          bytes += File.size?(entry[:attachment].source_path).to_i
          bytes > MAX_UPLOAD_ATTACHMENT_BYTES
        end || entries.size
        keep = [keep, MAX_UPLOAD_ATTACHMENTS].min
        return payload if keep == entries.size

        dropped = entries.size - keep
        @warn.call("not uploading #{dropped} #{dropped == 1 ? 'attachment' : 'attachments'}: over the upload " \
                   "budget of #{MAX_UPLOAD_ATTACHMENT_BYTES / (1024 * 1024)} MB / " \
                   "#{MAX_UPLOAD_ATTACHMENTS} files; they remain in #{@config.output_dir}")
        seen = 0
        run = payload.run
        Payload.new(run.with(results: run.results.map do |result|
          result.with(attachments: result.attachments.select { (seen += 1) <= keep })
        end))
      end

      def add_field(body, boundary, name, value)
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n".b
        body << value.to_s.b << "\r\n".b
      end

      def add_file(body, boundary, name, attachment)
        filename = File.basename(attachment.source_path).gsub(/[^\w.\-]/, "_")
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
          body = parse_body(response.body)
          build = body["build"].is_a?(Hash) ? body["build"] : {}
          Result.new(ok: true, url: present(body["url"]), run_id: present(body["run_id"]),
                     build_url: present(build["url"]), error: nil)
        else
          Result.new(ok: false, url: nil, run_id: nil, build_url: nil, error: error_message(response))
        end
      end

      # One short line: an HTML error page (e.g. a Rails 500) is summarised, anything
      # else is collapsed to one line, redacted, then cut to ERROR_DETAIL_LIMIT.
      def error_message(response)
        text = response.body.to_s
        detail = if html?(response, text)
                   "the server returned an HTML error page"
                 else
                   redact(text).gsub(/\s+/, " ").strip[0, ERROR_DETAIL_LIMIT]
                 end
        detail.empty? ? "HTTP #{response.code}" : "HTTP #{response.code}: #{detail}"
      end

      def html?(response, text)
        response["Content-Type"].to_s.include?("html") || text.lstrip.start_with?("<")
      end

      def redact(text)
        token = @config.token.to_s
        token.empty? ? text.to_s : text.to_s.gsub(token, "[REDACTED]")
      end

      def parse_body(text)
        parsed = JSON.parse(text.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      def present(value)
        value.nil? || value.to_s.strip.empty? ? nil : value
      end
    end
  end
end
