module Curator
  module Prompt
    # Default text fragments used by `Curator::Prompt::Assembler` and
    # the strict-grounding refusal path. Held as constants so test code
    # can match on them without string duplication. v2 may add per-KB
    # overrides for any of these; for now they're the only voice.
    module Templates
      DEFAULT_INSTRUCTIONS_WITH_CITATIONS = <<~TEXT.strip
        You are a helpful assistant answering questions using the provided
        context.

        Reference sources using `[N]` markers that match the numbered
        context entries below. Cite every factual claim you draw from
        the context.

        Answer only from the provided context. If the context does not
        contain the answer, say so plainly rather than guessing or
        drawing on outside knowledge.
      TEXT

      DEFAULT_INSTRUCTIONS_WITHOUT_CITATIONS = <<~TEXT.strip
        You are a helpful assistant answering questions using the provided
        context.

        Answer only from the provided context. If the context does not
        contain the answer, say so plainly rather than guessing or
        drawing on outside knowledge.
      TEXT

      REFUSAL_MESSAGE = "I don't have information on that in the knowledge base.".freeze
    end
  end
end
