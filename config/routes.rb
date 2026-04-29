Curator::Engine.routes.draw do
  root "knowledge_bases#index"

  resources :knowledge_bases,
            path:   "kbs",
            param:  :slug do
    # Nested resources (Phase 4) and member routes (Phase 5)
    # land inside this block.
  end
end
