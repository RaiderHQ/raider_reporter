# frozen_string_literal: true

require "raider_reporter"
require "tmpdir"
require "json"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
end
