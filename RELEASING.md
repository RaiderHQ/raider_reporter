# Releasing raider_reporter

Releases are published to rubygems.org from GitHub Actions with
[trusted publishing](https://guides.rubygems.org/trusted-publishing/). No RubyGems API key is stored in the repository
or in GitHub secrets.

## One-time setup (gem owner)

Before the first release from CI, an owner of the `raider_reporter` gem must add a GitHub Actions trusted publisher on
rubygems.org (gem page, Settings, Trusted publishers):

- Repository owner: `RaiderHQ`
- Repository name: `raider_reporter`
- Workflow filename: `release.yml`
- Environment: `rubygems.org` (the name used by the `environment:` entry in `.github/workflows/release.yml`; create the
  environment in the repository settings, or leave both empty and remove the entry from the workflow)

Once the trusted publisher is in place, the API-key path is retired: revoke any RubyGems API key that was used to push
this gem, and do not run `gem push` by hand.

## Cutting a release

1. Update `lib/raider_reporter/version.rb` and the `CHANGELOG.md` heading in a pull request and merge it.
2. Publish a GitHub release for the tag `vX.Y.Z` (or push the tag `vX.Y.Z`).
3. The `Release` workflow runs `bundle exec rspec` and then `rubygems/release-gem@v1`, which builds the gem, pushes it
   to rubygems.org and tags the release.
