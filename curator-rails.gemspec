require_relative "lib/curator/version"

Gem::Specification.new do |spec|
  spec.name        = "curator-rails"
  spec.version     = Curator::VERSION
  spec.authors     = [ "Greg Lappen" ]
  spec.email       = [ "greg@lapcominc.com" ]
  spec.homepage    = "https://github.com/glappen/curator-rails"
  spec.summary     = "Production-ready Retrieval Augmented Generation for Rails."
  spec.description = "A Rails engine that adds a knowledge base, semantic " \
                     "search, Q&A over documents, a polished admin UI, and a " \
                     "JSON API on top of RubyLLM and pgvector. Mount it, run " \
                     "the generator, and your app has RAG."
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.post_install_message = <<~MSG
    Curator requires auth hooks before it will serve non-test requests.
    Configure `authenticate_admin_with` and `authenticate_api_with` in
    config/initializers/curator.rb after running `rails g curator:install`.
    Unconfigured requests raise Curator::AuthNotConfigured in dev and prod.
  MSG

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails",       ">= 7.0"
  spec.add_dependency "ruby_llm",    "~> 1"
  spec.add_dependency "neighbor",    ">= 0.5"
  spec.add_dependency "pg",          ">= 1.5"
  spec.add_dependency "turbo-rails", ">= 2.0"
  # `csv` left default-gems in Ruby 3.4. The exporter services
  # write CSV via the stdlib API, so depend on it explicitly.
  spec.add_dependency "csv",         ">= 3.2"
end
