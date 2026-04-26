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

  describe "Curator::EmbeddingDimensionMismatch" do
    it "inherits from EmbeddingError" do
      expect(Curator::EmbeddingDimensionMismatch.ancestors).to include(Curator::EmbeddingError)
    end

    it "carries expected and actual dims and an actionable message" do
      err = Curator::EmbeddingDimensionMismatch.new(expected: 1536, actual: 1024, model: "voyage-3")
      expect(err.expected).to eq(1536)
      expect(err.actual).to eq(1024)
      expect(err.message).to include("1536", "1024", "voyage-3", "schema migration", "full reembed")
    end

    it "omits the model clause when model is unspecified" do
      err = Curator::EmbeddingDimensionMismatch.new(expected: 1536, actual: 1024)
      expect(err.message).to include("1536", "1024")
    end
  end
end
