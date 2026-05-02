require "rails_helper"

# Phase 1 skeleton — placeholder example so the spec file exists at the
# right path. Phase 2B fills in the real form-render and run-action
# assertions (chunked response, `<turbo-stream>` frame ordering,
# curator_retrievals row).
RSpec.describe "Curator::ConsoleController", type: :request do
  it "has the controller class loaded" do
    expect(defined?(Curator::ConsoleController)).to eq("constant")
  end
end
