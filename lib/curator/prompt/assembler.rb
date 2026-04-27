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

      def call(kb:, hits:)
        instructions = instructions_for(kb)
        context      = context_block(hits)
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

      def context_block(hits)
        return "" if hits.nil? || hits.empty?

        body = hits.map { |hit| render_hit(hit) }.join("\n\n")
        "#{CONTEXT_HEADER}\n\n#{body}"
      end

      def render_hit(hit)
        page = hit.page_number.nil? ? "" : " (page #{hit.page_number})"
        %([#{hit.rank}] From "#{hit.document_name}"#{page}:\n#{hit.text})
      end
    end
  end
end
