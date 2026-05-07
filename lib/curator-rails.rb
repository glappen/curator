require "ruby_llm"
require "neighbor"
require "curator"
# Subclasses of `RubyLLM::Tool` cannot be required from `lib/curator.rb`
# because that file is loaded by `spec_helper.rb` before Rails (and
# therefore ruby_llm) is on the load path. Defer until after `ruby_llm`
# is required here.
require "curator/chat/tools/retrieve"
require "curator/engine"
