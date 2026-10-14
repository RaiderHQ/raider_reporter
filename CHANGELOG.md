# Changelog

## 0.6.0 — 2026-10-14

- Schema v1, additive: optional `failure.app_frame`, the first line of the raw exception backtrace that lies inside the project root (`Dir.pwd` when the reporter starts), outside `vendor/`, `.bundle/`, `Gem.path` and Ruby's library directory, and not `<internal:...>`. The path is made project-relative and the rest of the line is unchanged, e.g. `spec/pages/login_page.rb:42:in 'LoginPage#submit'`; at most 500 characters. The key is omitted when no line qualifies or computing it fails, so payloads without it are unchanged. Raider uses it to group failures by error
- Reported by both the RSpec and Cucumber reporters
- No breaking changes

## 0.5.1 — 2026-10-13

- Fix: a failed upload now reports one short line. An HTML error page (for example a server 500) is summarised as `the server returned an HTML error page` instead of being printed, other bodies are collapsed to one line of at most 200 characters, and the token is redacted from upload errors, including exception messages
- Docs: the Azure Pipelines snippet publishes `raider-results-$(System.JobPositionInPhase)-$(System.JobAttempt)`, so re-running failed jobs or `strategy: parallel` no longer collides on the artifact name

## 0.5.0 — 2026-10-12

- Add Azure Pipelines support: detect the build (`provider: azure_pipelines`, build URL, attempt, job, branch, commit), report Azure Repos pull requests in `run.git.pr`, and derive a stable id-based build key. `strategy: parallel` jobs are detected as shards of one build
- `raider-reporter comment` now works on Azure Pipelines: it creates or updates one tagged comment thread on the pull request (closed when the build passed) and sets a `raider/tests` PR status. Uses `System.AccessToken` with the PR statuses API version 7.1; the build service needs "Contribute to pull requests" on the repository. GitHub-hosted repositories built by Azure Pipelines are skipped with a notice
- Schema v1, additive: optional `run.git.pr.url` (set by GitHub Actions and Azure Pipelines)
- Unexpanded Azure macros such as `$(RAIDER_TOKEN)` or `$(System.AccessToken)` are treated as missing instead of being sent as a token
- Fix: redact the token before truncating error bodies in the GitHub and Azure clients, so a token straddling the 200-character cut can no longer leak partially
- Notices: the missing-permission notice uses `<project>` when the project name is unknown, and the success notice prints `PR #<n>` when the PR URL is unknown
- `raider-reporter comment` now runs only on GitHub Actions (`GITHUB_ACTIONS=true`) or Azure Pipelines; elsewhere it prints `skipped: unsupported CI` and exits 0
- No breaking changes

## 0.4.0 — 2026-10-11

- Add a Cucumber reporter (Cucumber >= 9, < 12; not a gem dependency). `require "raider_reporter/cucumber"` from `features/support/` registers it in plugin mode (recommended, works with any `--format` and no `--out`); `--format RaiderReporter::Cucumber::Formatter --out <file>` also works. Using both registers one listener
- Identity: `file_path` is project-relative (`features/login.feature`), `full_name` is `"<Feature>: <Scenario>"` (outline rows add `(<Examples name>, row <n>)`; when several Examples tables share a label, each is numbered: `(Examples 1, row 1)`, `(Examples 2, row 1)`), `identifier` is `<file>:<line>`
- Report the failing step (or Before/After hook) with its location in the failure message; ambiguous maps to failed, undefined to pending
- Retries: only the final attempt is kept, with `attempts` set and earlier attachments dropped
- Attachments: `RaiderReporter.attach` and Cucumber's `attach(path, media_type)` with an existing file path are captured; inline data and `log` messages are ignored
- Dry runs (`cucumber --dry-run`) write and upload nothing; `parallel_tests` shards write `run-<n>.json`
- No breaking changes: RSpec behaviour is unchanged

## 0.3.0 — 2026-10-11

- Report pull request identity: `run.ci.repository`, `run.git.default_branch` and `run.git.pr` (number, base/head branch, head SHA) on `pull_request` and `pull_request_target` events. Requires a Raider server that accepts `git.pr`
- Add `raider-reporter comment`: posts (and updates) one results comment on the pull request and sets the `raider/tests` commit status; fail-open, always exits 0, skips fork PRs
- Print the `Raider report: <url>` line to stderr instead of stdout, so stdout-parsing tools (such as `--format json`) stay clean
- Report the PR head commit's SHA and message on pull request events instead of the merge commit's
- Harden the GitHub client: only a bot-authored comment starting with the marker is updated, any number of trailing slashes in `GITHUB_API_URL` are accepted, and the token is redacted from error messages

## 0.2.0 — 2026-10-11

- Report the CI build key, attempt and job so runs of one build are grouped (GitHub Actions)
- Detect shards from `RAIDER_SHARD_INDEX`/`RAIDER_SHARD_TOTAL` or `parallel_tests` (`TEST_ENV_NUMBER`, `PARALLEL_TEST_GROUPS`) and report them per run; a matrix leg running parallel_tests is composed into unique shards
- Write parallel-safe local output (`run-<n>.json`, `attachments-<n>/`) when sharded; fixes parallel_tests processes overwriting each other's results
- Print the Raider build URL after upload, falling back to the run URL

## 0.1.1 — 2026-10-11

- Send run timestamps with millisecond precision, so durations under a second are no longer reported as 0

## 0.1.0 — 2026-10-11

- RSpec formatter writing Raider schema v1 to `raider-results/run.json`
- Screenshot and video attachments via `RaiderReporter.attach`, copied when attached (5 MB limit per file)
- Optional fail-open upload to a Raider server (`RAIDER_TOKEN`, `RAIDER_ENDPOINT`), capped at 45 MB / 1000 attachment files per upload
- GitHub Actions CI and git metadata detection
