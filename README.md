# curator-rails

A Rails engine that adds production-ready Retrieval Augmented Generation (RAG)
to any Rails 7+ application. Mount it, run the generator, and your app gains
a knowledge base, semantic search, Q&A over documents, a polished admin UI,
and a JSON API for building branded frontends.

Built on top of [RubyLLM](https://rubyllm.com) (conversation persistence and
LLM provider abstraction) and [pgvector](https://github.com/pgvector/pgvector)
(vector storage via the `neighbor` gem).

> **Status: pre-alpha.** See `features/initial.md` for the product vision
> and `features/implementation.md` for the full technical plan. v1 is
> under active development; the gem is not yet published.

## Installation (planned)

```ruby
gem "curator-rails"
```

```bash
bundle install
rails generate curator:install
rails db:migrate
```

### Optional dependencies

Curator ships with two extraction backends — host apps pick one via
`config.extractor`.

- **`:basic`** (default in v1 host apps) — dependency-free. Handles
  `text/plain`, `text/markdown`, `text/csv`, and `text/html` (HTML
  stripped via Nokogiri). Anything else raises
  `Curator::UnsupportedMimeError`.

- **`:kreuzberg`** — PDF, Office, RTF, EPUB, images, and 50+ other
  formats via the [`kreuzberg`](https://rubygems.org/gems/kreuzberg)
  gem. Kreuzberg is *not* declared in `curator-rails.gemspec`; opt in
  by adding it to your `Gemfile`:

  ```ruby
  gem "kreuzberg"
  ```

  Then:

  ```ruby
  Curator.configure { |c| c.extractor = :kreuzberg }
  ```

#### OCR (Kreuzberg only)

By default Kreuzberg extracts **embedded** text only — text rendered as
images (scanned PDFs, photos, images in slides) will be skipped. Enable
OCR with:

```ruby
Curator.configure do |c|
  c.extractor    = :kreuzberg
  c.ocr          = :tesseract   # or `true` (shorthand) or :paddle
  c.ocr_language = "eng"        # tesseract/paddle lang code
  c.force_ocr    = false        # true = re-OCR pages that already have text
end
```

The OCR engine itself is a system dependency that curator-rails does
not ship:

- **Tesseract** — install via your package manager.
  Arch: `sudo pacman -S tesseract tesseract-data-eng`.
  Debian/Ubuntu: `sudo apt install tesseract-ocr tesseract-ocr-eng`.
  macOS: `brew install tesseract` (add language packs as needed).
- **PaddleOCR** — see the
  [Kreuzberg docs](https://kreuzberg.dev) for PaddleOCR setup; heavier
  install, stronger on CJK languages.

## Usage (planned)

```ruby
# One-shot Q&A
result = Curator.ask("What is our refund policy?", knowledge_base: :support)
result.answer           # => String
result.sources          # => Array of retrieved chunks with metadata

# Semantic search without LLM
results = Curator.search("refund policy", knowledge_base: :legal, limit: 10)

# Multi-turn persistent chat (retrieval tool-wired)
chat = Curator.chat(knowledge_base: :support)
chat.ask("What's our refund policy?") { |chunk| stream(chunk) }
chat.ask("How long do I have to claim?") { |chunk| stream(chunk) }

# Ingest documents
Curator.ingest(file, knowledge_base: :support, title: "Refund Policy")
Curator.ingest_directory("./docs", knowledge_base: :support)
```

## License

Released under the [MIT License](MIT-LICENSE).
