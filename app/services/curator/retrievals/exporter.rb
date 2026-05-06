require "csv"
require "json"

module Curator
  module Retrievals
    # Streams Retrievals as CSV or JSON for an admin "Export" download or
    # the `curator:retrievals:export` rake task. Filters mirror the
    # querystring contract on `RetrievalsController#index` so the same
    # filter form drives both the on-screen table and the export.
    #
    # CSV is written line-by-line via `io.write` so an
    # `ActionController::Live` stream surfaces rows incrementally rather
    # than buffering the full result (`Live::Buffer` implements `write`
    # but not `puts`). JSON is a single document — small enough to
    # materialize and shape-friendly for downstream tooling.
    #
    # Rows come out in PK-descending order (`find_each(order: :desc)`),
    # which approximates the on-screen "newest first" sort without
    # tripping the "Scoped order is ignored" warning that any non-PK
    # `order` clause produces under `find_each`.
    #
    # Answer text is truncated at `ANSWER_TRUNCATION` chars: full
    # generated answers can be multi-KB and bloating every row by 10x
    # for an export field that's typically previewed, not consumed
    # whole, isn't a good trade.
    class Exporter
      COLUMNS = %i[
        retrieval_id query answer kb_slug chat_model embedding_model
        status origin retrieved_hit_count eval_count created_at
      ].freeze

      ANSWER_TRUNCATION = 500

      # Filter-key contract for `Curator::Tasks::Export` — the rake-task
      # dispatcher reads these to map ENV args (`KB=`, `SINCE=`) onto
      # the keys this exporter actually expects. Retrievals use
      # `:kb_slug` (so it doesn't clash with the controller's numeric
      # `:knowledge_base_id`) and `:from` (mirrors the controller's
      # date-range param).
      CLI_KB_KEY    = :kb_slug
      CLI_SINCE_KEY = :from

      def self.stream(io:, format:, filters: {})
        new(filters: filters).stream(io: io, format: format)
      end

      def initialize(filters: {})
        @filters = filters || {}
      end

      def stream(io:, format:)
        case format.to_s
        when "csv"  then write_csv(io)
        when "json" then write_json(io)
        else
          raise ArgumentError, "unknown format: #{format.inspect}"
        end
      end

      private

      # `io.write` rather than `io.puts` — `ActionController::Live::Buffer`
      # implements `write`/`<<` but not `puts`, and exceptions on the
      # action thread surface as a silent empty body in tests.
      # `CSV.generate_line` already terminates with a newline, so write
      # is also semantically identical for `StringIO`.
      def write_csv(io)
        io.write(CSV.generate_line(COLUMNS))
        each_row { |row| io.write(CSV.generate_line(COLUMNS.map { |col| row[col] })) }
      end

      # JSON is emitted as a streamed array literal — open bracket, comma
      # between objects, close bracket — so the same `find_each` walk
      # that powers CSV doesn't have to materialize an intermediate
      # array. The result is still a single valid JSON document.
      def write_json(io)
        io.write("[")
        first = true
        each_row do |row|
          io.write(",") unless first
          io.write(JSON.generate(row.transform_keys(&:to_s)))
          first = false
        end
        io.write("]")
      end

      # `find_each(order: :desc)` walks PK descending — approximates
      # newest-first chronologically without the silently-dropped
      # `order(created_at: :desc)` that `find_each` warns about.
      def each_row
        scope.find_each(order: :desc) do |retrieval|
          yield row_for(retrieval)
        end
      end

      def row_for(retrieval)
        {
          retrieval_id:        retrieval.id,
          query:               retrieval.query,
          answer:              answer_for(retrieval),
          kb_slug:             retrieval.knowledge_base.slug,
          chat_model:          retrieval.chat_model,
          embedding_model:     retrieval.embedding_model,
          status:              retrieval.status,
          origin:              retrieval.origin,
          retrieved_hit_count: retrieval.retrieval_hits.size,
          eval_count:          retrieval.evaluations.size,
          created_at:          retrieval.created_at&.iso8601
        }
      end

      def answer_for(retrieval)
        text = retrieval.message&.content
        return nil if text.nil?
        text.length > ANSWER_TRUNCATION ? "#{text[0, ANSWER_TRUNCATION - 1]}…" : text
      end

      def scope
        apply_filters(
          Curator::Retrieval.includes(:knowledge_base, :message, :retrieval_hits, :evaluations)
        )
      end

      def apply_filters(scope)
        f = @filters
        scope = scope.where(origin: %w[adhoc console]) unless truthy?(f[:show_review])
        scope = scope.where(knowledge_base_id: f[:knowledge_base_id]) if f[:knowledge_base_id].present?
        if f[:kb_slug].present?
          scope = scope.joins(:knowledge_base)
                       .where(curator_knowledge_bases: { slug: f[:kb_slug] })
        end
        if (from = parse_date(f[:from]))
          scope = scope.where("curator_retrievals.created_at >= ?", from)
        end
        if (to = parse_date(f[:to]))
          scope = scope.where("curator_retrievals.created_at <  ?", to + 1)
        end
        scope = scope.where(status: f[:status])                   if f[:status].present?
        scope = scope.where(chat_model: f[:chat_model])           if f[:chat_model].present?
        scope = scope.where(embedding_model: f[:embedding_model]) if f[:embedding_model].present?
        scope = scope.where("query ILIKE ?", "%#{f[:query]}%")    if f[:query].present?
        scope = apply_rating_filter(scope, f)
        scope
      end

      def apply_rating_filter(scope, filters)
        if filters[:rating].present?
          scope.joins(:evaluations).where(curator_evaluations: { rating: filters[:rating] }).distinct
        elsif truthy?(filters[:unrated])
          scope.where.missing(:evaluations)
        else
          scope
        end
      end

      def parse_date(value)
        return value if value.is_a?(Date) || value.is_a?(Time)
        return nil if value.blank?
        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def truthy?(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end
    end
  end
end
