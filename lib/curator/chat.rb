module Curator
  # Public wrapper around RubyLLM's `Chat` for multi-turn,
  # tool-driven retrieval. Pins a KB at creation time and persists the
  # pin in `curator_chat_bindings` so resumption (`Curator.chat(id:)`)
  # can rehydrate the same KB without the caller passing it again.
  #
  # Phase 3a ships only the public surface — `#ask` and `#history`
  # raise `NotImplementedError` until Phase 3b lands the real
  # `Curator::ChatAsker` orchestration. Generator (Phase 4) develops
  # against this frozen contract in parallel.
  class Chat
    def self.create(knowledge_base: nil)
      kb = Curator::KnowledgeBase.resolve(knowledge_base)
      ActiveRecord::Base.transaction do
        raw_chat     = ::Chat.create!(model: kb.chat_model)
        chat_binding = Curator::ChatBinding.create!(chat: raw_chat, knowledge_base: kb)
        new(raw: raw_chat, binding: chat_binding)
      end
    end

    def self.find(id:)
      chat_binding = Curator::ChatBinding.find_by!(chat_id: id)
      new(raw: chat_binding.chat, binding: chat_binding)
    end

    def initialize(raw:, binding:)
      @raw     = raw
      @binding = binding
    end

    attr_reader :raw

    def id
      @binding.chat_id
    end

    def knowledge_base
      @binding.knowledge_base
    end

    def ask(_text, &_stream_block)
      raise NotImplementedError,
            "Curator::Chat#ask lands in M8 Phase 3b (Curator::ChatAsker)"
    end

    def history
      raise NotImplementedError,
            "Curator::Chat#history lands in M8 Phase 3b"
    end
  end
end
