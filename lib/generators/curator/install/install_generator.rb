require "rails/generators"
require "rails/generators/active_record"

module Curator
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      namespace "curator:install"

      source_root File.expand_path("templates", __dir__)

      class_option :embedding_dim, type: :numeric, default: 1536,
                                   desc: "Vector dimension for the embedding column (default 1536)"
      class_option :mount_at, type: :string, default: "/curator",
                              desc: "Path at which to mount Curator::Engine in host routes"

      desc "Installs Curator: enables pgvector, copies migrations, writes an initializer, " \
           "mounts the engine, and chains ruby_llm:install."

      def self.next_migration_number(dirname)
        ::ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def verify_active_storage!
        unless active_storage_present?
          say_status :abort,
                     "Active Storage is required. Run `bin/rails active_storage:install` " \
                     "and then `bin/rails db:migrate` before rerunning this generator.",
                     :red
          exit 1
        end
      end

      def install_ruby_llm
        # Active Storage was verified above; pass through so ruby_llm doesn't
        # re-run `rails active_storage:install` (which would fail in fresh
        # test environments and is redundant otherwise).
        invoke "ruby_llm:install", [], skip_active_storage: true
      end

      def copy_migrations
        migration_template "enable_vector.rb.tt",
                           "db/migrate/enable_vector.rb"
        migration_template "create_curator_knowledge_bases.rb.tt",
                           "db/migrate/create_curator_knowledge_bases.rb"
        migration_template "create_curator_documents.rb.tt",
                           "db/migrate/create_curator_documents.rb"
        migration_template "create_curator_chunks.rb.tt",
                           "db/migrate/create_curator_chunks.rb"
        migration_template "create_curator_embeddings.rb.tt",
                           "db/migrate/create_curator_embeddings.rb"
        migration_template "create_curator_retrievals.rb.tt",
                           "db/migrate/create_curator_retrievals.rb"
        migration_template "create_curator_retrieval_steps.rb.tt",
                           "db/migrate/create_curator_retrieval_steps.rb"
        migration_template "create_curator_evaluations.rb.tt",
                           "db/migrate/create_curator_evaluations.rb"
        migration_template "add_curator_scope_to_chats.rb.tt",
                           "db/migrate/add_curator_scope_to_chats.rb"
      end

      def copy_initializer
        template "curator.rb.tt", "config/initializers/curator.rb"
      end

      def mount_engine
        route %(mount Curator::Engine, at: "#{mount_path}")
      end

      def show_next_steps
        say_status :info,
                   "Next: bin/rails db:migrate && bin/rails curator:seed_defaults",
                   :green
      end

      # Public so specs can stub it without running against the real schema.
      # Host apps never call this directly.
      def self.active_storage_installed?
        defined?(ActiveStorage::Blob) &&
          ActiveStorage::Blob.respond_to?(:table_exists?) &&
          ActiveStorage::Blob.table_exists?
      end

      private

      def embedding_dim
        options[:embedding_dim].to_i
      end

      def mount_path
        options[:mount_at]
      end

      def active_storage_present?
        self.class.active_storage_installed?
      end
    end
  end
end
