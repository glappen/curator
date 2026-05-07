module Curator
  class Chat
    module Tools
      # RubyLLM tool exposed to chat-mode LLMs for on-demand knowledge-base
      # retrieval (M8). One instance per turn — `Curator::Chat::Asker`
      # latches in the `knowledge_base` + tentative `retrieval` row, then
      # calls `chat.with_tools(tool).ask(...)`. The LLM may invoke the
      # tool zero or more times within the turn; each invocation gets a
      # cumulatively-renumbered Format-1 context block plus a `hit_count`
      # so the system prompt's strict-grounding rider has something
      # concrete to react to.
      #
      # Continuous renumbering: hits from the second tool call in a
      # turn are emitted as `[K+1..K+M]` where K = total hits returned
      # by all prior calls in the same turn. Preserves the unique
      # `(retrieval_id, rank)` index on `curator_retrieval_hits` and
      # spares the LLM from disambiguating duplicate `[N]` markers
      # across calls within the answer it composes.
      #
      # Trace bracket is asymmetric on failure. If `#execute` raises
      # mid-flight (embedding error, keyword search blowing up), the
      # `:tool_call_started` step row is already written and no
      # paired `:tool_call_completed` follows. UI consumers that pair
      # frames by `call_index` should treat a missing `_completed`
      # within the turn boundary as a tool-call failure and surface
      # the outer `mark_failed!` instead of waiting for completion.
      class Retrieve < RubyLLM::Tool
        description <<~DESC
          Search the knowledge base for passages relevant to the user's question.
          Pass a search-optimized rephrasing of the user's most recent message:
          extract the key topic and any concrete entity names, drop conversational
          filler. Returns a numbered context block of source passages plus a
          hit_count. When hit_count is 0, no matching documents were found in this
          knowledge base.
        DESC

        param :query,
              type: :string,
              desc: "Search-optimized rephrasing of the user's question."

        # @param knowledge_base [Curator::KnowledgeBase] the KB this chat
        #   is pinned to (Q1-A: per-chat, decided at chat-creation time).
        # @param retrieval [Curator::Retrieval, nil] the (possibly
        #   tentative) retrieval row that step rows + hit rows attach to.
        #   May be nil when query logging is disabled — in that case the
        #   tool still functions but emits no audit trail.
        def initialize(knowledge_base:, retrieval:)
          super()
          @knowledge_base = knowledge_base
          @retrieval      = retrieval
          @call_index     = 0
          @rank_cursor    = 0
        end

        def execute(query:)
          call_index = @call_index
          @call_index += 1

          record_started!(call_index, query)

          hits        = run_pipeline(query)
          renumbered  = renumber(hits)
          persist!(renumbered)
          @rank_cursor += renumbered.size

          record_completed!(call_index, renumbered)

          {
            context:   Curator::Prompt::Assembler.render_context_block(hits: renumbered),
            hit_count: renumbered.size
          }
        end

        private

        # Pass `persist_hits: false`: Pipeline writes its embed_query /
        # vector_search / rrf_fusion trace steps against @retrieval, but
        # the per-hit audit insert is deferred until we've renumbered
        # ranks against the cumulative cursor.
        def run_pipeline(query)
          pipeline = Curator::Retrievers::Pipeline.new(
            query:          query,
            knowledge_base: @knowledge_base
          )
          pipeline.call(@retrieval, persist_hits: false)
        end

        def renumber(hits)
          offset = @rank_cursor
          hits.map { |h| h.with(rank: h.rank + offset) }
        end

        def persist!(renumbered)
          return unless @retrieval
          Curator::Retrievers::Pipeline.persist_hits!(@retrieval, renumbered)
        end

        # Started-event emission: payload captures inputs (call_index,
        # rephrased query). Block body is a no-op marker — Tracing.record
        # is the single write site so Phase 1's `curator.step` notification
        # fires uniformly for tool brackets too. Duration on the started
        # row will be ~0ms.
        def record_started!(call_index, query)
          Curator::Tracing.record(
            retrieval:       @retrieval,
            step_type:       :tool_call_started,
            payload_builder: ->(_) { { tool: "retrieve", call_index: call_index, query: query } }
          ) { nil }
        end

        def record_completed!(call_index, renumbered)
          rank_range = renumbered.empty? ? nil : [ renumbered.first.rank, renumbered.last.rank ]
          Curator::Tracing.record(
            retrieval:       @retrieval,
            step_type:       :tool_call_completed,
            payload_builder: ->(_) {
              {
                tool:       "retrieve",
                call_index: call_index,
                hit_count:  renumbered.size,
                rank_range: rank_range
              }
            }
          ) { nil }
        end
      end
    end
  end
end
