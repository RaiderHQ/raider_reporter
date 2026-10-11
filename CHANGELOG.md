# Changelog

## 0.1.1 — 2026-10-11

- Send run timestamps with millisecond precision, so durations under a second are no longer reported as 0

## 0.1.0 — 2026-10-11

- RSpec formatter writing Raider schema v1 to `raider-results/run.json`
- Screenshot and video attachments via `RaiderReporter.attach`, copied when attached (5 MB limit per file)
- Optional fail-open upload to a Raider server (`RAIDER_TOKEN`, `RAIDER_ENDPOINT`), capped at 45 MB / 1000 attachment files per upload
- GitHub Actions CI and git metadata detection
