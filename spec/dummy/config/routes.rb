Rails.application.routes.draw do
  mount Curator::Engine, at: "/curator"
end

# Test-only: stubs that exercise Curator::Authentication via real routing.
# See spec/requests/curator/authentication_concern_spec.rb.
Rails.application.routes.draw do
  get "/__curator_test_admin", to: "curator_test_admin#index"
end
