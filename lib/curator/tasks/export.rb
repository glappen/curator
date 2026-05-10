require "csv"
require "json"

module Curator
  module Tasks
    # Shared rake-task streaming for `curator:retrievals:export` and
    # `curator:evaluations:export`. Dispatches to CSV or JSON based on
    # the caller-supplied format, walks the ActiveRecord `scope` with
    # `find_each`, and yields each record to the block for row shaping.
    module Export
      module_function

      # @param format [String] "csv" or "json"
      # @param io [IO] destination stream (e.g. `$stdout`)
      # @param scope [ActiveRecord::Relation]
      # @param columns [Array<Symbol>] column keys for CSV header / row
      #   ordering (ignored by JSON)
      def run(format:, io:, scope:, columns:)
        case format.to_s
        when "csv"  then stream_csv(io, scope, columns) { |r| yield(r) }
        when "json" then stream_json(io, scope)        { |r| yield(r) }
        else
          raise ArgumentError, "unknown format: #{format.inspect}"
        end
      end

      def stream_csv(io, scope, columns)
        io.write(CSV.generate_line(columns))
        scope.find_each(order: :desc) do |row|
          io.write(CSV.generate_line(columns.map { |col| yield(row)[col] }))
        end
      end
      private_class_method :stream_csv

      def stream_json(io, scope)
        io.write("[")
        first = true
        scope.find_each(order: :desc) do |row|
          io.write(",") unless first
          io.write(JSON.generate(yield(row).transform_keys(&:to_s)))
          first = false
        end
        io.write("]")
      end
      private_class_method :stream_json
    end
  end
end
