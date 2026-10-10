# raider_reporter

Raider-schema test reporting for RSpec. `raider_reporter` is an RSpec formatter that records every example's result, failure details, screenshots and videos, writes them to a local `run.json` (schema v1), and can optionally upload the run to a Raider server. It replaces Allure for Ruby Raider projects.

It has no runtime dependencies and requires Ruby 3.2 or newer.

## Install

```ruby
# Gemfile
gem "raider_reporter"
```

## Setup

Require the RSpec integration in `spec/spec_helper.rb`:

```ruby
require "raider_reporter/rspec"
```

Enable the formatter in `.rspec`:

```
--format progress
--format RaiderReporter::RSpec::Formatter
```

Run `bundle exec rspec` as usual. Results land in `raider-results/run.json`. A dry run (`rspec --dry-run`) writes and uploads nothing.

## Attaching screenshots and videos

Call `RaiderReporter.attach` while an example is running, for example from an `after` hook:

```ruby
RSpec.configure do |config|
  config.after do |example|
    next unless example.exception

    FileUtils.mkdir_p("tmp/screenshots")
    path = "tmp/screenshots/#{example.id.gsub(/\W/, '_')}.png"
    driver.save_screenshot(path)
    RaiderReporter.attach("screenshot", path, type: :png)
  end
end
```

`attach` copies the file right away, so the attachment keeps the bytes the file had at that moment even if the same path is overwritten by a later example. Using a path per example (as above) still makes the files on disk easier to find.

`attach` returns `true` on success. It returns `false` and prints a `[raider_reporter]` warning, never raising, if it is called outside a running example (for instance when the formatter is not loaded), if the file does not exist, or if the file is larger than 5 MB.

## Configuration

```ruby
RaiderReporter.configure do |c|
  c.output_dir = "raider-results"
  c.environment = { "browser" => "chrome", "suite" => "smoke" }
end
```

| Option | Default | Description |
| --- | --- | --- |
| `token` | `ENV["RAIDER_TOKEN"]` | API token used for uploads. |
| `endpoint` | `ENV["RAIDER_ENDPOINT"]` | Base URL of the Raider server to upload to. |
| `output_dir` | `"raider-results"` | Directory for local output. |
| `clean_output_dir` | `true` | Remove the previous `run.json` and `attachments/` directory inside `output_dir` before writing. Nothing else in `output_dir` is touched. |
| `environment` | `{}` | Free-form string key/values stored with the run (browser, suite name, and so on). |

## Local output

```
raider-results/
  run.json          # the run in schema v1
  attachments/      # copies of attached screenshots and videos
```

Add `raider-results/` to your `.gitignore`.

## Uploading to Raider

If both a token and an endpoint are set, the run (plus attachments) is uploaded when the suite finishes:

```
RAIDER_TOKEN=... RAIDER_ENDPOINT=https://your-raider-server bundle exec rspec
```

On success the formatter prints `Raider report: <url>`. If either value is missing, nothing is uploaded and the local files are still written.

An upload carries at most 45 MB of attachments and at most 1000 attachment files. Attachments past that budget are left out of the upload (in order, with one warning) but stay in the local `raider-results/`.

Reporting is fail-open: no error inside the gem, network failure, timeout or non-2xx response will raise or change RSpec's exit status. Each connect/write/read step of the upload times out after 30 seconds. Problems are printed as warnings prefixed with `[raider_reporter]`. An endpoint without `http://` or `https://` (for example `localhost:3000`) produces a warning and nothing is uploaded; a trailing slash is fine.

The hosted Raider service is not public yet; uploads go to a Raider server whose address you provide in `RAIDER_ENDPOINT`.

## Examples

- `examples/rspec_basic` is a runnable RSpec project with a passing, a failing (with an attachment) and a skipped example. Run it with `cd examples/rspec_basic && bundle install && bundle exec rspec`; the failure is deliberate.
- `examples/github_actions.yml` shows the workflow steps for CI.

## Schema

`run.json` follows schema v1, documented in [docs/schema-v1.md](docs/schema-v1.md). Statuses are exactly `passed`, `failed`, `pending` and `skipped`.

## Contributing

Bug reports and pull requests are welcome at https://github.com/RaiderHQ/raider_reporter. Run `bundle install && bundle exec rake` to run the specs.

## License

MIT. See [LICENSE](LICENSE).
