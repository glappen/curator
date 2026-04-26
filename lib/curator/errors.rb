module Curator
  class Error < StandardError; end

  class ConfigurationError < Error; end
  class AuthNotConfigured < ConfigurationError; end

  class EmbeddingError < Error; end

  class EmbeddingDimensionMismatch < EmbeddingError
    attr_reader :expected, :actual, :model

    def initialize(expected:, actual:, model: nil)
      @expected = expected
      @actual   = actual
      @model    = model
      super(build_message)
    end

    private

    def build_message
      model_clause = model ? "model '#{model}' produces" : "model produces"
      "#{model_clause} #{actual}-dim vectors; column is #{expected}-dim — " \
        "this requires a schema migration and full reembed"
    end
  end

  class RetrievalError < Error; end
  class LLMError < Error; end

  class ExtractionError < Error; end
  class UnsupportedMimeError < ExtractionError; end
  class FileTooLargeError < Error; end

  class FetchError < Error; end
end
