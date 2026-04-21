require "spec_helper"
require "erb"
require "pathname"

RSpec.describe "Curator install migration templates" do
  templates_dir = Pathname.new(File.expand_path("../../../../lib/generators/curator/install/templates", __dir__))

  expected = {
    "enable_vector.rb.tt"                  => { class_name: "EnableVector" },
    "create_curator_knowledge_bases.rb.tt" => {
      class_name: "CreateCuratorKnowledgeBases",
      table:      "curator_knowledge_bases",
      must_have:  [ "unique: true", "is_default = true" ]
    },
    "create_curator_documents.rb.tt"       => {
      class_name: "CreateCuratorDocuments",
      table:      "curator_documents",
      must_have:  [ "knowledge_base", "content_hash" ]
    },
    "create_curator_chunks.rb.tt"          => {
      class_name: "CreateCuratorChunks",
      table:      "curator_chunks",
      must_have:  [ "content_tsvector", "using: :gin" ]
    },
    "create_curator_embeddings.rb.tt"      => {
      class_name: "CreateCuratorEmbeddings",
      table:      "curator_embeddings",
      must_have:  [ "vector(1536)", "USING hnsw" ]
    },
    "create_curator_searches.rb.tt"        => {
      class_name: "CreateCuratorSearches",
      table:      "curator_searches",
      must_have:  [ "system_prompt_text", "retrieval_strategy", "chunk_limit" ]
    },
    "create_curator_search_steps.rb.tt"    => {
      class_name: "CreateCuratorSearchSteps",
      table:      "curator_search_steps",
      must_have:  [ "step_type", "payload" ]
    },
    "create_curator_evaluations.rb.tt"     => {
      class_name: "CreateCuratorEvaluations",
      table:      "curator_evaluations",
      must_have:  [ "failure_categories", "array: true", "using: :gin" ]
    },
    "add_curator_scope_to_chats.rb.tt"     => {
      class_name: "AddCuratorScopeToChats",
      must_have:  [ "add_column :chats, :curator_scope" ]
    }
  }

  # Render context for ERB templates — matches what the install generator
  # will provide at generation time.
  render_context = Object.new.tap do |obj|
    obj.define_singleton_method(:embedding_dim) { 1536 }
  end

  it "has exactly the expected set of templates" do
    actual = templates_dir.children.map { |p| p.basename.to_s }.sort
    expect(actual).to match_array(expected.keys)
  end

  expected.each do |filename, spec|
    describe filename do
      let(:path)     { templates_dir.join(filename) }
      let(:rendered) { ERB.new(path.read, trim_mode: "-").result(render_context.instance_eval { binding }) }

      it "renders to syntactically valid Ruby" do
        expect { RubyVM::InstructionSequence.compile(rendered) }.not_to raise_error
      end

      it "declares a migration class #{spec[:class_name]} inheriting from ActiveRecord::Migration[7.0]" do
        expect(rendered).to match(/class #{spec[:class_name]} < ActiveRecord::Migration\[7\.0\]/)
      end

      if spec[:table]
        it "targets the #{spec[:table]} table" do
          expect(rendered).to include(spec[:table])
        end
      end

      Array(spec[:must_have]).each do |fragment|
        it "contains required fragment: #{fragment}" do
          expect(rendered).to include(fragment)
        end
      end
    end
  end
end
