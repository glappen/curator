module Curator
  # One result row from a retrieval strategy. `rank` is 1-indexed and
  # equals the citation marker `[N]` in the assembled prompt (M4).
  # `score` carries cosine similarity in [-1.0, 1.0] for vector /
  # hybrid hits (1.0 = identical direction, -1.0 = anti-correlated;
  # real LLM embeddings cluster in the positive range). It's nil for
  # keyword-only contributions — callers handling pure-keyword KBs
  # already need to tolerate nil.
  Hit = Data.define(
    :rank,
    :chunk_id,
    :document_id,
    :document_name,
    :page_number,
    :text,
    :score,
    :source_url
  )
end
