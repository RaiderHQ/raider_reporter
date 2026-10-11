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
  c.environment = { "browser" => "chrome", "suite" => "smoke", "headless" => true }
end
```

| Option | Default | Description |
| --- | --- | --- |
| `token` | `ENV["RAIDER_TOKEN"]` | API token used for uploads. |
| `endpoint` | `ENV["RAIDER_ENDPOINT"]` | Base URL of the Raider server to upload to. |
| `output_dir` | `"raider-results"` | Directory for local output. |
| `clean_output_dir` | `true` | Remove the previous `run.json` and `attachments/` directory (`run-<n>.json` and `attachments-<n>/` when sharded) inside `output_dir` before writing. Nothing else in `output_dir` is touched. |
| `environment` | `{}` | Free-form key/values stored with the run (browser, suite name, and so on). Values are JSON values: strings, booleans or numbers. |

## Local output

```
raider-results/
  run.json          # the run in schema v1
  attachments/      # copies of attached screenshots and videos
```

Add `raider-results/` to your `.gitignore`. When a run is sharded, the files are named per shard; see [Parallel runs](#parallel-runs).

## Uploading to Raider

If both a token and an endpoint are set, the run (plus attachments) is uploaded when the suite finishes:

```
RAIDER_TOKEN=... RAIDER_ENDPOINT=https://your-raider-server bundle exec rspec
```

On success the formatter prints `Raider report: <url>`, using the build URL when the server returns one and the run URL otherwise (or `Raider report uploaded (run <id>)` if the response has no URL). If either value is missing, nothing is uploaded and the local files are still written.

An upload carries at most 45 MB of attachments and at most 1000 attachment files. Attachments past that budget are left out of the upload (in order, with one warning) but stay in the local `raider-results/`.

Reporting is fail-open: no error inside the gem, network failure, timeout or non-2xx response will raise or change RSpec's exit status. Each connect/write/read step of the upload times out after 30 seconds. Problems are printed as warnings prefixed with `[raider_reporter]`. An endpoint without `http://` or `https://` (for example `localhost:3000`) produces a warning and nothing is uploaded; a trailing slash is fine.

The hosted Raider service is not public yet; uploads go to a Raider server whose address you provide in `RAIDER_ENDPOINT`.

## Parallel runs

When a suite is split across several processes or CI jobs, each one uploads its own run. Raider groups runs of the same CI build, so the shards show up together as one build. Each run records its shard (`index`, `total` and a `label`) and, on GitHub Actions, a build key made from the repository, run id and run attempt. A re-run attempt of a workflow is a separate build.

Shard detection, in order of precedence:

1. `RAIDER_SHARD_INDEX` (1 or more) and, optionally, `RAIDER_SHARD_TOTAL`.
2. `parallel_tests` / `parallel_rspec`: `TEST_ENV_NUMBER` (empty means shard 1) and `PARALLEL_TEST_GROUPS` for the total.
3. Otherwise the run is not sharded.

A GitHub Actions matrix needs only the two variables:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        shard: [1, 2, 3, 4]
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - run: bundle exec rspec  # split the spec files by shard however you like
        env:
          RAIDER_TOKEN: ${{ secrets.RAIDER_TOKEN }}
          RAIDER_ENDPOINT: ${{ vars.RAIDER_ENDPOINT }}
          RAIDER_SHARD_INDEX: ${{ matrix.shard }}
          RAIDER_SHARD_TOTAL: 4
```

`parallel_rspec` works with no configuration, because it sets `TEST_ENV_NUMBER` and `PARALLEL_TEST_GROUPS` for each process.

When a run is sharded, local output is written per shard so that processes sharing one `raider-results/` do not overwrite each other. Cleaning only removes the current shard's own files:

```
raider-results/
  run-1.json
  attachments-1/
  run-2.json
  attachments-2/
```

Unsharded runs still write `run.json` and `attachments/`. Tools that read local results should load `run*.json`.

### Matrix and parallel_tests together

A GitHub matrix leg can also run `parallel_rspec -n 2`. When `RAIDER_SHARD_INDEX` and `TEST_ENV_NUMBER` are both present and `PARALLEL_TEST_GROUPS` is a positive integer `g`, the two are composed so every process gets a unique shard:

- `index = (RAIDER_SHARD_INDEX - 1) * g + parallel_index`
- `total = RAIDER_SHARD_TOTAL * g`
- `label = "<job>#<RAIDER_SHARD_INDEX>.<parallel_index>"`

For example, matrix leg 2 of 2 with `parallel_rspec -n 2` yields shards 3 and 4 of 4, labelled `#2.1` and `#2.2`. `RAIDER_SHARD_TOTAL` must match the matrix size. Without it, `total` is null. If `PARALLEL_TEST_GROUPS` is missing or invalid, only `RAIDER_SHARD_INDEX` is used.

Tip: run `rm -rf raider-results` before a parallel run. Each process only cleans its own files, so files from an earlier run with more processes stay behind.

## Examples

- `examples/rspec_basic` is a runnable RSpec project with a passing, a failing (with an attachment) and a skipped example. Run it with `cd examples/rspec_basic && bundle install && bundle exec rspec`; the failure is deliberate.
- `examples/github_actions.yml` shows the workflow steps for CI.

## Schema

`run.json` follows schema v1, documented in [docs/schema-v1.md](docs/schema-v1.md). Statuses are exactly `passed`, `failed`, `pending` and `skipped`.

## Contributing

Bug reports and pull requests are welcome at https://github.com/RaiderHQ/raider_reporter. Run `bundle install && bundle exec rake` to run the specs.

## License

MIT. See [LICENSE](LICENSE).
