module Curator
  class Error < StandardError; end

  class ConfigurationError < Error; end
  class AuthNotConfigured < ConfigurationError; end

  class EmbeddingError < Error; end
  class RetrievalError < Error; end
  class LLMError < Error; end

  class ExtractionError < Error; end
  class UnsupportedMimeError < ExtractionError; end
  class FileTooLargeError < Error; end

  class FetchError < Error; end
end
