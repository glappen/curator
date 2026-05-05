require "rails_helper"

RSpec.describe "Curator::Documents", type: :request do
  include ActiveJob::TestHelper

  let(:knowledge_base) do
    create(:curator_knowledge_base, slug: "kb-docs", name: "KB Docs")
  end

  describe "GET /curator/kbs/:slug/documents" do
    it "renders the upload form and the documents table" do
      doc = create(:curator_document,
                   knowledge_base: knowledge_base,
                   title:          "alpha.md",
                   mime_type:      "text/markdown",
                   byte_size:      2_048)

      get "/curator/kbs/kb-docs/documents"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include('data-controller="curator--drag-drop"')
      expect(body).to include('data-curator--drag-drop-target="dropzone"')
      expect(body).to include('data-curator--drag-drop-target="input"')
      expect(body).to include('name="files[]"')
      expect(body).to include(doc.title)
      # Row actions render with the project's `.btn` design-system classes,
      # not Bootstrap-style `.button`. Locks against future class drift —
      # mismatched names would render unstyled buttons in the admin UI.
      expect(body).to match(/class="btn btn--sm"[^>]*>\s*Re-ingest/)
      expect(body).to match(/class="btn btn--sm btn--danger"[^>]*>\s*Delete/)
    end

    it "hides documents in the :deleting status" do
      visible = create(:curator_document, knowledge_base: knowledge_base, title: "visible.md")
      hidden  = create(:curator_document,
                       knowledge_base: knowledge_base,
                       title:          "hidden.md",
                       status:         :deleting)

      get "/curator/kbs/kb-docs/documents"

      expect(response.body).to     include(visible.title)
      expect(response.body).not_to include(hidden.title)
    end

    it "renders the empty state when no documents exist" do
      get "/curator/kbs/kb-docs/documents"

      expect(response.body).to include("No documents yet.")
    end

    it "404s on an unknown KB slug" do
      get "/curator/kbs/missing/documents"
      expect(response).to have_http_status(:not_found)
    end

    describe "pagination" do
      before do
        26.times do |i|
          create(:curator_document,
                 knowledge_base: knowledge_base,
                 title:          format("doc-%02d.md", i))
        end
      end

      it "shows 25 docs on page 1 and renders pagination controls" do
        get "/curator/kbs/kb-docs/documents"

        expect(response.body.scan(/<tr id="document_/).size).to eq(25)
        expect(response.body).to include("pagination")
        expect(response.body).to include("page=2")
      end

      it "shows the remaining 1 doc on page 2" do
        get "/curator/kbs/kb-docs/documents", params: { page: 2 }

        expect(response.body.scan(/<tr id="document_/).size).to eq(1)
      end

      it "clamps per > 100 down to 100" do
        get "/curator/kbs/kb-docs/documents", params: { per: 200 }

        expect(response.body.scan(/<tr id="document_/).size).to eq(26)
        # All rows fit on one page once per is clamped to 100, so the
        # pagination nav should be absent.
        expect(response.body).not_to match(/class="pagination"/)
      end
    end

    # Locks in the grouped-aggregate preload: chunk_counts come from one
    # GROUP BY per request, not one COUNT(*) per row. Mirrors Phase 3's
    # KB-card N+1 guard.
    it "fetches chunk counts in a single grouped aggregate" do
      3.times do |i|
        doc = create(:curator_document, knowledge_base: knowledge_base, title: "doc-#{i}.md")
        2.times { create(:curator_chunk, document: doc) }
      end

      get "/curator/kbs/kb-docs/documents" # warm the schema cache

      queries = []
      callback = ->(_, _, _, _, payload) {
        queries << payload[:sql] if payload[:sql].is_a?(String)
      }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        get "/curator/kbs/kb-docs/documents"
      end

      chunk_count_queries = queries.grep(/curator_chunks/i).grep(/count/i)
      expect(chunk_count_queries.size).to eq(1),
        "expected exactly one chunks COUNT query, got #{chunk_count_queries.size}:\n" +
        chunk_count_queries.join("\n")
      expect(chunk_count_queries.first).to match(/group by/i)
    end
  end

  describe "POST /curator/kbs/:slug/documents" do
    let(:fixture_dir) { Curator::Engine.root.join("spec/fixtures") }

    def upload(name, type)
      fixture_file_upload(fixture_dir.join(name), type)
    end

    it "ingests a single file and renders a summary flash" do
      expect {
        post "/curator/kbs/kb-docs/documents",
             params: { files: [ upload("sample.md", "text/markdown") ] }
      }.to change(knowledge_base.documents, :count).by(1)

      expect(response).to redirect_to("/curator/kbs/kb-docs/documents")
      follow_redirect!
      expect(response.body).to include("1 ingested, 0 duplicate, 0 failed.")
    end

    it "ingests several files in one batch and aggregates the summary" do
      expect {
        post "/curator/kbs/kb-docs/documents", params: {
          files: [
            upload("sample.md",   "text/markdown"),
            upload("sample.csv",  "text/csv"),
            upload("sample.html", "text/html")
          ]
        }
      }.to change(knowledge_base.documents, :count).by(3)

      follow_redirect!
      expect(response.body).to include("3 ingested, 0 duplicate, 0 failed.")
    end

    it "counts duplicates separately from new ingests" do
      knowledge_base # instantiate the lazy let

      post "/curator/kbs/kb-docs/documents",
           params: { files: [ upload("sample.md", "text/markdown") ] }

      expect {
        post "/curator/kbs/kb-docs/documents",
             params: { files: [ upload("sample.md", "text/markdown") ] }
      }.not_to change(knowledge_base.documents, :count)

      follow_redirect!
      expect(response.body).to include("0 ingested, 1 duplicate, 0 failed.")
    end

    it "keeps the batch going when a single file fails (e.g. oversize)" do
      original_max = Curator.config.max_document_size
      # Cap at sample.csv's size (88 bytes); sample.md (152 bytes) trips
      # the limit. The batch must still ingest the small file.
      Curator.config.max_document_size = 100

      begin
        expect {
          post "/curator/kbs/kb-docs/documents", params: {
            files: [
              upload("sample.csv", "text/csv"),
              upload("sample.md",  "text/markdown")
            ]
          }
        }.to change(knowledge_base.documents, :count).by(1)
      ensure
        Curator.config.max_document_size = original_max
      end

      follow_redirect!
      body = response.body
      expect(body).to include("1 ingested, 0 duplicate, 1 failed.")
      expect(body).to include("FileTooLargeError")
    end

    it "redirects with an alert when no files are submitted" do
      knowledge_base # instantiate the lazy let

      post "/curator/kbs/kb-docs/documents", params: { files: [] }

      expect(response).to redirect_to("/curator/kbs/kb-docs/documents")
      follow_redirect!
      expect(response.body).to include("No files were selected.")
    end
  end

  describe "DELETE /curator/kbs/:slug/documents/:id" do
    it "flips status to :deleting, enqueues DestroyDocumentJob, and redirects" do
      doc = create(:curator_document, knowledge_base: knowledge_base, status: :complete)

      expect {
        delete "/curator/kbs/kb-docs/documents/#{doc.id}"
      }.to have_enqueued_job(Curator::DestroyDocumentJob).with(doc.id)

      expect(doc.reload.status).to eq("deleting")
      expect(response).to redirect_to("/curator/kbs/kb-docs/documents")
      follow_redirect!
      expect(response.body).to include("Document queued for deletion.")
    end

    it "removes the row from the database after the job runs" do
      doc = create(:curator_document, knowledge_base: knowledge_base, status: :complete)

      perform_enqueued_jobs do
        delete "/curator/kbs/kb-docs/documents/#{doc.id}"
      end

      expect(Curator::Document.find_by(id: doc.id)).to be_nil
    end

    it "404s on an unknown document id" do
      delete "/curator/kbs/kb-docs/documents/999999"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /curator/kbs/:slug/documents/:id/reingest" do
    it "calls Curator.reingest with the document and flips status back to :pending" do
      doc = create(:curator_document, knowledge_base: knowledge_base, status: :complete)
      # Match by id (not by AR identity) — the controller looks the doc up
      # fresh, so the instance Curator.reingest receives is a different
      # object from `doc`.
      expect(Curator).to receive(:reingest)
        .with(have_attributes(id: doc.id))
        .and_call_original

      post "/curator/kbs/kb-docs/documents/#{doc.id}/reingest"

      expect(doc.reload.status).to eq("pending")
      expect(response).to redirect_to("/curator/kbs/kb-docs/documents")
      follow_redirect!
      expect(response.body).to include("Re-ingesting")
    end

    it "404s on an unknown document id" do
      post "/curator/kbs/kb-docs/documents/999999/reingest"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "broadcasts on destroy + reingest", :broadcasts do
    let(:stream) do
      Turbo::StreamsChannel.send(:stream_name_from, [ knowledge_base, "documents" ])
    end

    it "broadcasts the row replace when destroy flips status to :deleting" do
      doc = create(:curator_document, knowledge_base: knowledge_base, status: :complete)

      expect {
        delete "/curator/kbs/kb-docs/documents/#{doc.id}"
      }.to have_broadcasted_to(stream)
    end

    it "broadcasts the row remove after the destroy job runs" do
      doc = create(:curator_document, knowledge_base: knowledge_base, status: :complete)

      # Two messages: the controller's :deleting flip (replace) and the
      # job's `destroy!` (remove). The remove is the load-bearing one
      # for any other connected client to see the row vanish.
      #
      # Sequencing matters: `perform_enqueued_jobs` is called *outside*
      # the request, not as a block-form wrapper. The block form sets
      # `perform_enqueued_jobs = true` on the test adapter, which causes
      # `perform_later` to inline the job — and since the controller now
      # wraps `update!(:deleting)` + `perform_later` in a transaction,
      # the inlined `destroy!` would run *before* the transaction commits
      # and would suppress the :deleting flip's `after_update_commit`
      # broadcast. Calling `perform_enqueued_jobs` after the request
      # gets the production sequencing: request transaction commits
      # (replace fires), then the job runs (remove fires).
      expect {
        delete "/curator/kbs/kb-docs/documents/#{doc.id}"
        perform_enqueued_jobs
      }.to have_broadcasted_to(stream).twice
    end

    it "broadcasts the row replace on reingest's status flip" do
      doc = create(:curator_document, knowledge_base: knowledge_base, status: :complete)

      expect {
        post "/curator/kbs/kb-docs/documents/#{doc.id}/reingest"
      }.to have_broadcasted_to(stream)
    end
  end

  describe "broadcasts on the per-KB documents stream", :broadcasts do
    # `Turbo::Streams::StreamName#stream_name_from` is the canonical
    # builder; calling it via `send` is brittler than reading docs but
    # breaks loudly if turbo-rails ever changes the signature, instead
    # of silently mismatching a hand-rolled string.
    let(:stream) do
      Turbo::StreamsChannel.send(:stream_name_from, [ knowledge_base, "documents" ])
    end

    it "appends a row when a document is created" do
      expect {
        create(:curator_document, knowledge_base: knowledge_base)
      }.to have_broadcasted_to(stream)
    end

    it "replaces the row when a document's status changes" do
      doc = create(:curator_document, knowledge_base: knowledge_base, status: :pending)

      expect {
        doc.update!(status: :complete)
      }.to have_broadcasted_to(stream)
    end

    it "removes the row when a document is destroyed" do
      doc = create(:curator_document, knowledge_base: knowledge_base)

      expect {
        doc.destroy!
      }.to have_broadcasted_to(stream)
    end
  end

  describe "GET /curator/kbs/:slug/documents/:id" do
    let(:document) do
      create(:curator_document, knowledge_base: knowledge_base, title: "show.md")
    end

    def chunk_path(doc, n: 1)
      "/curator/kbs/#{knowledge_base.slug}/documents/#{doc.id}?page=#{n}"
    end

    it "renders the metadata header with X-of-Y embedded counter" do
      embedded = create(:curator_chunk, document: document, sequence: 0)
      _missing = create(:curator_chunk, document: document, sequence: 1)
      create(:curator_embedding,
             chunk:           embedded,
             embedding_model: knowledge_base.embedding_model)

      get "/curator/kbs/#{knowledge_base.slug}/documents/#{document.id}"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("show.md")
      expect(body).to include("1 of 2") # 1 of 2 embedded
    end

    it "renders embedded vs missing badges per chunk" do
      c1 = create(:curator_chunk, document: document, sequence: 0)
      _c2 = create(:curator_chunk, document: document, sequence: 1)
      create(:curator_embedding,
             chunk:           c1,
             embedding_model: knowledge_base.embedding_model)

      get "/curator/kbs/#{knowledge_base.slug}/documents/#{document.id}"

      body = response.body
      # Both badges present — at least one embedded, at least one missing.
      expect(body).to match(/class="badge badge--embedded"/)
      expect(body).to match(/class="badge badge--missing"/)
    end

    it "treats embeddings from a stale model as missing" do
      chunk = create(:curator_chunk, document: document, sequence: 0)
      create(:curator_embedding,
             chunk:           chunk,
             embedding_model: "some-other-model")

      get "/curator/kbs/#{knowledge_base.slug}/documents/#{document.id}"

      body = response.body
      expect(body).to include("0 of 1")
      expect(body).to match(/class="badge badge--missing"/)
    end

    it "renders the stage_error inline when the document is failed" do
      document.update!(status: :failed, stage_error: "ExtractionError: bad PDF")

      get "/curator/kbs/#{knowledge_base.slug}/documents/#{document.id}"

      expect(response.body).to include("ExtractionError: bad PDF")
      expect(response.body).to include("flash--alert")
    end

    it "renders the model + dim + embedded-at strip on embedded chunks" do
      chunk = create(:curator_chunk, document: document, sequence: 0)
      create(:curator_embedding,
             chunk:           chunk,
             embedding_model: knowledge_base.embedding_model)

      get "/curator/kbs/#{knowledge_base.slug}/documents/#{document.id}"

      body = response.body
      expect(body).to include(knowledge_base.embedding_model)
      expect(body).to include("#{Curator::Embedding.dimension}d")
      # `to_fs(:short)` is `"%d %b %H:%M"` — the day-of-month digit is the
      # cheapest stable substring to assert without coupling to wall clock.
      expect(body).to match(/embedded \d{1,2} [A-Z][a-z]{2}/)
    end

    it "renders the empty-chunks copy when the document has no chunks" do
      get "/curator/kbs/#{knowledge_base.slug}/documents/#{document.id}"

      expect(response.body).to include("No chunks yet")
      # The chunks-list container is suppressed entirely on the empty
      # branch — no orphan heading or stray pagination nav.
      expect(response.body).not_to match(/class="chunks-list"/)
    end

    describe "pagination" do
      before do
        26.times do |i|
          create(:curator_chunk, document: document, sequence: i)
        end
      end

      it "shows 25 chunks on page 1 by default" do
        get chunk_path(document, n: 1)

        expect(response.body.scan(/class="chunk-card"/).size).to eq(25)
        expect(response.body).to include("page=2")
      end

      it "shows the trailing chunk on page 2" do
        get chunk_path(document, n: 2)

        expect(response.body.scan(/class="chunk-card"/).size).to eq(1)
      end

      it "clamps page=0 up to page 1" do
        get chunk_path(document, n: 0)

        expect(response.body.scan(/class="chunk-card"/).size).to eq(25)
      end

      it "clamps page > total pages down to the last page" do
        get chunk_path(document, n: 999)

        # 26 chunks / 25 per = 2 pages; page 2 has 1 chunk.
        expect(response.body.scan(/class="chunk-card"/).size).to eq(1)
      end

      it "clamps per > 100 down to 100" do
        get "/curator/kbs/#{knowledge_base.slug}/documents/#{document.id}?per=200"

        expect(response.body.scan(/class="chunk-card"/).size).to eq(26)
      end
    end
  end

  describe "broadcasts on the per-document stream", :broadcasts do
    let(:document) { create(:curator_document, knowledge_base: knowledge_base) }
    let(:chunk)    { create(:curator_chunk, document: document) }
    let(:stream) do
      Turbo::StreamsChannel.send(:stream_name_from, document)
    end

    it "replaces the header turbo-frame when an embedding is created" do
      chunk # create chunk first so the embedding has a parent

      expect {
        create(:curator_embedding,
               chunk:           chunk,
               embedding_model: knowledge_base.embedding_model)
      }.to have_broadcasted_to(stream)
    end

    it "replaces the header turbo-frame when an embedding is destroyed" do
      embedding = create(:curator_embedding,
                         chunk:           chunk,
                         embedding_model: knowledge_base.embedding_model)

      expect { embedding.destroy! }.to have_broadcasted_to(stream)
    end

    it "replaces the header turbo-frame when the document status changes" do
      document # create

      expect {
        document.update!(status: :complete)
      }.to have_broadcasted_to(stream)
    end
  end
end
