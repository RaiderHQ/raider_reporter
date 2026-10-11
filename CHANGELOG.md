# Changelog

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
