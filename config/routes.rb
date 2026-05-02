Curator::Engine.routes.draw do
  root "knowledge_bases#index"

  get  "console",     to: "console#show", as: :console
  post "console/run", to: "console#run",  as: :console_run

  resources :knowledge_bases,
            path:   "kbs",
            param:  :slug do
    get "console", to: "console#show", as: :console

    resources :documents, only: %i[index show create destroy] do
      member do
        post :reingest
      end
    end
  end
end
