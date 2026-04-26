module Curator
  # Return value from Curator.search. Wraps the ordered hit list plus
  # the bookkeeping callers need: query string echoed back, end-to-end
  # duration, the KB the search ran against, and the curator_searches
  # row id (nil when config.log_queries is false).
  SearchResults = Data.define(:query, :hits, :duration_ms, :knowledge_base, :search_id) do
    include Enumerable

    def each(&) = hits.each(&)
    def empty?  = hits.empty?
    def size    = hits.size
    alias_method :length, :size
  end
end
