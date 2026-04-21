module Curator
  class Error < StandardError; end

  class ConfigurationError < Error; end
  class AuthNotConfigured < ConfigurationError; end

  class EmbeddingError < Error; end
  class RetrievalError < Error; end
  class LLMError < Error; end
end
