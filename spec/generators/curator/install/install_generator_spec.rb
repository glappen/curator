require "rails_helper"
require "rails/generators"
require "rails/generators/testing/behavior"
require "rails/generators/testing/assertions"
require "generators/curator/install/install_generator"

RSpec.describe Curator::Generators::InstallGenerator, type: :generator do
  include Rails::Generators::Testing::Behavior
  include Rails::Generators::Testing::Assertions
  include FileUtils

  tests Curator::Generators::InstallGenerator
  destination File.expand_path("../../../../tmp/generator_test", __dir__)

  before do
    prepare_destination
    # Routes file that `route` will append to.
    FileUtils.mkdir_p(File.join(destination_root, "config"))
    File.write(
      File.join(destination_root, "config/routes.rb"),
      "Rails.application.routes.draw do\nend\n"
    )

    # Keep the Active Storage check hermetic — don't hit the dummy DB.
    allow(Curator::Generators::InstallGenerator)
      .to receive(:active_storage_installed?).and_return(true)
  end

  def find_migration(pattern)
    Dir.glob(File.join(destination_root, "db/migrate/*.rb"))
       .find { |p| File.basename(p).match?(pattern) }
  end

  describe "--embedding-dim" do
    it "writes vector(1536) by default" do
      run_generator
      path = find_migration(/create_curator_embeddings/)
      expect(path).not_to be_nil
      expect(File.read(path)).to include("vector(1536)")
    end

    it "writes vector(3072) when --embedding-dim=3072 is given" do
      run_generator %w[--embedding-dim=3072]
      path = find_migration(/create_curator_embeddings/)
      expect(File.read(path)).to include("vector(3072)")
    end
  end

  describe "--mount-at" do
    it 'defaults to mounting at "/curator"' do
      run_generator
      expect(File.read(File.join(destination_root, "config/routes.rb")))
        .to include(%(mount Curator::Engine, at: "/curator"))
    end

    it "respects a custom mount path" do
      run_generator %w[--mount-at=/kb]
      expect(File.read(File.join(destination_root, "config/routes.rb")))
        .to include(%(mount Curator::Engine, at: "/kb"))
    end
  end

  describe "initializer" do
    it "writes config/initializers/curator.rb" do
      run_generator
      path = File.join(destination_root, "config/initializers/curator.rb")
      expect(File).to exist(path)
      content = File.read(path)
      expect(content).to include("Curator.configure")
      expect(content).to include("authenticate_admin_with")
      expect(content).to include("authenticate_api_with")
      expect(content).to include("extractor")
      expect(content).to include("trace_level")
    end
  end

  describe "migration set" do
    before { run_generator }

    %w[
      enable_vector
      create_curator_knowledge_bases
      create_curator_documents
      create_curator_chunks
      create_curator_embeddings
      create_curator_retrievals
      create_curator_retrieval_steps
      create_curator_evaluations
      add_curator_scope_to_chats
    ].each do |name|
      it "generates a migration for #{name}" do
        expect(find_migration(/#{name}/)).not_to be_nil
      end
    end

    it "assigns monotonically increasing timestamps" do
      stamps = Dir.glob(File.join(destination_root, "db/migrate/*.rb"))
                  .map { |p| File.basename(p).split("_", 2).first.to_i }
      expect(stamps).to eq(stamps.sort)
      expect(stamps.uniq.length).to eq(stamps.length)
    end
  end

  describe "idempotency" do
    it "does not create duplicate migrations on a second run" do
      run_generator
      first_set = Dir.glob(File.join(destination_root, "db/migrate/*.rb")).sort

      # Re-run — Rails' migration_template detects existing migrations by
      # class name and skips them.
      run_generator
      second_set = Dir.glob(File.join(destination_root, "db/migrate/*.rb")).sort

      expect(second_set).to eq(first_set)
    end
  end

  describe "when Active Storage is missing" do
    it "aborts with a non-zero exit" do
      allow(Curator::Generators::InstallGenerator)
        .to receive(:active_storage_installed?).and_return(false)

      expect { run_generator }.to raise_error(SystemExit) { |e|
        expect(e.status).not_to eq(0)
      }
    end
  end

  describe "ActionCable check" do
    it "warns when config/cable.yml is absent" do
      output = run_generator
      expect(output).to match(/warn.*cable\.yml not found/i)
    end

    it "is silent about cable when config/cable.yml exists" do
      FileUtils.mkdir_p(File.join(destination_root, "config"))
      File.write(File.join(destination_root, "config/cable.yml"), "development:\n  adapter: async\n")

      output = run_generator
      expect(output).not_to match(/cable\.yml not found/i)
    end

    it "always prints the production cable adapter reminder in the next-steps block" do
      output = run_generator
      expect(output).to match(/ActionCable adapter/)
    end
  end

  describe "RubyLLM chaining" do
    it "invokes ruby_llm:install — RubyLLM migrations end up in db/migrate" do
      run_generator
      ruby_llm_migrations = Dir.glob(File.join(destination_root, "db/migrate/*.rb"))
                               .select { |p| File.basename(p).match?(/create_(chats|messages|tool_calls|models)/) }
      expect(ruby_llm_migrations).not_to be_empty
    end
  end
end
