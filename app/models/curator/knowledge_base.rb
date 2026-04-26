module Curator
  class KnowledgeBase < ApplicationRecord
    self.table_name = "curator_knowledge_bases"

    DEFAULT_LOCK_KEY        = "curator_kb_default".freeze
    DEFAULT_EMBEDDING_MODEL = "text-embedding-3-small".freeze
    DEFAULT_CHAT_MODEL      = "gpt-5-mini".freeze

    # The standard text search configurations shipped with Postgres. A
    # typo'd config would otherwise only surface as a Postgres error from
    # inside Curator::Chunk's after_save callback at ingest time.
    # Custom site-installed configs require extending this list.
    TSVECTOR_CONFIGS = %w[
      simple arabic armenian basque catalan danish dutch english finnish
      french german greek hindi hungarian indonesian irish italian
      lithuanian nepali norwegian portuguese romanian russian serbian
      spanish swedish tamil turkish yiddish
    ].freeze

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
    validates :chunk_limit,          numericality: { only_integer: true, greater_than: 0 }
    validates :similarity_threshold, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
    validates :retrieval_strategy,   inclusion: { in: %w[hybrid vector keyword] }
    validates :tsvector_config,      inclusion: { in: TSVECTOR_CONFIGS }
    validate :chunk_overlap_smaller_than_chunk_size

    before_save :unset_prior_default, if: -> { is_default? && is_default_changed? }

    def self.default
      find_by(is_default: true)
    end

    def self.default!
      default || raise(ActiveRecord::RecordNotFound,
                       "no default Curator::KnowledgeBase exists — " \
                       "run Curator::KnowledgeBase.seed_default! or pass `knowledge_base:` explicitly")
    end

    def self.seed_default!
      with_default_lock do
        find_by(is_default: true) || create!(
          name:            "Default",
          slug:            "default",
          is_default:      true,
          embedding_model: DEFAULT_EMBEDDING_MODEL,
          chat_model:      DEFAULT_CHAT_MODEL
        )
      end
    rescue ActiveRecord::RecordNotUnique
      find_by!(is_default: true)
    end

    private

    def self.with_default_lock
      transaction do
        connection.execute(
          sanitize_sql_array([
            "SELECT pg_advisory_xact_lock(hashtext(?))", DEFAULT_LOCK_KEY
          ])
        )
        yield
      end
    end

    # Serialize concurrent default-flips on a Postgres advisory lock so
    # they can't race the partial unique index
    # (index_curator_kb_on_single_default). The xact-scoped variant
    # auto-releases when the surrounding save's transaction commits or
    # rolls back. Without this, two simultaneous saves with is_default:
    # true would both clear+set and the second would surface
    # ActiveRecord::RecordNotUnique to callers.
    def unset_prior_default
      self.class.with_default_lock do
        self.class.where(is_default: true).where.not(id: id).update_all(is_default: false)
      end
    end

    def chunk_overlap_smaller_than_chunk_size
      return if chunk_size.blank? || chunk_overlap.blank?
      return if chunk_overlap < chunk_size

      errors.add(:chunk_overlap, "must be less than chunk_size")
    end
  end
end
