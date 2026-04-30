module Curator
  class DestroyDocumentJob < ApplicationJob
    # Async destroy lets the controller return immediately when an
    # operator deletes a doc whose chunk/embedding cascade may take
    # multiple seconds. The controller flips status to :deleting (the
    # index already filters those rows) and enqueues this job; the
    # actual destroy + cascade happens out-of-band.
    #
    # `find_by(id:)` makes a doc deleted between enqueue and execution
    # a silent no-op rather than raising RecordNotFound — same pattern
    # as IngestDocumentJob.
    def perform(document_id)
      document = Curator::Document.find_by(id: document_id)
      return unless document

      ActiveRecord::Base.transaction { document.destroy! }
    end
  end
end
