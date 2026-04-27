# Curator — High-Level Product Spec

## Concept

A Rails engine that adds production-ready Retrieval Augmented Generation (RAG)
capabilities to any Rails 7+ application. Drop it in like ActiveAdmin: mount it,
run the generator, and your app gains a knowledge base, semantic search, Q&A over
documents, a polished admin UI, and a clean API for building your own branded
frontend.

Curator targets two audiences simultaneously. Developers get a well-designed
service object and REST API layer for building end-user-facing features. Non-technical
users — SMEs, content managers, domain experts — get a responsive admin UI for
managing the knowledge base and evaluating AI responses without writing a line of code.

### Relationship to RubyLLM

Curator is built on top of RubyLLM rather than reimplementing LLM interaction
from scratch. RubyLLM owns conversation persistence (chats, messages, tool calls)
and the LLM provider abstraction. This engine owns the RAG layer: document ingestion,
chunking, embeddings, retrieval, and evaluation. The two layers are wired together
so retrieval context is injected into RubyLLM chat sessions automatically.

This division means Curator inherits RubyLLM's full provider support (OpenAI,
Anthropic, Google, Ollama, and more) and its streaming architecture without
additional work.

### Knowledge Bases

Curator organizes documents into named **Knowledge Bases** — independent,
queryable silos of domain knowledge. A host app might have a "Product Documentation"
knowledge base, a "Legal Policies" knowledge base, and a "Support Tickets" knowledge
base, each with its own documents, configuration, and eval queue. Knowledge bases
can be queried independently or in combination. This is the abstraction that turns
Curator from a RAG library into a knowledge management platform.

---

## Core Capabilities

### Knowledge Bases

- Documents are organized into named Knowledge Bases (e.g., "Product Docs", "Legal Policies")
- Each Knowledge Base has its own:
  - Document collection
  - Chunking configuration (chunk size, overlap)
  - Embedding model
  - Similarity threshold
  - System prompt / persona
  - Eval queue and golden dataset
- Knowledge Bases are queryable independently or in combination
- Managed via the admin UI or programmatically
- A default Knowledge Base is created on install so simple use cases require
  no additional configuration

### Document Ingestion

- Supported formats at launch: plain text, Markdown, PDF, DOCX, HTML, CSV
- Two ingestion paths:
  - File upload through the admin UI
  - Programmatic API (`Curator.ingest(file)`, `Curator.ingest_directory(path)`)
- Text extraction uses a **pluggable extractor adapter**, configurable per
  deployment:
  - `:kreuzberg` (default) — Rust-core gem with native Ruby bindings, handles
    90+ formats, built-in OCR, document hierarchy detection. Preferred when
    available.
  - `:basic` (fallback) — `pdf-reader` for PDFs + `ruby-docx` for DOCX.
    Battle-tested, no native dependencies, covers the common case without
    Kreuzberg.
  ```ruby
  Curator.configure do |config|
    config.extractor = :kreuzberg  # or :basic
  end
  ```
- All extractor adapters conform to a narrow internal interface, returning a
  common `ExtractionResult` value object. The rest of the pipeline only ever
  sees `ExtractionResult` — it never knows which extractor produced it:
  ```ruby
  module Curator
    module Extractors
      class Kreuzberg
        def extract(file_path)
          result = ::Kreuzberg.extract_file_sync(file_path)
          ExtractionResult.new(
            content: result.content,
            mime_type: result.mime_type,
            pages: result.pages
          )
        end
      end
    end
  end
  ```
- `ExtractionResult` is the contract between the extractor and the chunker.
  Required fields: `content` (full extracted text), `mime_type`, `pages`
  (array of page objects with text and page number). Swapping extractors is
  a contained change with no impact on the chunking or embedding pipeline.
- Binary files stored via Active Storage — keeps large files out of the database
  while providing CDN-backed retrieval; S3, Cloudflare R2, and local disk all
  supported via standard Active Storage configuration
