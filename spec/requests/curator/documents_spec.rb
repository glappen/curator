require "rails_helper"

RSpec.describe "Curator::Documents", type: :request do
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
end
