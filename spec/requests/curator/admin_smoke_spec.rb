require "rails_helper"

# End-to-end smoke for the M5 admin surface. Drives a single operator
# story top-to-bottom against the dummy app:
#
#   empty `/curator` → create KB → landing card → multi-file upload
#   → ingest+embed → docs index → chunk inspector → reingest → destroy
#
# Tagged `:broadcasts` so the per-example suppression configured in
# spec/support/turbo_helpers.rb stays out of the way — turbo broadcasts
# at key transitions are part of what this spec asserts.
RSpec.describe "Curator admin end-to-end smoke", :broadcasts, type: :request do
  include ActiveJob::TestHelper

  let(:fixture_dir) { Curator::Engine.root.join("spec/fixtures") }

  def upload(name, type)
    fixture_file_upload(fixture_dir.join(name), type)
  end

  before { Curator.configure { |c| c.extractor = :basic } }
  after  { Curator.reset_config! }

  it "drives the full admin flow from empty state through destroy" do
    # 1. Empty `/curator` renders the onboarding panel, no cards grid.
    get "/curator"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Create your first knowledge base")
    expect(response.body).not_to include(%(id="curator_knowledge_bases_cards"))

    # 2. Create a KB. KB-create broadcasts a prepend onto the index stream.
    expect {
      post "/curator/kbs", params: {
        knowledge_base: {
          name:            "Smoke",
          slug:            "smoke",
          description:     "M5 smoke KB",
          embedding_model: "text-embedding-3-small",
          chat_model:      "gpt-5-mini"
        }
      }
    }.to have_broadcasted_to("curator_knowledge_bases_index")

    expect(response).to redirect_to("/curator/kbs/smoke")
    kb = Curator::KnowledgeBase.find_by!(slug: "smoke")

    # 3. Landing now renders the card (no longer the empty state).
    get "/curator"
    expect(response.body).to include(%(id="card_knowledge_base_#{kb.id}"))
    expect(response.body).to include(%(href="/curator/kbs/smoke/documents"))
    expect(response.body).not_to include("Create your first knowledge base")

    # 4. Upload three files. Block-form `perform_enqueued_jobs` runs
    #    each ingest + its chained EmbedChunksJob inline, so by the
    #    time the request returns every document is at terminal
    #    status. RubyLLMStubs.stub_embed (default in rails_helper)
    #    returns deterministic vectors, so embeddings land on every
    #    chunk without WebMock wiring. We assert at least one
    #    broadcast on the per-KB stream during the request — the
    #    precise callback counts already live in documents_spec.rb.
    docs_stream = Turbo::StreamsChannel.send(:stream_name_from, [ kb, "documents" ])

    expect {
      perform_enqueued_jobs do
        post "/curator/kbs/smoke/documents", params: {
          files: [
            upload("sample.md",   "text/markdown"),
            upload("sample.csv",  "text/csv"),
            upload("sample.html", "text/html")
          ]
        }
      end
    }.to change(kb.documents, :count).by(3)
       .and have_broadcasted_to(docs_stream).at_least(:once)

    follow_redirect!
    expect(response.body).to include("3 ingested, 0 duplicate, 0 failed.")

    # Order by `id` rather than `created_at` — same-millisecond
    # timestamps on fast machines would otherwise leave the
    # `sample.md` lookup below order-dependent.
    documents = kb.documents.reload.order(:id)
    documents.each do |doc|
      expect(doc.status).to eq("complete"),
        "expected #{doc.title} to reach :complete, got #{doc.status} (#{doc.stage_error})"
      expect(doc.chunks.count).to be >= 1
      embedded = Curator::Embedding.where(chunk: doc.chunks).count
      expect(embedded).to eq(doc.chunks.count)
    end

    # 5. Docs index shows all three rows with terminal status badges.
    get "/curator/kbs/smoke/documents"
    body = response.body
    documents.each { |doc| expect(body).to include(doc.title) }
    expect(body.scan(/<tr id="document_/).size).to eq(3)
    # Status renders via the badge--success styling for `:complete`.
    expect(body.scan(/class="badge badge--success"/).size).to eq(3)

    # 6. Chunk inspector for the markdown doc: chunks visible, all
    #    embedded, X-of-Y reflects that.
    md_doc = documents.find { |d| d.title == "sample.md" }
    get "/curator/kbs/smoke/documents/#{md_doc.id}"
    expect(response).to have_http_status(:ok)
    inspector = response.body
    expect(inspector).to include("sample.md")
    expect(inspector).to include("#{md_doc.chunks.count} of #{md_doc.chunks.count}")
    expect(inspector).to match(/class="badge badge--embedded"/)
    expect(inspector).not_to match(/class="badge badge--missing"/)

    # 7. Re-ingest the markdown doc. Drain jobs in the same pass so
    #    the doc returns to :complete with a fresh chunk set.
    original_chunk_ids = md_doc.chunks.pluck(:id)

    expect {
      perform_enqueued_jobs do
        post "/curator/kbs/smoke/documents/#{md_doc.id}/reingest"
      end
    }.to have_broadcasted_to(docs_stream).at_least(:once)

    md_doc.reload
    expect(md_doc.status).to eq("complete")
    new_chunk_ids = md_doc.chunks.pluck(:id)
    expect(new_chunk_ids).not_to be_empty
    expect(new_chunk_ids & original_chunk_ids).to be_empty

    # 8. Destroy the markdown doc. The controller flips :deleting
    #    (one broadcast: replace) and enqueues DestroyDocumentJob;
    #    running the job emits the row remove broadcast and the row
    #    vanishes from the database. `at_least(:twice)` keeps the
    #    smoke check tolerant — `documents_spec.rb` pins the exact
    #    count.
    expect {
      delete "/curator/kbs/smoke/documents/#{md_doc.id}"
      perform_enqueued_jobs
    }.to have_broadcasted_to(docs_stream).at_least(:twice)

    expect(Curator::Document.find_by(id: md_doc.id)).to be_nil

    # Index no longer renders the destroyed row.
    get "/curator/kbs/smoke/documents"
    expect(response.body).not_to include("sample.md")
    expect(response.body.scan(/<tr id="document_/).size).to eq(2)
  end
end
