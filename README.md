# raider_reporter

Raider-schema test reporting for RSpec and Cucumber. `raider_reporter` is an RSpec formatter and a Cucumber reporter that records every example's result, failure details, screenshots and videos, writes them to a local `run.json` (schema v1, or v2 when a run has a quarantined result), and can optionally upload the run to a Raider server. It replaces Allure for Ruby Raider projects.

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

Run `bundle exec rspec` as usual. (For Cucumber, see [Cucumber](#cucumber).) Results land in `raider-results/run.json`. A dry run (`rspec --dry-run`) writes and uploads nothing.

## Cucumber

Requirements: Cucumber 9, 10, 11 or 12 (12 needs Ruby 3.3+) in your own Gemfile (`gem "cucumber"`). It is not a dependency of this gem; requiring `raider_reporter/cucumber` without Cucumber raises a `LoadError` that says so. Cucumber 9.2.1 on Ruby 4 also needs `gem "logger"` in your Gemfile, because Cucumber requires it without declaring it.

### Plugin mode (recommended)

Require the reporter from a file under `features/support/`, for example `features/support/raider.rb`:

```ruby
require "raider_reporter/cucumber"
```

Then run Cucumber with any normal formatter and no `--out`:

```
# cucumber.yml
default: --format pretty
```

The require registers one listener on Cucumber's event bus, so it sits next to `pretty`, `progress` or any other formatter. Results land in `raider-results/run.json`, and a dry run (`cucumber --dry-run`) writes and uploads nothing. Plugin mode registers once per Ruby process, because `require` is cached: a second in-process `Cucumber::Cli::Main` run in the same process does not register again.

### Formatter mode

You can also name the formatter explicitly:

```
cucumber --format pretty --format RaiderReporter::Cucumber::Formatter --out raider-results/cucumber.log
```

`--out` is required here. Cucumber rejects a second formatter on the same output stream ("All but one formatter must use --out", also in 9.2.1), and this formatter writes nothing to its stream, so give it any file path (it is never created). If both modes are active, only one listener is registered.

### How tests are identified

- `file_path` is relative to the project root (`features/login.feature`), even when Cucumber is given `./features/login.feature` or an absolute path.
- `full_name` is `"<Feature name>: <Scenario name>"`. Scenario Outline rows are `"<Feature name>: <Scenario name> (<Examples name or 'Examples'>, row <n>)"`, where `n` is the 1-based data row of that Examples table. When two or more Examples tables of one outline share a label (for example two unnamed ones), every table with that label is numbered by its position among them, `(Examples 1, row 1)`, `(Examples 2, row 1)`, so each row keeps a distinct name; tables with a unique label are unchanged.
- `identifier` is `"<file_path>:<line>"`: the scenario line, or the Examples row line for outline rows.
- `tags` are the feature, scenario and Examples tags, merged, sorted, unique, without `@`.

Statuses: passed, failed and ambiguous (reported as failed), pending and undefined (reported as pending), skipped. Failed (and ambiguous) scenarios on the quarantine list are reported as quarantined.

### Failures

A failed test reports the step that failed, not the whole scenario:

```
When I fail on purpose (features/login.feature:9)

expected 5, got 4
```

A failing `Before` or `After` hook is named `Before hook` or `After hook` in place of the step, so an `After` hook that raises after every step passed is still a failed test. Messages are capped at 10,000 characters and backtraces at 50 lines.

### Retries

With `--retry n`, only the final attempt of each scenario is reported, and `attempts` is the number of attempts. Each attempt starts with fresh attachments; attachments from earlier attempts are dropped.

### Attachments

Both of these are captured while a scenario runs:

```ruby
After do |scenario|
  attach(path, "image/png") if scenario.failed?        # Cucumber's own attach, with an existing file path (a Pathname works too)
  RaiderReporter.attach("screenshot", path, type: :png) # or the Raider helper, as in RSpec
end
```

Cucumber's `attach` is captured only when given the path of an existing file. Inline data (`attach("some text", "text/plain")`) and `log` messages are ignored.

### Parallel runs with Cucumber

`parallel_tests` works with no configuration for Cucumber too: each process writes `run-<n>.json`. See [Parallel runs](#parallel-runs).

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

`attach` returns `true` on success. It returns `false` and prints a `[raider_reporter]` warning, never raising, if it is called outside a running example (for instance when the formatter is not loaded), if the file does not exist, or if the file is larger than its size cap: 5 MB (`max_attachment_bytes`), or 50 MB for videos (`video/*`, `max_video_bytes`).

Videos (`.webm`, `.mp4`) are attached the same way, for example `RaiderReporter.attach("video", path, type: :webm)`. In the local HTML report they play inline, with a download link.

When a run is uploaded, screenshots and other non-video attachments are sent first; videos then fill the room left in the upload budget. A video that does not fit is skipped and later, smaller videos are still tried. The local `raider-results/attachments/` folder keeps every attachment that passed its size cap.

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
| `clean_output_dir` | `true` | Remove the previous `run.json` and `attachments/` directory (`run-<n>.json` and `attachments-<n>/` when sharded) inside `output_dir` before writing. Nothing else in `output_dir` is touched, except a raider_reporter-written `index.html`. |
| `html_report` | `true` | Write `index.html`, the local HTML report, into `output_dir` after each run. See [Local report](#local-report). |
| `quarantine` | `true` when `ENV["RAIDER_QUARANTINE"]` is `1` or `true` | Fetch the quarantine list at run start and report matching failures as `quarantined`. Needs `token` and `endpoint`. See [Quarantine](#quarantine). |
| `max_attachment_bytes` | `5 MB` | Largest non-video attachment `attach` accepts. |
| `max_video_bytes` | `50 MB` | Largest `video/*` attachment `attach` accepts. |
| `exec_summary_path` | `ENV["RAIDER_EXEC_SUMMARY"]` | File where the run writes its failure counts (framework failures, quarantined, errors outside tests) for `raider-reporter exec` to read when it decides the exit code. `exec` sets it for the command it runs; leave it unset otherwise. Nothing is written when it is unset. See [Quarantine](#quarantine). |
| `environment` | `{}` | Free-form key/values stored with the run (browser, suite name, and so on). Values are JSON values: strings, booleans or numbers. |

## Local output

```
raider-results/
  run.json          # the run in schema v1 (v2 with quarantined results)
  attachments/      # copies of attached screenshots and videos
  index.html        # the local report, see below
```

Add `raider-results/` to your `.gitignore`. When a run is sharded, the files are named per shard; see [Parallel runs](#parallel-runs).

## Local report

Every run also writes `raider-results/index.html`: one self-contained page (inline CSS and JS, no network requests, so it works offline) built from every `run*.json` in the folder. It shows totals and pass rate, then failures first with message, exception class, backtrace and screenshots, followed by the other statuses; a filter box narrows by test name or file. Open it in a browser or publish it as a CI artifact.

Rebuild it from the run files on disk, for example after `parallel_rspec` has written one file per shard:

```
raider-reporter report [dir]   # default: raider-results; prints the path, exits 1 when there are no run files or the report cannot be written
```

Set `config.html_report = false` to turn it off. An `index.html` that raider_reporter did not write is never overwritten or removed; a warning is printed instead.

## Uploading to Raider

If both a token and an endpoint are set, the run (plus attachments) is uploaded when the suite finishes:

```
RAIDER_TOKEN=... RAIDER_ENDPOINT=https://your-raider-server bundle exec rspec
```

On success the formatter prints `Raider report: <url>` to stderr (so tools that parse RSpec's stdout, such as `--format json`, stay clean), using the build URL when the server returns one and the run URL otherwise (or `Raider report uploaded (run <id>)` if the response has no URL). If either value is missing, nothing is uploaded and the local files are still written.

An upload carries at most 45 MB of attachments and at most 1000 attachment files. Attachments past that budget are left out of the upload (in order, with one warning) but stay in the local `raider-results/`.

Reporting is fail-open: no error inside the gem, network failure, timeout or non-2xx response will raise or change RSpec's exit status. Each connect/write/read step of the upload times out after 30 seconds. Problems are printed as warnings prefixed with `[raider_reporter]`. An endpoint without `http://` or `https://` (for example `localhost:3000`) produces a warning and nothing is uploaded; a trailing slash is fine.

The hosted Raider service is not public yet; uploads go to a Raider server whose address you provide in `RAIDER_ENDPOINT`.

## Quarantine

A test quarantined in Raider (with a reason and an expiry) still runs and is still reported, but its failure is reported as `quarantined`, and a CI build stays green when quarantined tests are its only failures.

1. Turn it on in CI with `RAIDER_QUARANTINE=1` (or `config.quarantine = true`), next to `RAIDER_TOKEN` and `RAIDER_ENDPOINT`.
2. Run the suite through `raider-reporter exec`:

   ```
   bundle exec raider-reporter exec -- bundle exec rspec
   bundle exec raider-reporter exec -- bundle exec cucumber
   ```

When the run starts, the formatter fetches the project's quarantine list once (`GET /api/v1/quarantine`, 3-second timeout). On any error it prints `[raider_reporter] quarantine list unavailable (<reason>); no tests quarantined` and nothing is quarantined. Matching failures keep their message, backtrace and screenshots; the run is written as schema 2, and `run.json`, the upload and the HTML report show `quarantined`.

`exec` runs the command without a shell and exits with its status, with one exception: when the command exits 1, every failure the framework counted is quarantined, and nothing went wrong outside tests, it prints `raider-reporter: N quarantined failure(s) did not fail the build` to stderr and exits 0. "Outside tests" means RSpec errors outside examples, a run stopped early (`--fail-fast`, an interrupt, a load error), or a Cucumber run that did not finish every scenario. RSpec `--fail-fast` counts even when the last example triggers it, and interrupts count too, so the build stays red. Under Cucumber `--strict`, a flaky scenario (failed, then passed on retry) counts as a real failure and keeps the build red. A command killed by a signal exits 128 + the signal number; a command that cannot be started exits 127. Several processes under one `exec` (for example `parallel_rspec`) never turn red into green: their summaries conflict and the command's exit code is used.

Without `exec`, RSpec and Cucumber exit codes are unchanged; quarantine only changes how failures are reported.

## Pull request comments

On pull requests, `raider-reporter comment` posts one comment with the build's results (and sets a `raider/tests` commit status on the PR head commit). Run it in a job that runs after your test jobs, so every shard has uploaded. Use the workflow's `GITHUB_TOKEN` (or a GitHub App token): a personal access token posts as a user, so the step adds a new comment on every run instead of updating the existing one.

```yaml
  raider-comment:
    needs: [test]   # every test job id
    if: always() && github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      statuses: write
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: "3.4", bundler-cache: true }
      - name: Comment Raider results on the pull request
        run: bundle exec raider-reporter comment
        env:
          RAIDER_TOKEN: ${{ secrets.RAIDER_TOKEN }}
          RAIDER_ENDPOINT: ${{ vars.RAIDER_ENDPOINT }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- The comment is rendered by the Raider server (`GET /api/v1/builds/summary`); the gem only fetches the Markdown and posts it. The same comment is updated on every run instead of adding a new one.
- Pull requests from forks are skipped: GitHub gives their workflows a read-only token, so the command prints a notice and exits 0.
- The command never fails your CI: it always exits 0 and prints notices to stderr, prefixed `[raider_reporter]`. It needs `GITHUB_TOKEN`, `GITHUB_REPOSITORY`, `GITHUB_EVENT_PATH`, `RAIDER_TOKEN` and `RAIDER_ENDPOINT`; if one is missing, or the event is not a pull request, it does nothing.
- It requires a Raider server that supports the summary endpoint and the `git.pr` field. Upgrade the server before using it.

## Quality gate

A Raider project can turn on gate rules (minimum pass rate, no new failures against the default branch, no new flaky tests) under its Gate page. Raider computes one verdict per build once every shard is in, and never changes it. `raider-reporter gate` waits for that verdict in CI and fails the job when the gate fails. Run it once, after every test job:

```yaml
  raider-gate:
    needs: [test]   # every test job id
    if: always() && vars.RAIDER_GATE == '1'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      statuses: write
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: "3.4", bundler-cache: true }
      - name: Wait for the Raider quality gate
        run: bundle exec raider-reporter gate
        env:
          RAIDER_TOKEN: ${{ secrets.RAIDER_TOKEN }}
          RAIDER_ENDPOINT: ${{ vars.RAIDER_ENDPOINT }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

| Outcome | Exit | Output |
|---|---|---|
| passed | 0 | stdout: `raider-reporter gate: passed` and one line per rule |
| no gate rules | 0 | stdout: `raider-reporter gate: no gate rules for this project` |
| failed | 1 | stderr: `raider-reporter gate: failed`, one line per failed rule (`  ✗ pass rate: 96% < 98%`) and the build URL |
| no verdict | 2 | stderr: timeout, Raider unreachable, token rejected, build not found, or another error |

- It polls every 10 seconds (10-second timeouts) for up to `RAIDER_GATE_TIMEOUT` seconds (default 600, 1–3600) and retries 429, 5xx and network errors. While waiting it prints, at most once a minute, `waiting for the verdict (build incomplete: 2 of 4 shards)` or `(analysing results)`.
- It needs `RAIDER_TOKEN`, `RAIDER_ENDPOINT` and the CI build key that uploads and `comment` use (GitHub Actions or Azure Pipelines); without them it exits 2.
- It posts a `raider/gate` status: pending while it waits, then success, failure (the failed rules) or error. On GitHub it needs `GITHUB_TOKEN` and `statuses: write`, and uses the PR head commit on `pull_request` events, else `GITHUB_SHA`. On Azure Repos pull requests it needs `SYSTEM_ACCESSTOKEN: $(System.AccessToken)`; other Azure builds get no status. A status that cannot be posted prints a warning and never changes the exit code. Require the `raider/gate` check in branch protection to block merges.
- Unlike `comment`, `gate` fails closed. Turn it on per repository (the `RAIDER_GATE` variable above) so pull requests from forks and projects without a token are not blocked. The token is never printed.

## Azure Pipelines

The gem detects Azure Pipelines when `TF_BUILD` is `true`. It reports the build (`provider: azure_pipelines`, build URL, attempt, job), the branch and commit, the pull request and a build key, so shards of one build group together. On a pull request from Azure Repos, `raider-reporter comment` posts one comment thread with the results and sets a `raider/tests` status on the PR.

```yaml
jobs:
  - job: tests
    steps:
      - task: UseRubyVersion@0
        inputs: { versionSpec: '3.4' }
      - script: bundle install
        displayName: Install gems
      - script: bundle exec rspec spec/ --format documentation
        displayName: Run tests
        env:
          RAIDER_TOKEN: $(RAIDER_TOKEN)
          RAIDER_ENDPOINT: $(RAIDER_ENDPOINT)
      - task: PublishPipelineArtifact@1
        condition: always()
        inputs: { targetPath: raider-results, artifact: raider-results-$(System.JobPositionInPhase)-$(System.JobAttempt) }
  - job: raider_comment
    dependsOn: tests
    condition: and(always(), eq(variables['Build.Reason'], 'PullRequest'))
    steps:
      - task: UseRubyVersion@0
        inputs: { versionSpec: '3.4' }
      - script: bundle install
      - script: bundle exec raider-reporter comment
        displayName: Comment Raider results on the pull request
        env:
          RAIDER_TOKEN: $(RAIDER_TOKEN)
          RAIDER_ENDPOINT: $(RAIDER_ENDPOINT)
          SYSTEM_ACCESSTOKEN: $(System.AccessToken)
```

- **One-time grant:** give "Contribute to pull requests" to `<Project> Build Service (<org>)` on the repository (Project settings > Repositories > Security). Without it the command prints a notice naming the exact identity and exits 0.
- **Map secrets explicitly:** Azure does not expose secret variables to scripts automatically. Map `RAIDER_TOKEN` and `System.AccessToken` with `env:` as shown. If a mapped variable is undefined, Azure passes the literal `$(...)`; the gem treats it as missing: results are still written locally but not uploaded, and `raider-reporter comment` prints a skip notice.
- **Pull request builds:** for Azure Repos, YAML `pr:` triggers are ignored. PR builds (and therefore the comment job) run only when the pipeline is added as a **Build validation** branch policy on the target branch.
- **Same stage:** keep the comment job in the same stage as the test jobs; the build key includes `System.StageAttempt`.
- **Artifact names:** pipeline artifacts cannot be overwritten within a run, so the name includes the job position and attempt. A fixed name would fail when you re-run failed jobs or use `strategy: parallel`.
- **Azure Repos only:** the PR comment works for repositories hosted in Azure Repos. A GitHub-hosted repository built by Azure Pipelines still uploads results, but `comment` prints `skipped: not an Azure Repos pull request`.
- **Parallel jobs:** `strategy: parallel: N` shards are detected automatically and grouped into one build, like GitHub matrix jobs.
- The command never fails your pipeline: it always exits 0 and prints notices to stderr, prefixed `[raider_reporter]`. It needs `SYSTEM_ACCESSTOKEN`, `RAIDER_TOKEN` and `RAIDER_ENDPOINT`, and requires a Raider server that supports the summary endpoint.

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

For example, matrix leg 2 of 2 with `parallel_rspec -n 2` yields shards 3 and 4 of 4, labelled `#2.1` and `#2.2`. `RAIDER_SHARD_TOTAL` must match the matrix size. Without it, `total` is null. If `PARALLEL_TEST_GROUPS` is missing or invalid, only `RAIDER_SHARD_INDEX` is used. Every matrix leg must use the same parallel_tests process count (`-n`) and set `RAIDER_SHARD_TOTAL`; mixing different `-n` values, or composed and plain legs, can repeat shard numbers.

Tip: run `rm -rf raider-results` before a parallel run. Each process only cleans its own files, so files from an earlier run with more processes stay behind.

## Examples

- `examples/rspec_basic` is a runnable RSpec project with a passing, a failing (with an attachment) and a skipped example. Run it with `cd examples/rspec_basic && bundle install && bundle exec rspec`; the failure is deliberate.
- `examples/cucumber_basic` is the same for Cucumber (plugin mode): a passing scenario, a failing one with an attachment, and an outline. Run it with `cd examples/cucumber_basic && bundle install && bundle exec cucumber`; the failure is deliberate.
- `examples/github_actions.yml` shows the workflow steps for CI.

## Schema

`run.json` follows schema v1, documented in [docs/schema-v1.md](docs/schema-v1.md). Statuses are `passed`, `failed`, `pending` and `skipped`, plus `quarantined` in schema 2 (written only when a run has a quarantined result). In both RSpec and Cucumber, a failure may carry `app_frame` (when a project frame is found): the first backtrace line inside your project, for example `spec/pages/login_page.rb:42:in 'LoginPage#submit'`, which Raider uses to group failures with the same error.

## Contributing

Bug reports and pull requests are welcome at https://github.com/RaiderHQ/raider_reporter. Run `bundle install && bundle exec rake` to run the specs. To test against another Cucumber, set `CUCUMBER_VERSION` (for example `CUCUMBER_VERSION="~> 9.0" bundle update cucumber && bundle exec rspec`).

## License

MIT. See [LICENSE](LICENSE).
