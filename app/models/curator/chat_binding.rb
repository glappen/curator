module Curator
  # Curator-owned partition of RubyLLM's `chats` table. One row per
  # `Curator::Chat` instance: pins the KB, optionally tags a UI scope
  # (populated by scoped `curator:chat_ui` generator runs).
  #
  # `Curator.ask` does *not* write here — bindings exist only for the
  # multi-turn `Curator.chat` flow.
  class ChatBinding < ApplicationRecord
    self.table_name = "curator_chat_bindings"

    belongs_to :knowledge_base, class_name: "Curator::KnowledgeBase"
    # `class_name: "::Chat"` (top-level) — without the leading `::`, AR
    # resolves the constant inside the enclosing `Curator` module and
    # finds `Curator::Chat` (the wrapper) instead of RubyLLM's
    # ActiveRecord-backed `Chat`.
    belongs_to :chat, class_name: "::Chat"

    validates :chat_id, presence: true, uniqueness: true
  end
end
