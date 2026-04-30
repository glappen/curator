Curator::Engine.routes.draw do
  root "knowledge_bases#index"

  resources :knowledge_bases,
            path:   "kbs",
            param:  :slug do
    resources :documents, only: %i[index create destroy] do
      member do
        post :reingest
      end
    end
  end
end
