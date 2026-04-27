module RubyLLMStubs
  EMBEDDING_URL       = "https://api.openai.com/v1/embeddings".freeze
  CHAT_COMPLETION_URL = "https://api.openai.com/v1/chat/completions".freeze

  # Stub OpenAI's /embeddings endpoint to return either a fixed vector
  # array (when `vectors:` is given) or a deterministic per-input vector
  # (the default — sequence built from a hash of each input). The
  # deterministic mode is enough for "different chunks get different
  # vectors" assertions without forcing every spec to wire up fixtures.
  #
  # Returns the WebMock stub so callers can `expect(...).to have_been_requested`.
  def stub_embed(model: "text-embedding-3-small", vectors: nil, dimension: 1536)
    WebMock.stub_request(:post, EMBEDDING_URL)
           .with(body: hash_including("model" => model))
           .to_return do |request|
      payload = JSON.parse(request.body)
      inputs  = Array(payload.fetch("input"))
      data    = inputs.each_with_index.map do |text, idx|
        vector = vectors ? vectors.fetch(idx) : deterministic_vector(text, dimension)
        { "embedding" => vector, "index" => idx, "object" => "embedding" }
      end

      {
        status:  200,
        headers: { "Content-Type" => "application/json" },
        body:    {
          "data"   => data,
          "model"  => model,
          "object" => "list",
          "usage"  => { "prompt_tokens" => inputs.length, "total_tokens" => inputs.length }
        }.to_json
      }
    end
  end

  # Stub /embeddings to fail. Pass `:bad_request` for OpenAI's per-input
  # rejection (RubyLLM raises BadRequestError) or `:server_error` for the
  # whole-batch retryable case.
  def stub_embed_error(kind, model: "text-embedding-3-small")
    status, error_type = case kind
    when :bad_request   then [ 400, "invalid_request_error" ]
    when :rate_limit    then [ 429, "rate_limit_exceeded" ]
    when :server_error  then [ 503, "service_unavailable" ]
    else raise ArgumentError, "unknown stub kind: #{kind.inspect}"
    end

    WebMock.stub_request(:post, EMBEDDING_URL)
           .with(body: hash_including("model" => model))
           .to_return(
             status:  status,
             headers: { "Content-Type" => "application/json" },
             body:    { "error" => { "type" => error_type, "message" => "stubbed #{kind}" } }.to_json
           )
  end

  # Stub OpenAI's /chat/completions endpoint to return a non-streamed
  # assistant message with the given content. Mirrors `stub_embed`'s
  # shape: returns the WebMock stub so callers can assert on it.
  def stub_chat_completion(model: "gpt-5-mini", content: "stubbed assistant reply",
                           input_tokens: 12, output_tokens: 8, finish_reason: "stop")
    WebMock.stub_request(:post, CHAT_COMPLETION_URL)
           .with(body: hash_including("model" => model))
           .to_return(
             status:  200,
             headers: { "Content-Type" => "application/json" },
             body:    {
               "id"      => "chatcmpl-stub-#{SecureRandom.hex(4)}",
               "object"  => "chat.completion",
               "created" => Time.now.to_i,
               "model"   => model,
               "choices" => [ {
                 "index"         => 0,
                 "message"       => { "role" => "assistant", "content" => content },
                 "finish_reason" => finish_reason
               } ],
               "usage"   => {
                 "prompt_tokens"     => input_tokens,
                 "completion_tokens" => output_tokens,
                 "total_tokens"      => input_tokens + output_tokens
               }
             }.to_json
           )
  end

  # Stub /chat/completions to fail. `:server_error` is the
  # whole-call retryable case; `:bad_request` is the permanent case
  # (RubyLLM raises BadRequestError).
  def stub_chat_completion_error(kind, model: "gpt-5-mini")
    status, error_type = case kind
    when :bad_request   then [ 400, "invalid_request_error" ]
    when :rate_limit    then [ 429, "rate_limit_exceeded" ]
    when :server_error  then [ 503, "service_unavailable" ]
    else raise ArgumentError, "unknown stub kind: #{kind.inspect}"
    end

    WebMock.stub_request(:post, CHAT_COMPLETION_URL)
           .with(body: hash_including("model" => model))
           .to_return(
             status:  status,
             headers: { "Content-Type" => "application/json" },
             body:    { "error" => { "type" => error_type, "message" => "stubbed #{kind}" } }.to_json
           )
  end

  # Deterministic L2-normalized vector for `text`. Each whitespace token
  # contributes a SHA-seeded random projection; the projections are
  # summed and normalized. Properties retrieval specs care about:
  #
  #   - Same text → same vector (Random.new is fully seeded).
  #   - Texts sharing tokens have higher cosine similarity than texts
  #     that don't, so a query and a chunk that share words will
  #     out-rank an unrelated chunk under cosine retrieval.
  #   - Each dimension is independently sampled (no SHA-byte aliasing
  #     across the requested dimension), so the vector occupies the
  #     full embedding space rather than a 32-byte stripe.
  def deterministic_vector(text, dimension)
    vector = Array.new(dimension, 0.0)
    tokens = text.to_s.downcase.scan(/\w+/)
    tokens = [ text.to_s ] if tokens.empty?

    tokens.each do |token|
      rng = Random.new(Digest::SHA256.hexdigest(token).to_i(16))
      dimension.times { |i| vector[i] += rng.rand * 2 - 1 }
    end

    norm = Math.sqrt(vector.sum { |v| v * v })
    norm.zero? ? vector : vector.map { |v| v / norm }
  end
end

RSpec.configure do |config|
  config.include RubyLLMStubs

  # RubyLLM raises ConfigurationError if openai_api_key is nil. WebMock
  # intercepts the actual HTTP, so any non-empty placeholder works.
  config.before(:suite) do
    RubyLLM.configure { |c| c.openai_api_key ||= "test-openai-key" }
  end

  # Default /embeddings stub so specs that exercise the full ingest →
  # embed pipeline (smoke tests, rake tests) don't have to wire up
  # WebMock by hand. Specs that need to assert call counts or simulate
  # failures install their own stubs, which take precedence.
  config.before(:each) { stub_embed }
end
