module Curator
  class KnowledgeBase < ApplicationRecord
    include Turbo::Broadcastable

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

    has_many :documents,   class_name: "Curator::Document",  dependent: :destroy
    has_many :retrievals,  class_name: "Curator::Retrieval", dependent: :destroy

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

    # ---- Broadcasts (M5 Phase 3) ----
    # Card prepended on create, replaced on update, removed on destroy.
    # The index view subscribes to "curator_knowledge_bases_index" and
    # holds a `<turbo-frame id="curator_knowledge_bases_cards">` container
    # for new cards and per-KB `<turbo-frame id="<%= dom_id(kb, :card) %>">`
    # frames for replace/remove.
    after_create_commit -> {
      broadcast_prepend_to "curator_knowledge_bases_index",
                           target:  "curator_knowledge_bases_cards",
                           partial: "curator/knowledge_bases/card",
                           locals:  { kb: self }
    }
    after_update_commit -> {
      broadcast_replace_to "curator_knowledge_bases_index",
                           target:  ActionView::RecordIdentifier.dom_id(self, :card),
                           partial: "curator/knowledge_bases/card",
                           locals:  { kb: self }
    }
    after_destroy_commit -> {
      broadcast_remove_to "curator_knowledge_bases_index",
                          target: ActionView::RecordIdentifier.dom_id(self, :card)
    }

    def self.default
      find_by(is_default: true)
    end

    # Normalizes the `knowledge_base:` argument that public APIs accept:
    # nil falls back to the default KB, an instance passes through, and a
    # String/Symbol is looked up by slug. Anything else is a programmer
    # error and raises ArgumentError.
    def self.resolve(arg)
      case arg
      when nil            then default!
      when KnowledgeBase  then arg
      when String, Symbol then find_by!(slug: arg.to_s)
      else
        raise ArgumentError,
              "knowledge_base: must be a Curator::KnowledgeBase, String, or " \
              "Symbol slug (got #{arg.class})"
      end
    end

    # Routes use `param: :slug`, so URL helpers must read slug, not id.
    def to_param
      slug
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
    private_class_method :with_default_lock

    private

    # Serialize concurrent default-flips on a Postgres advisory lock so
    # they can't race the partial unique index
    # (index_curator_kb_on_single_default). The xact-scoped variant
    # auto-releases when the surrounding save's transaction commits or
    # rolls back. Without this, two simultaneous saves with is_default:
    # true would both clear+set and the second would surface
    # ActiveRecord::RecordNotUnique to callers.
    def unset_prior_default
      self.class.send(:with_default_lock) do
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
