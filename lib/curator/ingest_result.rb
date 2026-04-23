module Curator
  # Return value from Curator.ingest. Binary outcome on the happy path
  # (:created vs :duplicate); :reason is a free-form string reserved for
  # callers that want to explain the outcome (e.g. which hash matched).
  IngestResult = Data.define(:document, :status, :reason) do
    STATUSES = %i[created duplicate].freeze

    def initialize(document:, status:, reason: nil)
      unless STATUSES.include?(status)
        raise ArgumentError,
              "IngestResult status must be one of #{STATUSES.inspect} (got #{status.inspect})"
      end
      super
    end

    def created?   = status == :created
    def duplicate? = status == :duplicate
  end
end
