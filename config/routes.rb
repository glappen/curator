Curator::Engine.routes.draw do
  root "dashboard#index"

  resources :knowledge_bases,
            path:   "kbs",
            param:  :slug,
            except: [ :index ] do
    # Nested resources (Phase 4) and member routes (Phase 5)
    # land inside this block.
  end
end
