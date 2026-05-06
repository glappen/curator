require "csv"
require "json"

module Curator
  module Evaluations
    # Streams Evaluations as CSV or JSON for the admin "Export" button
    # and the `curator:evaluations:export` rake task. Filters mirror
    # `EvaluationsController#index` so the same querystring drives the
    # in-page table and the export.
    #
    # Streaming model matches `Curator::Retrievals::Exporter` —
    # line-by-line `io.write` for CSV (so `ActionController::Live::Buffer`
    # works; it doesn't implement `puts`), single JSON document for JSON.
    # Failure categories serialize as a semicolon-joined string in CSV
    # (so the column round-trips through Excel without splitting on
    # commas) and as a JSON array in JSON. An empty list becomes nil
    # in CSV (renders as a blank cell) and `[]` in JSON.
    #
    # Rows come out in PK-descending order — see
    # `Curator::Retrievals::Exporter` for the rationale.
    class Exporter
      COLUMNS = %i[
        retrieval_id query answer kb_slug chat_model embedding_model
        rating feedback ideal_answer failure_categories
        evaluator_id evaluator_role created_at
      ].freeze

      ANSWER_TRUNCATION = 500

      # Filter-key contract for `Curator::Tasks::Export`. Evaluations
      # mirror the controller's `:kb`/`:since` params directly — see
      # `Curator::Retrievals::Exporter` for why retrievals are different.
      CLI_KB_KEY    = :kb
      CLI_SINCE_KEY = :since

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

      # See `Curator::Retrievals::Exporter#write_csv` — `io.write`
      # rather than `io.puts` so this works against
      # `ActionController::Live::Buffer`, which doesn't implement
      # `puts`.
      def write_csv(io)
        io.write(CSV.generate_line(COLUMNS))
        each_row(:csv) do |row|
          io.write(CSV.generate_line(COLUMNS.map { |col| row[col] }))
        end
      end

      def write_json(io)
        io.write("[")
        first = true
        each_row(:json) do |row|
          io.write(",") unless first
          io.write(JSON.generate(row.transform_keys(&:to_s)))
          first = false
        end
        io.write("]")
      end

      # `find_each(order: :desc)` — see `Curator::Retrievals::Exporter`.
      def each_row(format)
        scope.find_each(order: :desc) do |evaluation|
          yield row_for(evaluation, format)
        end
      end

      def row_for(evaluation, format)
        retrieval = evaluation.retrieval
        {
          retrieval_id:       retrieval.id,
          query:              retrieval.query,
          answer:             answer_for(retrieval),
          kb_slug:            retrieval.knowledge_base.slug,
          chat_model:         retrieval.chat_model,
          embedding_model:    retrieval.embedding_model,
          rating:             evaluation.rating,
          feedback:           evaluation.feedback,
          ideal_answer:       evaluation.ideal_answer,
          failure_categories: serialize_categories(evaluation.failure_categories, format),
          evaluator_id:       evaluation.evaluator_id,
          evaluator_role:     evaluation.evaluator_role,
          created_at:         evaluation.created_at&.iso8601
        }
      end

      def answer_for(retrieval)
        text = retrieval.message&.content
        return nil if text.nil?
        text.length > ANSWER_TRUNCATION ? "#{text[0, ANSWER_TRUNCATION - 1]}…" : text
      end

      # CSV cells are flat strings, so categories collapse to a
      # `;`-joined string (avoids the comma-vs-Excel-delimiter trap).
      # JSON keeps them as an array because the consumer can iterate
      # natively. An empty list becomes nil in CSV (renders as a blank
      # cell — semantically "no value" rather than "empty value") and
      # `[]` in JSON, matching what each format's consumers expect.
      def serialize_categories(categories, format)
        cats = Array(categories)
        case format
        when :csv  then cats.empty? ? nil : cats.join(";")
        when :json then cats
        end
      end

      def scope
        apply_filters(
          Curator::Evaluation
            .joins(retrieval: :knowledge_base)
            .includes(retrieval: %i[knowledge_base message])
        )
      end

      def apply_filters(scope)
        f = @filters
        scope = scope.where(curator_knowledge_bases: { slug: f[:kb] })          if f[:kb].present?
        scope = scope.where(rating: f[:rating])                                 if f[:rating].present?
        scope = scope.where(evaluator_role: f[:evaluator_role])                 if f[:evaluator_role].present?
        scope = scope.where(curator_retrievals: { chat_model: f[:chat_model] }) if f[:chat_model].present?
        if f[:embedding_model].present?
          scope = scope.where(curator_retrievals: { embedding_model: f[:embedding_model] })
        end
        if f[:evaluator_id].present?
          needle = ActiveRecord::Base.sanitize_sql_like(f[:evaluator_id])
          scope  = scope.where("curator_evaluations.evaluator_id ILIKE ?", "%#{needle}%")
        end
        if (cats = Array(f[:failure_categories]).reject(&:blank?)).any?
          scope = scope.where("curator_evaluations.failure_categories && ARRAY[?]::varchar[]", cats)
        end
        if (since = parse_date(f[:since]))
          scope = scope.where("curator_evaluations.created_at >= ?", since.beginning_of_day)
        end
        if (before = parse_date(f[:until]))
          scope = scope.where("curator_evaluations.created_at <= ?", before.end_of_day)
        end
        scope
      end

      def parse_date(value)
        return value if value.is_a?(Date) || value.is_a?(Time)
        return nil if value.blank?
        Date.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
