require "spec_helper"

RSpec.describe "Curator error hierarchy" do
  it "has a base Curator::Error descended from StandardError" do
    expect(Curator::Error.ancestors).to include(StandardError)
  end

  it "nests auth errors under ConfigurationError" do
    expect(Curator::AuthNotConfigured.ancestors).to include(
      Curator::ConfigurationError,
      Curator::Error
    )
  end

  it "defines runtime error subclasses under Curator::Error" do
    [ Curator::EmbeddingError, Curator::RetrievalError, Curator::LLMError ].each do |klass|
      expect(klass.ancestors).to include(Curator::Error)
    end
  end
end
