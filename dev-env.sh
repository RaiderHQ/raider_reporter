# Source before any ruby/bundle/rspec command: source dev-env.sh
# The shell profile pins GEM_HOME to the 4.0.2 gem tree; this makes PATH agree.
RUBY_VERSION_FOR_PROJECT="4.0.2"
RUBY_ABI="4.0.0"
export GEM_HOME="$HOME/.rubies/gems/${RUBY_VERSION_FOR_PROJECT}"
export GEM_PATH="$GEM_HOME:$HOME/.rubies/${RUBY_VERSION_FOR_PROJECT}/lib/ruby/gems/${RUBY_ABI}"
export PATH="$GEM_HOME/bin:$HOME/.rubies/${RUBY_VERSION_FOR_PROJECT}/bin:$PATH"
