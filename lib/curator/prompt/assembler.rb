module Curator
  module Prompt
    # Pure-function system-prompt builder. `#call(kb:, hits:)` returns
    # the assembled prompt text, a stable SHA256 hash for analytics
    # grouping, and a heuristic token estimate. No DB writes, no LLM
    # calls — Asker (Phase 4) snapshots the result onto the open
    # `curator_retrievals` row, and the Query Console (M5/M6) can call
    # this directly for prompt preview.
    #
    # The instructions half is operator-overridable via
    # `kb.system_prompt`; the context block format is Curator-owned so
    # operators can't accidentally remove the citation markers an LLM
    # is being asked to emit.
    class Assembler
      CONTEXT_HEADER = "Context:".freeze

      # Render the citation-numbered context block. Public so chat-mode
      # tool calls (M8 `Curator::Chat::Tools::Retrieve`) can produce the
      # same Format-1 string the Asker injects into one-shot prompts. The
      # `rank_offset:` shifts displayed `[N]` markers — used to renumber
      # hits continuously across multiple tool calls within a single chat
      # turn so the LLM never sees a duplicate citation marker.
      #
      # Returns "" when hits is nil/empty so callers can paste the result
      # into a larger prompt template without conditional logic.
      def self.render_context_block(hits:, rank_offset: 0)
        return "" if hits.nil? || hits.empty?

        body = hits.map { |hit| render_hit(hit, rank_offset) }.join("\n\n")
        "#{CONTEXT_HEADER}\n\n#{body}"
      end

      def self.render_hit(hit, rank_offset)
        page = hit.page_number.nil? ? "" : " (page #{hit.page_number})"
        %([#{hit.rank + rank_offset}] From "#{hit.document_name}"#{page}:\n#{hit.text})
      end
      private_class_method :render_hit

      def call(kb:, hits:)
        instructions = instructions_for(kb)
        context      = self.class.render_context_block(hits: hits)
        text         = context.empty? ? instructions : "#{instructions}\n\n#{context}"

        {
          system_prompt_text:    text,
          system_prompt_hash:    Digest::SHA256.hexdigest(text),
          prompt_token_estimate: Curator::TokenCounter.count(text)
        }
      end

      private

      def instructions_for(kb)
        override = kb.system_prompt
        return override if override.is_a?(String) && !override.strip.empty?

        if kb.include_citations
          Templates::DEFAULT_INSTRUCTIONS_WITH_CITATIONS
        else
          Templates::DEFAULT_INSTRUCTIONS_WITHOUT_CITATIONS
        end
      end
    end
  end
end
