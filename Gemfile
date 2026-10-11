# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
gem "webmock", "~> 3.26"
gem "cucumber", ENV.fetch("CUCUMBER_VERSION", "~> 10.0")
gem "logger" # cucumber 9 requires it without declaring it; Ruby 4 no longer bundles it
