Rails.application.routes.draw do
  mount Curator::Engine, at: "/curator"
end
