# frozen_string_literal: true

# Test data and fake clients for RAG pipeline testing.
# Use these to test without real LLM API calls.

# ============================================================
# Fake API Clients
# ============================================================

class FakeLlmClient
  attr_reader :calls

  def initialize
    @calls = []
    @responses = {}
    @default_response = { content: "I don't know." }
  end

  # Register a canned response for a given prompt pattern
  def stub_response(pattern, response)
    @responses[pattern] = response
  end

  def chat(messages:, tools: nil)
    @calls << { messages: messages, tools: tools }

    # Check for matching pattern in the last user message
    user_msg = messages.reverse.find { |m| m[:role] == 'user' }&.dig(:content) || ''

    @responses.each do |pattern, response|
      return { content: response } if user_msg.include?(pattern)
    end

    @default_response
  end
end

class FakeEmbeddingClient
  # Returns deterministic embeddings based on text content
  # Words are hashed to produce consistent vectors
  def create_embedding(model:, input:)
    # Simple bag-of-words embedding: hash each word to a dimension
    dimensions = 256
    vector = Array.new(dimensions, 0.0)

    words = input.downcase.gsub(/[^a-z0-9\s]/, '').split(/\s+/)
    words.each do |word|
      hash = Digest::MD5.hexdigest(word).to_i(16)
      dim = hash % dimensions
      vector[dim] += 1.0
    end

    # Normalize to unit vector
    magnitude = Math.sqrt(vector.sum { |v| v ** 2 })
    vector = vector.map { |v| magnitude.zero? ? 0.0 : v / magnitude }

    { embedding: vector }
  end
end

# ============================================================
# Test Documents
# ============================================================

TEST_DOCUMENTS = {
  'ruby-concurrency' => <<~DOC,
    Ruby Concurrency Guide

    Ruby's Global VM Lock (GVL), historically called the Global Interpreter Lock (GIL),
    is a mechanism in MRI (CRuby) that prevents multiple threads from executing Ruby code
    simultaneously. The GVL exists to protect internal C data structures from concurrent
    modification.

    Despite the GVL, Ruby threads are still useful for I/O-bound work. When a thread
    performs a blocking I/O operation (network request, file read, database query), it
    releases the GVL, allowing other threads to run. This means a multi-threaded Ruby
    application can handle many concurrent network requests efficiently.

    For CPU-bound work, Ruby offers Ractors (introduced in Ruby 3.0). Each Ractor has
    its own GVL, enabling true parallel execution across multiple CPU cores. However,
    Ractors have strict rules about data sharing: objects must be deeply frozen or
    transferred (moved) between Ractors.

    Fibers are another concurrency primitive in Ruby. Unlike threads, fibers are
    cooperatively scheduled -- they must explicitly yield control. The Fiber Scheduler
    interface (Ruby 3.0+) enables non-blocking I/O using fibers, similar to async/await
    in other languages. The 'async' gem provides a production-ready implementation.

    For web applications, Puma is the most popular Ruby web server and uses a thread pool.
    Each Puma worker is a separate process (bypassing the GVL for parallelism), and each
    worker runs multiple threads for concurrent request handling.
  DOC

  'ruby-testing' => <<~DOC,
    Ruby Testing Best Practices

    RSpec is the most popular testing framework in the Ruby ecosystem. It provides a
    behavior-driven development (BDD) syntax with describe/context/it blocks that read
    like documentation.

    The test pyramid suggests having many unit tests, fewer integration tests, and even
    fewer end-to-end tests. Unit tests should be fast (under 10ms each), isolated from
    external dependencies, and focused on a single behavior.

    Mocking should be done at system boundaries: HTTP clients, databases, file systems,
    and time. Don't mock the class you're testing. Use dependency injection to make
    classes testable -- accept dependencies as constructor parameters rather than creating
    them internally.

    Factory Bot is the standard library for creating test fixtures in Ruby. It generates
    test objects with sensible defaults that can be overridden per test. Avoid using
    database fixtures (YAML files) as they create hidden dependencies between tests.

    Property-based testing with gems like 'rantly' generates random inputs and verifies
    that properties hold for all of them. This catches edge cases that example-based
    tests miss. Common properties: round-trip (encode then decode), idempotency,
    commutativity, and invariant preservation.

    Mutation testing (using the 'mutant' gem) measures test quality by introducing small
    changes to your code and checking if tests catch them. If a mutation survives, your
    tests have a gap. Run it periodically to find undertested code paths.
  DOC

  'api-design' => <<~DOC
    REST API Design Principles

    REST APIs should use nouns for resource URIs, not verbs. Use HTTP methods (GET, POST,
    PUT, PATCH, DELETE) to indicate the action. GET is idempotent and safe. POST creates
    resources and is neither. PUT replaces a resource (idempotent). PATCH partially
    updates (can be idempotent). DELETE removes a resource (idempotent).

    Pagination is essential for list endpoints. Cursor-based pagination is preferred over
    offset-based because it provides consistent results when data changes between requests
    and has O(1) database performance regardless of page depth.

    Rate limiting protects your API from abuse. The token bucket algorithm is the most
    common approach. Include rate limit headers in every response: X-RateLimit-Limit,
    X-RateLimit-Remaining, and X-RateLimit-Reset.

    Idempotency keys allow clients to safely retry requests. The client sends a unique key
    with each request. The server caches the response for that key. If the same key is
    seen again, the cached response is returned without re-executing the request.

    API versioning should be done via URL prefix (/v1/) for simplicity, or via Accept
    headers for purity. The real goal is to avoid breaking changes by making additive
    changes only and providing deprecation policies with sunset headers.
  DOC
}

# ============================================================
# Test Questions with Expected Answers
# ============================================================

TEST_QA_PAIRS = [
  {
    question: "What is the GVL in Ruby?",
    expected_answer: "The GVL (Global VM Lock) is a mechanism in MRI Ruby that prevents " \
                     "multiple threads from executing Ruby code simultaneously. It exists " \
                     "to protect internal C data structures.",
    relevant_doc: 'ruby-concurrency',
    category: :factual
  },
  {
    question: "How do Ractors work in Ruby?",
    expected_answer: "Ractors enable true parallel execution in Ruby. Each Ractor has its " \
                     "own GVL, allowing multiple Ractors to run on different CPU cores. " \
                     "They communicate via message passing and have strict rules about " \
                     "data sharing -- objects must be frozen or transferred.",
    relevant_doc: 'ruby-concurrency',
    category: :factual
  },
  {
    question: "What is cursor-based pagination and why is it preferred?",
    expected_answer: "Cursor-based pagination uses an opaque cursor to mark position. It " \
                     "is preferred over offset-based pagination because it provides " \
                     "consistent results when data changes and has O(1) database performance.",
    relevant_doc: 'api-design',
    category: :factual
  },
  {
    question: "What is the difference between mocking and property-based testing?",
    expected_answer: "Mocking replaces dependencies with test doubles at system boundaries. " \
                     "Property-based testing generates random inputs and verifies that " \
                     "invariant properties hold for all of them, catching edge cases " \
                     "example-based tests miss.",
    relevant_doc: 'ruby-testing',
    category: :comparison
  },
  {
    question: "What language is Ruby written in?",
    expected_answer: "The provided context does not contain enough information to fully " \
                     "answer this question, though it mentions 'internal C data structures' " \
                     "in the context of the GVL.",
    relevant_doc: nil,  # not directly answerable from context
    category: :unanswerable
  }
]
