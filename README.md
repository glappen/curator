# curator-rails

A Rails engine that adds production-ready Retrieval Augmented Generation (RAG)
to any Rails 7+ application. Mount it, run the generator, and your app gains
a knowledge base, semantic search, Q&A over documents, a polished admin UI,
and a JSON API for building branded frontends.

Built on top of [RubyLLM](https://rubyllm.com) (conversation persistence and
LLM provider abstraction) and [pgvector](https://github.com/pgvector/pgvector)
(vector storage via the `neighbor` gem).

> **Status: pre-alpha.** See `specs/initial.md` for the product vision and
> `specs/implementation.md` for the full technical plan. v1 is under active
> development; the gem is not yet published.

## Installation (planned)

```ruby
gem "curator-rails"
```

```bash
bundle install
rails generate curator:install
rails db:migrate
```

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
