Curator::Engine.routes.draw do
  root "knowledge_bases#index"

  resources :knowledge_bases,
            path:   "kbs",
            param:  :slug do
    resources :documents, only: %i[index create]
    # Member routes for Phase 5 land inside `resources :documents`.
  end
end
