module Curator
  class KnowledgeBase < ApplicationRecord
    self.table_name = "curator_knowledge_bases"

    DEFAULT_LOCK_KEY = "curator_kb_default".freeze

    has_many :documents, class_name: "Curator::Document", dependent: :destroy
    has_many :searches,  class_name: "Curator::Search",   dependent: :destroy

    validates :name, presence: true
    validates :slug,
              presence: true,
              uniqueness: true,
              format: { with: /\A[a-z0-9_-]+\z/ }
    validates :embedding_model,      presence: true
    validates :chat_model,           presence: true
    validates :chunk_size,           numericality: { only_integer: true, greater_than: 0 }
    validates :chunk_overlap,        numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :similarity_threshold, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :retrieval_strategy,   inclusion: { in: %w[hybrid vector keyword] }

    before_save :unset_prior_default, if: -> { is_default? && is_default_changed? }

    def self.seed_default!
      find_by(is_default: true) || create!(
        name: "Default",
        slug: "default",
        is_default: true,
        embedding_model: "text-embedding-3-small",
        chat_model: "gpt-5-mini"
      )
    end

    private

    # Serialize concurrent default-flips on a Postgres advisory lock so
    # they can't race the partial unique index
    # (index_curator_kb_on_single_default). The xact-scoped variant
    # auto-releases when the surrounding save's transaction commits or
    # rolls back. Without this, two simultaneous saves with is_default:
    # true would both clear+set and the second would surface
    # ActiveRecord::RecordNotUnique to callers.
    def unset_prior_default
      self.class.connection.execute(
        self.class.sanitize_sql_array([
          "SELECT pg_advisory_xact_lock(hashtext(?))", DEFAULT_LOCK_KEY
        ])
      )
      self.class.where(is_default: true).where.not(id: id).update_all(is_default: false)
    end
  end
end