- Documents are chunked, embedded, and stored asynchronously via ActiveJob
- Ingestion status tracked per document (pending, processing, complete, failed)
- Empty extraction detected and surfaced as a warning in the admin UI rather
  than silently ingesting an empty document

### Chunking Strategy

- When using the Kreuzberg extractor: structure-aware chunking leverages document
  hierarchy detection (title, section, subsection, paragraph) to chunk at
  semantically meaningful boundaries; each chunk is mapped back to its source
  page with byte-accurate offsets for precise citations
- When using the basic extractor: paragraph-aware chunking accumulates paragraphs
  up to a token ceiling before starting a new chunk, preserving semantic coherence
- Fixed-length chunking with overlap available as an alternative for structured
  or unstructured content
- Chunk size, overlap, and boundary strategy configurable per Knowledge Base
- Chunk Inspector in the admin UI makes it easy to diagnose chunking issues
  before they affect retrieval quality

### Retrieval and Q&A

- Semantic similarity search via pgvector (PostgreSQL extension)
- Q&A over documents with retrieved chunks injected as context into RubyLLM
  chat sessions
- Queries scoped to a single Knowledge Base or across multiple
- Both use cases supported equally: chat-style Q&A and semantic search
- **Hybrid search**: semantic vector search combined with PostgreSQL full-text
  keyword search, merged via Reciprocal Rank Fusion (`Neighbor::Reranking.rrf()`)
  for better retrieval quality across a wider range of query types
- **Citation system**: retrieved chunks are numbered and injected with citation
  markers (`[1]`, `[2]`, etc.); the LLM is prompted to reference these markers;
  Curator returns structured source metadata (chunk text, document name, page
  number, source URL) alongside the answer so host apps can render clickable
  citation UI
- Advanced usage: retrieval exposed as a RubyLLM Tool, allowing the LLM to
  decide when to retrieve rather than forcing retrieval on every query

### Streaming Responses

- Streaming supported in v1 via RubyLLM's native Turbo Streams integration
- Host app controllers use RubyLLM's `acts_as_chat` / `acts_as_message` helpers
  with `broadcasts_to` for real-time UI updates
- The query testing console in the admin UI streams responses live, showing
  retrieved chunks alongside the streaming answer in real time

### LLM Provider Support

- Powered by RubyLLM, providing support for OpenAI, Anthropic, Google, Ollama,
  and other providers out of the box
- Embedding model and chat model configurable independently
- Provider and model switchable per environment via the initializer
- Per-chat API key overrides supported via RubyLLM's context system, enabling
  multi-tenant host apps to use customer-specific credentials
- Specialized embedding providers (e.g., Voyage AI) supported independently of
  the chat LLM — retrieval-optimized embedding models can meaningfully outperform
  general-purpose ones and are worth considering for production deployments

### Vector Storage

- pgvector only — no external vector database required
- Keeps infrastructure simple: one PostgreSQL database handles everything
- Variable-length embedding support for different models
- Vector similarity search implemented via the `neighbor` gem, which wraps
  pgvector's operators in idiomatic ActiveRecord:
  ```ruby
  Curator::Embedding.nearest_neighbors(:embedding, query_vector, distance: "cosine").limit(5)
  ```
- HNSW and IVFFlat approximate indexes supported via neighbor for production
  performance as knowledge bases grow
- Hybrid search (semantic + keyword via PostgreSQL tsvector) available using
  `Neighbor::Reranking.rrf()` for Reciprocal Rank Fusion — improves retrieval
  quality for short or highly specific queries that pure vector search handles
  poorly

### Background Processing

- All embedding and ingestion jobs run via ActiveJob
- Compatible with any ActiveJob backend: Sidekiq, GoodJob, Solid Queue, etc.
- Job status surfaced in the admin UI

---

## Admin UI

Built with Tailwind CSS, daisyUI, and Hotwire (Turbo + Stimulus). Responsive and
polished enough for non-technical users. Mounted at a configurable path (default:
`/curator`).

The admin UI has a top-level Knowledge Base switcher — all sections below operate
within the context of the selected Knowledge Base.

