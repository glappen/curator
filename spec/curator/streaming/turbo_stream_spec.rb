require "rails_helper"

# Phase 1 skeleton — placeholder example so the spec file exists and the
# directory is wired into rspec collection. Phase 2A replaces this with
# the real frame-writing assertions (StringIO substitute, escape behavior,
# .open block sugar, idempotent close).
RSpec.describe Curator::Streaming::TurboStream do
  it "exposes the Phase 1 skeleton signatures" do
    expect(described_class).to respond_to(:open)
    expect(described_class.instance_method(:append).arity).to eq(1)
  end
end
