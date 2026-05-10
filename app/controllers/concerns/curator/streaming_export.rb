require "csv"
require "json"

module Curator
  module StreamingExport
    extend ActiveSupport::Concern

    # Stream rows as CSV to `io`. `columns` is an Array of symbols
    # matching the keys the block yields. The block receives one row
    # at a time and must return a Hash with symbol keys.
    def stream_csv(io:, rows:, columns:)
      io.write(CSV.generate_line(columns))
      rows.each do |row|
        io.write(CSV.generate_line(columns.map { |col| yield(row)[col] }))
      end
    end

    # Stream rows as a single JSON array to `io`. The block receives
    # one row at a time and must return a Hash with symbol keys.
    def stream_json(io:, rows:)
      io.write("[")
      first = true
      rows.each do |row|
        io.write(",") unless first
        io.write(JSON.generate(yield(row).transform_keys(&:to_s)))
        first = false
      end
      io.write("]")
    end
  end
end
