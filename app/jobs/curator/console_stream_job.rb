module Curator
  # Streams a single Console run to the per-tab Turbo broadcast topic.
  #
  # `topic` is a per-page UUID rendered into `console#show` and round-tripped
  # through the form's hidden field, so two browser tabs each get an isolated
  # Cable channel. The sequence is: streaming-status replace → one append per
  # LLM delta → sources replace → done-status replace. A `Curator::Error` or
  # `RecordNotFound` becomes a single `:failed` status frame; the partial Asker
  # output that already streamed stays on screen.
  #
  # Defensive structure: any unexpected `StandardError` (e.g., a partial
  # render error inside `broadcast_replace_to`) also broadcasts a `:failed`
  # status before re-raising, so the badge never gets stuck mid-flight when
  # the underlying cause is a programmer error rather than a Curator one.
  class ConsoleStreamJob < ApplicationJob
    def perform(topic:, knowledge_base_slug:, query:,
                chunk_limit: nil, similarity_threshold: nil, strategy: nil,
                system_prompt: nil, chat_model: nil)
      Rails.logger.info("[ConsoleStreamJob] start topic=#{topic} kb=#{knowledge_base_slug}")
      broadcast_status(topic, state: :streaming)

      delta_count = 0
      kb = Curator::KnowledgeBase.resolve(knowledge_base_slug)
      answer = Curator::Asker.call(
        query,
        knowledge_base: kb,
        limit:          chunk_limit,
        threshold:      similarity_threshold,
        strategy:       strategy,
        system_prompt:  system_prompt,
        chat_model:     chat_model
      ) do |delta|
        delta_count += 1
        # Wrap each delta in a `<span data-seq>` so the
        # `console-stream` Stimulus controller can reorder spans that
        # land out of order. Action Cable's pubsub does not guarantee
        # in-order delivery on a single stream, even though the
        # broadcasts here are sequential — see
        # https://rubyllm.com/rails ("Message Ordering Issues").
        Turbo::StreamsChannel.broadcast_append_to(
          topic,
          target: "console-answer",
          html:   %(<span data-seq="#{delta_count}">#{ERB::Util.html_escape(delta)}</span>)
        )
      end

      Rails.logger.info(
        "[ConsoleStreamJob] asker done deltas=#{delta_count} sources=#{answer.sources.size}"
      )
      broadcast_sources(topic, answer.sources, kb)
      broadcast_evaluation_widget(topic, answer.retrieval_id) if answer.retrieval_id
      broadcast_status(topic, state: :done)
      Rails.logger.info("[ConsoleStreamJob] complete topic=#{topic}")
    rescue Curator::Error, ActiveRecord::RecordNotFound => e
      Rails.logger.warn("[ConsoleStreamJob] expected failure: #{e.class}: #{e.message}")
      safely_broadcast_status(topic, state: :failed, message: e.message)
    rescue StandardError => e
      Rails.logger.error(
        "[ConsoleStreamJob] unexpected #{e.class}: #{e.message}\n" \
        "#{e.backtrace.first(15).join("\n")}"
      )
      safely_broadcast_status(topic, state: :failed, message: "#{e.class}: #{e.message}")
      raise
    end

    private

    # `broadcast_status` itself can raise (e.g., partial render error in the
    # status template). Catch + log so the rescue paths don't swallow the
    # original exception with a secondary one.
    def safely_broadcast_status(topic, state:, message: nil)
      broadcast_status(topic, state: state, message: message)
    rescue StandardError => err
      Rails.logger.error(
        "[ConsoleStreamJob] could not broadcast :#{state} status: #{err.class}: #{err.message}"
      )
    end

    # `update` rather than `replace`: the partials don't carry the
    # `console-status` / `console-sources` id on their root element.
    # `replace` would swap the wrapping div out for the partial content,
    # leaving no element with that id behind for the next broadcast to
    # target — the badge would freeze on its first state. `update` keeps
    # the wrapping div and only swaps its inner contents, so subsequent
    # broadcasts (and re-runs on the same page) keep finding the target.
    def broadcast_status(topic, state:, message: nil)
      Turbo::StreamsChannel.broadcast_update_to(
        topic,
        target:  "console-status",
        partial: "curator/console/status",
        locals:  { state: state, message: message }
      )
    end

    # Post-success eval surface: M7 Phase 2's inline thumbs widget.
    # Skipped on `:failed` runs (the `rescue` paths return before
    # we reach this point) so a broken run doesn't sprout a rating
    # form against a row that may not even have a usable answer.
    def broadcast_evaluation_widget(topic, retrieval_id)
      Turbo::StreamsChannel.broadcast_update_to(
        topic,
        target:  "console-evaluation",
        partial: "curator/console/evaluation",
        locals:  { retrieval_id: retrieval_id }
      )
    end

    def broadcast_sources(topic, hits, kb)
      if hits.empty?
        Turbo::StreamsChannel.broadcast_update_to(
          topic,
          target:  "console-sources",
          partial: "curator/console/empty_sources"
        )
      else
        Turbo::StreamsChannel.broadcast_update_to(
          topic,
          target:     "console-sources",
          partial:    "curator/console/source",
          collection: hits,
          as:         :hit,
          locals:     { kb: kb }
        )
      end
    end
  end
end