### Sections

**Knowledge Base Management**
- Create, rename, and delete Knowledge Bases
- Configure per-KB settings: chunk size, overlap, embedding model, similarity
  threshold, and system prompt
- View summary stats per KB: document count and chunk count

**Document Management**
- Upload documents via drag-and-drop or file picker
- View all documents with ingestion status, chunk count, and metadata
- Delete documents and trigger re-ingestion

**Chunk Inspector**
- Browse the chunks generated from any document
- View chunk text, token count, and embedding metadata
- Useful for diagnosing chunking strategy issues

**Query Testing Console**
- Type any query and see exactly what happens:
  - Which chunks were retrieved and their similarity scores
  - The assembled prompt sent to the LLM
  - The LLM's response, streamed live via Turbo Streams
- Retrieved chunks and the streaming response displayed side by side
- Tweak parameters (chunk count, similarity threshold, prompt template)
  and re-run live
- The key developer tool for tuning retrieval quality

**Response Evaluation (Evals)**
- SMEs can review queries and responses logged from production, scoped per KB
- Each evaluation captures:
  - Thumbs up / thumbs down rating
  - Free-text feedback
  - The ideal answer (for golden dataset construction)
- Evaluated responses and ideal answers are stored and exportable as CSV or JSON

---

## Authentication

Curator does not impose its own authentication. Instead it provides a
configuration hook the host app plugs its own auth into:

```ruby
# config/initializers/curator.rb
Curator.configure do |config|
  config.authenticate_with do
    redirect_to main_app.login_path unless current_user&.admin?
  end
end
```

This follows the pattern used by tools like Sidekiq Web and Resque Web, keeping
Curator agnostic to the host app's auth strategy (Devise, Clearance, custom, etc.).

---

## Host App Integration

### Service Objects

```ruby
# Query a specific knowledge base
result = Curator.ask("What is our refund policy?", knowledge_base: :support)
result[:answer]          # LLM response
result[:sources]         # Retrieved chunks with scores
result[:context_count]   # Number of chunks used

# Query across multiple knowledge bases
result = Curator.ask("What do we know about X?", knowledge_bases: [:support, :legal])

# Semantic search within a knowledge base
results = Curator.retrieve("refund policy", knowledge_base: :legal, limit: 10, threshold: 0.7)

# Ingest into a specific knowledge base
Curator.ingest(file, knowledge_base: :support)

# Omitting knowledge_base uses the default KB
result = Curator.ask("What is our refund policy?")
```

### Streaming via RubyLLM

For streaming responses in the host app's branded frontend, Curator provides
a configured RubyLLM chat instance with RAG context pre-injected:

```ruby
# Returns a RubyLLM chat with retrieved context already in the system prompt
chat = Curator.chat_for("What is our refund policy?", context_limit: 5)

# Host app streams using standard RubyLLM / Turbo Streams pattern
chat.ask(params[:question]) do |chunk|
  assistant_message.broadcast_append_chunk(chunk.content)
end
```

### REST API

Curator mounts JSON endpoints the host app's frontend can call directly:

```
POST /curator/api/query               # Q&A endpoint (non-streaming)
GET  /curator/api/retrieve            # Retrieval endpoint (hits only, no LLM)
POST /curator/api/stream              # Streaming Q&A via Turbo Streams

# All endpoints accept an optional knowledge_base param
POST /curator/api/query?knowledge_base=support
POST /curator/api/query               # uses default KB if omitted
```

All endpoints return consistent JSON with answer, sources, knowledge base, and metadata.

---

## Install Experience

The install generator runs RubyLLM's own generator as a dependency, then
scaffolds the RAG-specific layer on top:

```bash
rails generate curator:install
```

This scaffolds:
- RubyLLM's Chat, Message, ToolCall, and Model tables (via `ruby_llm:install`)
- `config/initializers/curator.rb` with annotated configuration options
- Migrations for Curator's own tables (see Database Schema below)
- A sample `KnowledgeController` showing how to wire service objects and
  streaming into a host app controller
