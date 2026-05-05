Curator::Engine.routes.draw do
  root "knowledge_bases#index"

  get  "console",     to: "console#show", as: :console
  post "console/run", to: "console#run",  as: :console_run

  resources :evaluations, only: %i[index create]
  # `:show` route is owned by the Phase 3 worktree (RetrievalsController).
  # Defined here only so Phase 4's index can build `retrieval_path(...)`
  # links — Rails defines the helper at boot regardless of controller
  # existence; the route isn't reachable until Phase 3 lands the action.
  resources :retrievals, only: %i[show]

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
