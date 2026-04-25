module Curator
  # Return value from Curator.ingest and Curator.ingest_directory.
  # `:created` / `:duplicate` are the happy paths from a single-file
  # ingest; `:failed` only surfaces from the per-file rescue inside
  # `ingest_directory`, so a directory walk can keep going after one bad
  # file. `:reason` is a free-form string ("ExtractionError: empty file")
  # used by the rake task summary; `:document` is nil when the failure
  # happened before any row was created.
  IngestResult = Data.define(:document, :status, :reason) do
    STATUSES = %i[created duplicate failed].freeze

    def initialize(document: nil, status:, reason: nil)
      unless STATUSES.include?(status)
        raise ArgumentError,
              "IngestResult status must be one of #{STATUSES.inspect} (got #{status.inspect})"
      end
      super
    end

    def created?   = status == :created
    def duplicate? = status == :duplicate
    def failed?    = status == :failed
  end
end