- Mount instruction added to `config/routes.rb` automatically

---

## Database Schema

### Curator-owned tables (prefixed `curator_`)

- `curator_knowledge_bases` — name, description, slug, and per-KB configuration
  (chunk size, overlap, embedding model, similarity threshold, system prompt)
- `curator_documents` — document metadata, ingestion status, source path, FK to knowledge base
- `curator_chunks` — chunked text with token counts and position metadata
- `curator_embeddings` — vector embeddings linked to chunks, with model tracking
- `curator_retrievals` — query log with retrieved chunks, scores, timing, and FK to knowledge base
- `curator_evaluations` — SME ratings, feedback, and ideal answers per query

### RubyLLM-owned tables (managed by RubyLLM's generator)

- `chats` — conversation records with `acts_as_chat`
- `messages` — individual messages with `acts_as_message`
- `tool_calls` — LLM tool invocations with `acts_as_tool_call`
- `models` — LLM model registry with `acts_as_model`

Curator links `curator_retrievals` to RubyLLM's `messages` table so every
production query is traceable back to its full conversation context.

---

## Technical Requirements

- Rails 7.0+
- PostgreSQL with pgvector extension
- Ruby 3.1+ (implied by Rails 7 best practices)
- RubyLLM gem (manages LLM provider interaction and conversation persistence)
- `neighbor` gem (ActiveRecord wrapper for pgvector similarity search)
- `kreuzberg` gem (optional default extractor — Rust-core, 90+ formats, OCR;
  Elastic License 2.0 — permitted for use as a library dependency)
- `pdf-reader` + `ruby-docx` (basic extractor fallback — used if Kreuzberg
  is unavailable or not desired)
- ActiveJob (any backend: Sidekiq, GoodJob, Solid Queue, etc.)
- Active Storage (for document file storage; S3, Cloudflare R2, or local disk)
- Tailwind CSS (bundled, does not require host app to use Tailwind)

### Recommended Zero-Redis Deployment (Rails 8)

For Rails 8 apps, Curator works entirely without Redis:
- **Solid Queue** for ActiveJob background processing
- **Solid Cable** for Action Cable / Turbo Streams
- **Solid Cache** for caching

All backed by the same PostgreSQL instance already required for pgvector.
This is the recommended deployment pattern for new Rails 8 applications.

---

## v1 Scope

The goal of v1 is a shippable, useful gem that proves the concept and gives
developers something to actually integrate. Features are limited to what directly
enables that outcome.

**In scope for v1:**
- Install experience (generator, migrations, sample controller)
- Knowledge Base management (create, configure, switch)
- Document ingestion (upload via UI, programmatic API, ActiveJob pipeline)
- Pluggable extractor (Kreuzberg default, basic fallback)
- Chunking (structure-aware via Kreuzberg, paragraph-aware fallback)
- Hybrid retrieval (vector + keyword via RRF)
- Q&A and semantic search (service objects + REST API)
- Streaming responses (via RubyLLM + Turbo Streams)
- Citation system (numbered markers + source metadata)
- Admin UI: KB management, document management, chunk inspector, query testing console
- Basic evals: thumbs up/down, free-text feedback, ideal answer capture, CSV/JSON export

**Deferred to v2+:**
- Analytics dashboard (query volume, slow query tracking, retrieval success rate)
- A/B comparison view in evals
- LLM-as-judge scoring
- Corpus page (public-facing document index)
- Reranking (second-pass reranking model)
- Multi-tenancy within Curator
- Image or audio ingestion
- Fine-tuning or model training
- External vector databases (Pinecone, Weaviate, etc.)
- Multi-language support

---

## Open Questions

- Gem name: `curator-rails` (pending RubyGems availability confirmation)
- License (TBD)
- Whether to provide a sample host app as a separate repo for documentation purposes
- Tailwind distribution strategy: pre-compiled stylesheet vs. requiring host app
  to scan engine views
