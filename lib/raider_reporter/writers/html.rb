# frozen_string_literal: true

require "erb"
require "fileutils"
require "json"
require "time"

module RaiderReporter
  module Writers
    # Builds index.html from every run*.json in a results folder: one page with inline
    # CSS and JS and no network requests, so a run can be read without Raider or Java.
    class Html
      class ForeignFile < StandardError; end

      FILE = "index.html"
      MARKER = '<meta name="generator" content="raider_reporter">'
      ROW_LIMIT = 2_000
      RUN_FILE = /\Arun(-[^\/]+)?\.json\z/
      SECTIONS = [%w[failed Failed], %w[passed Passed], %w[pending Pending], %w[skipped Skipped]].freeze
      PROVIDERS = { "github_actions" => "GitHub Actions", "azure_pipelines" => "Azure Pipelines" }.freeze

      def self.ours?(path)
        File.file?(path) && File.read(path, 4096).to_s.include?(MARKER)
      end

      def write(dir)
        dir = File.expand_path(dir)
        files = run_files(dir)
        return nil if files.empty?

        target = File.join(dir, FILE)
        if File.exist?(target) && !self.class.ours?(target)
          raise ForeignFile, "#{target} exists and was not written by raider_reporter; not overwritten"
        end

        runs, skipped = load(files)
        tmp = "#{target}.tmp-#{Process.pid}"
        File.write(tmp, render(runs, skipped, project_name(dir)))
        File.rename(tmp, target)
        target
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      private

      def run_files(dir)
        return [] unless File.directory?(dir)

        Dir.children(dir).grep(RUN_FILE).sort.map { |name| File.join(dir, name) }
      end

      def load(files)
        runs = []
        skipped = []
        files.each do |file|
          data = JSON.parse(File.read(file))
          raise TypeError unless data.is_a?(Hash) && data["results"].is_a?(Array)

          runs << data
        rescue StandardError
          skipped << File.basename(file)
        end
        [runs, skipped]
      end

      def project_name(dir)
        name = File.basename(File.dirname(dir))
        name.empty? || name == "/" ? "Raider run" : name
      end

      def render(runs, skipped, project)
        results = runs.flat_map { |run| run["results"] }.select { |r| r.is_a?(Hash) }
        meta = runs.map { |run| run["run"].is_a?(Hash) ? run["run"] : {} }
        counts = SECTIONS.to_h { |status, _| [status, results.count { |r| r["status"] == status }] }

        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          #{MARKER}
          <title>#{h(project)} · Raider report</title>
          <style>#{CSS}</style>
          </head>
          <body>
          <header>
          <h1>#{h(project)}</h1>
          <p class="totals">#{totals(counts)}</p>
          <p class="meta">#{meta_line(meta)}</p>
          </header>
          <main>
          #{results.empty? ? '<p class="empty">No results</p>' : filter_box}
          #{SECTIONS.map { |status, label| section(status, label, results) }.join}
          </main>
          <footer>#{footer(skipped)}</footer>
          <script>#{JS}</script>
          </body>
          </html>
        HTML
      end

      def totals(counts)
        passed = counts["passed"]
        decided = passed + counts["failed"]
        rate = decided.zero? ? "—" : "#{(passed * 100.0 / decided).round}%"
        parts = SECTIONS.map { |status, _| %(<span class="b #{status}">#{counts[status]} #{status}</span>) }
        "#{parts.join(' ')} <span class=\"rate\">Pass rate #{rate}</span>"
      end

      def meta_line(meta)
        parts = []
        duration = run_duration(meta)
        parts << "Duration #{h(duration)}" if duration
        git = meta.map { |m| m["git"] }.find { |g| g.is_a?(Hash) } || {}
        parts << "Branch #{h(git['branch'])}" if git["branch"]
        parts << "Commit #{h(git['commit_sha'].to_s[0, 7])}" if git["commit_sha"]
        ci = meta.map { |m| m["ci"] }.find { |c| c.is_a?(Hash) } || {}
        parts << ci_link(ci) if ci["provider"]
        parts << "Generated #{h(Time.now.utc.strftime('%Y-%m-%d %H:%M UTC'))}"
        parts.join(" · ")
      end

      def ci_link(ci)
        label = h(PROVIDERS.fetch(ci["provider"], ci["provider"]))
        url = ci["build_url"].to_s
        url.match?(%r{\Ahttps?://}) ? %(<a href="#{h(url)}">#{label}</a>) : label
      end

      def run_duration(meta)
        starts = meta.filter_map { |m| time(m["started_at"]) }
        ends = meta.filter_map { |m| time(m["finished_at"]) }
        return nil if starts.empty? || ends.empty? || ends.max < starts.min

        format_ms(((ends.max - starts.min) * 1000).round)
      end

      def time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def filter_box
        '<input id="q" type="search" placeholder="Filter by test name or file" aria-label="Filter tests">'
      end

      def section(status, label, results)
        rows = results.select { |r| r["status"] == status }
        return "" if rows.empty?

        shown = rows.first(ROW_LIMIT).map { |r| row(r) }.join
        more = rows.size > ROW_LIMIT ? %(<p class="more">#{rows.size - ROW_LIMIT} more not shown</p>) : ""
        open = status == "failed" ? " open" : ""
        %(<details class="s"#{open}><summary>#{label} (#{rows.size})</summary>#{shown}#{more}</details>\n)
      end

      def row(result)
        key = "#{result['full_name']} #{result['file_path']}".downcase
        location = [result["file_path"], result["line_number"]].compact.join(":")
        attempts = result["attempts"].to_i > 1 ? %( <span class="att">#{result['attempts'].to_i} attempts</span>) : ""
        <<~ROW
          <div class="r #{h(result['status'])}" data-k="#{h(key)}">
          <p class="n"><span class="b #{h(result['status'])}">#{h(result['status'])}</span> #{h(result['full_name'])}</p>
          <p class="l">#{h(location)} · #{h(format_ms(result['duration_ms'].to_i))}#{attempts}</p>
          #{failure(result['failure'])}#{attachments(result['attachments'])}
          </div>
        ROW
      end

      def failure(failure)
        return "" unless failure.is_a?(Hash)

        trace = Array(failure["backtrace"]).join("\n")
        backtrace = trace.empty? ? "" : "<details><summary>Backtrace</summary><pre>#{h(trace)}</pre></details>"
        %(<p class="x">#{h(failure['exception_class'])}</p><pre>#{h(failure['message'])}</pre>#{backtrace})
      end

      def attachments(list)
        items = Array(list).filter_map do |attachment|
          next unless attachment.is_a?(Hash)

          href = safe_href(attachment["path"])
          next unless href

          if attachment["content_type"].to_s.start_with?("image/")
            %(<a href="#{href}"><img loading="lazy" src="#{href}" alt="#{h(attachment['name'])}"></a>)
          else
            %(<a href="#{href}">#{h(attachment['name'])}</a>)
          end
        end
        items.empty? ? "" : %(<div class="a">#{items.join(' ')}</div>)
      end

      # Relative paths inside the results folder only, each segment URL-encoded.
      def safe_href(path)
        path = path.to_s
        segments = path.split("/")
        return nil if path.empty? || path.start_with?("/") || segments.include?("..") || path.include?("\\")

        segments.map { |segment| ERB::Util.url_encode(segment) }.join("/")
      end

      def footer(skipped)
        note = skipped.empty? ? "" : "Skipped unreadable run files: #{h(skipped.join(', '))} · "
        "#{note}Generated by raider_reporter #{h(RaiderReporter::VERSION)}"
      end

      def format_ms(ms)
        return "#{ms}ms" if ms < 1000

        seconds = ms / 1000
        return format("%.1fs", ms / 1000.0) if seconds < 60

        "#{seconds / 60}m #{seconds % 60}s"
      end

      def h(value) = ERB::Util.html_escape(value.to_s)

      CSS = <<~CSS.gsub(/\s*\n\s*/, "")
        :root{--bg:#fff;--fg:#1f2328;--mute:#656d76;--bdr:#d0d7de;--card:#f6f8fa;--ruby:#C14420;--ok:#1a7f37;--warn:#9a6700}
        @media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--mute:#8d96a0;--bdr:#30363d;--card:#161b22;--ok:#3fb950;--warn:#d29922}}
        *{box-sizing:border-box}
        body{margin:0;padding:16px;background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
        header,main,footer{max-width:1100px;margin:0 auto}
        h1{margin:0 0 4px;font-size:20px;color:var(--ruby)}
        .meta,.l,footer,.more{color:var(--mute);font-size:12px}
        .b{display:inline-block;padding:0 6px;border-radius:9px;font-size:11px;font-weight:600;border:1px solid var(--bdr)}
        .b.failed{background:var(--ruby);color:#fff;border-color:var(--ruby)}
        .b.passed{color:var(--ok)}.b.pending,.b.skipped{color:var(--warn)}
        .rate{font-weight:600;margin-left:6px}
        #q{width:100%;margin:12px 0;padding:8px;border:1px solid var(--bdr);border-radius:6px;background:var(--card);color:var(--fg)}
        details.s{margin:8px 0;border:1px solid var(--bdr);border-radius:8px}
        details.s>summary{padding:8px 12px;font-weight:600;cursor:pointer}
        .r{padding:8px 12px;border-top:1px solid var(--bdr)}
        .r p{margin:2px 0;overflow-wrap:anywhere}.n{font-weight:500}.x{color:var(--ruby);font-weight:600}
        pre{margin:4px 0;padding:8px;background:var(--card);border-radius:6px;overflow-x:auto;white-space:pre-wrap;font-size:12px}
        .a img{max-width:100%;max-height:240px;border:1px solid var(--bdr);border-radius:4px;margin-top:4px}
        a{color:var(--ruby)}.empty{padding:24px 0;color:var(--mute)}
      CSS

      JS = <<~JS.gsub(/\s*\n\s*/, "")
        (function(){var q=document.getElementById("q");if(!q)return;
        q.addEventListener("input",function(){var v=q.value.toLowerCase();
        document.querySelectorAll(".r").forEach(function(r){r.hidden=v!==""&&r.dataset.k.indexOf(v)<0;});});})();
      JS
    end
  end
end
