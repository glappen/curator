module Curator
  module Documents
    # Ingest one batch of files into a knowledge base. Wraps each file's
    # `Curator.ingest` call so a per-file ingest error (bad MIME,
    # oversized blob, validation collision) doesn't abort the rest. Used
    # by `DocumentsController#create` to keep the controller a thin
    # parameter-massaging + flash-formatting layer.
    class IngestBatch
      Result = Data.define(:counts, :failures)

      # Known per-file ingest failures: countable and recoverable. Anything
      # outside this set (DB outage, OOM, programming error) propagates so
      # operators see the real outage instead of N silently-classified rows.
      RECOVERABLE_ERRORS = [
        Curator::Error,
        ActiveRecord::RecordInvalid
      ].freeze

      def self.call(...) = new(...).call

      def initialize(kb:, files:)
        @kb    = kb
        @files = files
      end

      def call
        counts   = { created: 0, duplicate: 0, failed: 0 }
        failures = []

        @files.each do |file|
          result = ingest_one(file)
          counts[result.status] += 1
          failures << result.reason if result.failed? && result.reason
        end

        Result.new(counts: counts, failures: failures)
      end

      private

      def ingest_one(file)
        Curator.ingest(file, knowledge_base: @kb)
      rescue *RECOVERABLE_ERRORS => e
        Curator::IngestResult.new(
          document: nil,
          status:   :failed,
          reason:   "#{e.class}: #{e.message}"
        )
      end
    end
  end
end
