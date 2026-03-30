# AI & LLM Integration

AI and LLM integration is the fastest-growing topic in technical interviews as of 2025-2026. Over 60% of ML-adjacent technical interviews now include questions on LLM behavior, hallucination mitigation, or prompt engineering. Even for backend roles at non-AI companies, interviewers want to see that you can build production systems that integrate AI capabilities: RAG pipelines, embedding-based search, AI agent architectures, and evaluation frameworks.

This is not about training models or understanding transformer internals (unless you are interviewing for ML engineering). It is about building reliable software systems around AI components: how to handle non-deterministic outputs, how to evaluate quality, how to manage context windows, and how to architect systems where AI is one component among many.

---

## Prompt Engineering

Prompt engineering is the practice of crafting inputs to LLMs to get reliable, useful outputs. It is the interface between your application logic and the model.

### Key Principles

**Be specific.** Vague prompts get vague answers. Tell the model exactly what format you want, what constraints apply, and what role it should play.

**Provide examples (few-shot).** Showing the model 2-3 examples of desired input-output pairs dramatically improves consistency.

**Structure your prompts.** Use sections, delimiters, and explicit instructions. The model follows structure.

```ruby
# Structured prompt template
class PromptBuilder
  def self.classification_prompt(text, categories)
    <<~PROMPT
      You are a text classifier. Classify the following text into exactly one
      of the provided categories. Respond with only the category name, nothing else.

      Categories: #{categories.join(', ')}

      Examples:
      Text: "My order hasn't arrived after 2 weeks"
      Category: shipping

      Text: "The product broke after one day"
      Category: quality

      Text: "I was charged twice for the same item"
      Category: billing

      Text: "#{text}"
      Category:
    PROMPT
  end
end
```

### Prompt Patterns

**System/User/Assistant structure:** Most LLM APIs support role-based messages. The system message sets behavior and constraints. User messages provide the input. Assistant messages provide examples of desired output (for few-shot).

```ruby
messages = [
  {
    role: 'system',
    content: 'You are a JSON extraction engine. Extract structured data from ' \
             'unstructured text. Always respond with valid JSON. Never include ' \
             'explanations or markdown.'
  },
  {
    role: 'user',
    content: 'Extract: "John Smith, 45, lives at 123 Main St, Toronto"'
  },
  {
    role: 'assistant',
    content: '{"name":"John Smith","age":45,"address":"123 Main St, Toronto"}'
  },
  {
    role: 'user',
    content: "Extract: \"#{user_input}\""
  }
]
```

**Chain of Thought (CoT):** Ask the model to reason step by step before giving a final answer. This improves accuracy on complex reasoning tasks.

**Output format enforcement:** Specify JSON schemas, use structured output modes (if the API supports them), or parse and validate the output programmatically.

```ruby
# Output validation after LLM call
class LlmOutputParser
  def self.parse_json(response, schema:)
    # Strip markdown code fences if present
    cleaned = response.gsub(/```json\n?/, '').gsub(/```\n?/, '').strip

    parsed = JSON.parse(cleaned, symbolize_names: true)
    validate_schema!(parsed, schema)
    parsed
  rescue JSON::ParserError => e
    raise LlmOutputError, "LLM returned invalid JSON: #{e.message}"
  end

  def self.validate_schema!(data, schema)
    schema.each do |field, type|
      raise LlmOutputError, "Missing field: #{field}" unless data.key?(field)
      unless data[field].is_a?(type)
        raise LlmOutputError, "#{field} should be #{type}, got #{data[field].class}"
      end
    end
  end
end
```

---

## Retrieval-Augmented Generation (RAG)

RAG is the most important pattern for building AI-powered applications in 2025-2026. It solves the hallucination problem by grounding LLM responses in real data retrieved from your own knowledge base.

### How RAG Works

1. **Indexing phase**: split documents into chunks, generate embeddings for each chunk, store in a vector database.
2. **Query phase**: embed the user's query, find the most similar chunks via vector search, include those chunks as context in the LLM prompt.
3. **Generation phase**: the LLM generates a response grounded in the retrieved context.

```
User Query  -->  Embed Query  -->  Vector Search  -->  Top-K Chunks
                                                           |
                                                           v
                                                    LLM Prompt with Context
                                                           |
                                                           v
                                                    Generated Answer
```

### Chunking Strategies

How you split documents into chunks matters enormously for retrieval quality.

```ruby
class DocumentChunker
  # Fixed-size chunking with overlap
  def self.fixed_size(text, chunk_size: 500, overlap: 50)
    chunks = []
    start = 0
    while start < text.length
      chunk_end = [start + chunk_size, text.length].min
      chunks << {
        text: text[start...chunk_end],
        start_offset: start,
        end_offset: chunk_end
      }
      start += chunk_size - overlap
    end
    chunks
  end

  # Semantic chunking: split on paragraph/section boundaries
  def self.semantic(text, max_chunk_size: 1000)
    paragraphs = text.split(/\n\n+/)
    chunks = []
    current_chunk = []
    current_size = 0

    paragraphs.each do |para|
      if current_size + para.length > max_chunk_size && current_chunk.any?
        chunks << { text: current_chunk.join("\n\n"), paragraph_count: current_chunk.length }
        current_chunk = []
        current_size = 0
      end
      current_chunk << para
      current_size += para.length
    end

    chunks << { text: current_chunk.join("\n\n"), paragraph_count: current_chunk.length } if current_chunk.any?
    chunks
  end
end
```

Chunk size trade-offs:
- **Too small** (100-200 chars): loses context, retrieval finds fragments that are meaningless in isolation
- **Too large** (2000+ chars): dilutes the relevant signal with irrelevant content, wastes context window
- **Sweet spot** (500-1000 chars): enough context to be meaningful, focused enough for precise retrieval

### Embedding and Vector Search

Embeddings are dense vector representations of text. Similar texts have similar embeddings (high cosine similarity).

```ruby
class EmbeddingService
  def initialize(api_client:, model: 'text-embedding-3-small')
    @client = api_client
    @model = model
  end

  def embed(text)
    response = @client.embeddings(
      model: @model,
      input: text
    )
    response[:data].first[:embedding]
  end

  def embed_batch(texts)
    response = @client.embeddings(
      model: @model,
      input: texts
    )
    response[:data].map { |d| d[:embedding] }
  end
end

# Simple in-memory vector store (production: use pgvector, Pinecone, Weaviate)
class VectorStore
  def initialize
    @documents = []  # [{id:, text:, embedding:, metadata:}]
  end

  def add(id:, text:, embedding:, metadata: {})
    @documents << { id: id, text: text, embedding: embedding, metadata: metadata }
  end

  def search(query_embedding, top_k: 5)
    scored = @documents.map do |doc|
      { document: doc, score: cosine_similarity(query_embedding, doc[:embedding]) }
    end
    scored.sort_by { |s| -s[:score] }.first(top_k)
  end

  private

  def cosine_similarity(a, b)
    dot = a.zip(b).sum { |x, y| x * y }
    mag_a = Math.sqrt(a.sum { |x| x ** 2 })
    mag_b = Math.sqrt(b.sum { |x| x ** 2 })
    return 0.0 if mag_a.zero? || mag_b.zero?
    dot / (mag_a * mag_b)
  end
end
```

### RAG Pipeline

```ruby
class RagPipeline
  def initialize(embedding_service:, vector_store:, llm_client:, top_k: 5)
    @embedding_service = embedding_service
    @vector_store = vector_store
    @llm_client = llm_client
    @top_k = top_k
  end

  # Index a document: chunk, embed, store
  def index_document(doc_id:, text:, metadata: {})
    chunks = DocumentChunker.semantic(text)

    chunks.each_with_index do |chunk, i|
      embedding = @embedding_service.embed(chunk[:text])
      @vector_store.add(
        id: "#{doc_id}:#{i}",
        text: chunk[:text],
        embedding: embedding,
        metadata: metadata.merge(doc_id: doc_id, chunk_index: i)
      )
    end
  end

  # Query: embed question, retrieve context, generate answer
  def query(question)
    # Step 1: embed the question
    query_embedding = @embedding_service.embed(question)

    # Step 2: retrieve relevant chunks
    results = @vector_store.search(query_embedding, top_k: @top_k)
    context_chunks = results.map { |r| r[:document][:text] }

    # Step 3: build prompt with context
    prompt = build_prompt(question, context_chunks)

    # Step 4: generate answer
    response = @llm_client.chat(
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: prompt }
      ]
    )

    {
      answer: response[:content],
      sources: results.map { |r| { id: r[:document][:id], score: r[:score] } },
      context_used: context_chunks.length
    }
  end

  private

  def system_prompt
    <<~PROMPT
      You are a helpful assistant that answers questions based on the provided context.
      Only use information from the context to answer. If the context does not contain
      enough information to answer the question, say "I don't have enough information
      to answer that question."
      Do not make up information. Cite which parts of the context you used.
    PROMPT
  end

  def build_prompt(question, context_chunks)
    context = context_chunks.each_with_index.map do |chunk, i|
      "[Source #{i + 1}]: #{chunk}"
    end.join("\n\n")

    <<~PROMPT
      Context:
      #{context}

      Question: #{question}

      Answer based on the context above:
    PROMPT
  end
end
```

---

## AI Agent Architectures

AI agents are systems where the LLM decides what actions to take, executes them, and iterates based on results. This is the pattern behind tools like Claude Code, AutoGPT, and company-specific AI assistants.

### Tool Use / Function Calling

The LLM is given a set of available tools (functions) with descriptions and parameters. It decides which tool to call, with what arguments. Your code executes the tool and feeds the result back to the LLM.

```ruby
class AgentToolkit
  def initialize
    @tools = {}
  end

  def register(name, description:, parameters:, &handler)
    @tools[name] = {
      description: description,
      parameters: parameters,
      handler: handler
    }
  end

  def tool_definitions
    @tools.map do |name, tool|
      {
        name: name,
        description: tool[:description],
        input_schema: tool[:parameters]
      }
    end
  end

  def execute(tool_name, arguments)
    tool = @tools[tool_name]
    raise "Unknown tool: #{tool_name}" unless tool

    tool[:handler].call(**arguments.transform_keys(&:to_sym))
  end
end

# Example usage
toolkit = AgentToolkit.new

toolkit.register('search_products',
  description: 'Search the product catalog by keyword',
  parameters: {
    type: 'object',
    properties: {
      query: { type: 'string', description: 'Search query' },
      category: { type: 'string', description: 'Optional category filter' }
    },
    required: ['query']
  }
) do |query:, category: nil|
  ProductSearch.new.search(query, category: category)
end

toolkit.register('get_order_status',
  description: 'Look up the status of an order by order ID',
  parameters: {
    type: 'object',
    properties: {
      order_id: { type: 'string', description: 'The order ID' }
    },
    required: ['order_id']
  }
) do |order_id:|
  OrderService.new.get_status(order_id)
end
```

### Agent Loop

```ruby
class Agent
  MAX_ITERATIONS = 10

  def initialize(llm_client:, toolkit:, system_prompt:)
    @llm = llm_client
    @toolkit = toolkit
    @system_prompt = system_prompt
  end

  def run(user_message)
    messages = [
      { role: 'system', content: @system_prompt },
      { role: 'user', content: user_message }
    ]

    MAX_ITERATIONS.times do |i|
      response = @llm.chat(
        messages: messages,
        tools: @toolkit.tool_definitions
      )

      # If the model wants to use a tool
      if response[:tool_use]
        tool_name = response[:tool_use][:name]
        tool_input = response[:tool_use][:input]

        # Execute the tool
        begin
          result = @toolkit.execute(tool_name, tool_input)
          messages << { role: 'assistant', content: response[:content],
                        tool_use: response[:tool_use] }
          messages << { role: 'tool', tool_use_id: response[:tool_use][:id],
                        content: result.to_json }
        rescue => e
          messages << { role: 'tool', tool_use_id: response[:tool_use][:id],
                        content: { error: e.message }.to_json }
        end
      else
        # Model is done -- return the final response
        return {
          answer: response[:content],
          iterations: i + 1,
          tool_calls: messages.count { |m| m[:role] == 'tool' }
        }
      end
    end

    raise "Agent exceeded maximum iterations (#{MAX_ITERATIONS})"
  end
end
```

### Agent Design Considerations

- **Safety guardrails**: limit what tools are available, validate tool arguments, cap iterations
- **Token budget**: track token usage across iterations, stop before exceeding limits
- **Determinism**: same input may produce different tool call sequences; design for variability
- **Error recovery**: tools can fail; the agent should be able to try alternative approaches
- **Observability**: log every tool call, every LLM response, every decision point

---

## Evaluating LLM Outputs

Evaluation is the hardest part of building LLM-powered systems. Unlike traditional software where outputs are deterministic, LLM outputs vary between calls, can be correct in different ways, and may have subtle quality differences.

### Evaluation Strategies

**Exact match**: for structured outputs (JSON, classification labels). Compare against expected output.

**Semantic similarity**: embed both the expected and actual output, compare cosine similarity. Good for open-ended text where different wordings are equally correct.

**LLM-as-judge**: use a separate LLM call to evaluate the quality of the output. Define clear criteria and a rubric.

**Human evaluation**: the gold standard but expensive. Use for calibrating automated metrics.

```ruby
class LlmEvaluator
  def initialize(llm_client:)
    @llm = llm_client
  end

  # Binary evaluation: does the answer satisfy the criteria?
  def evaluate(question:, answer:, context:, criteria:)
    prompt = <<~PROMPT
      Evaluate the following answer based on the given criteria.
      Respond with a JSON object: {"pass": true/false, "reason": "..."}

      Question: #{question}
      Context provided: #{context}
      Answer given: #{answer}

      Criteria:
      #{criteria.map { |c| "- #{c}" }.join("\n")}

      Evaluation:
    PROMPT

    response = @llm.chat(messages: [{ role: 'user', content: prompt }])
    JSON.parse(response[:content], symbolize_names: true)
  end

  # Scoring evaluation: rate the answer 1-5
  def score(question:, answer:, rubric:)
    prompt = <<~PROMPT
      Score the following answer from 1 to 5 based on the rubric.
      Respond with JSON: {"score": N, "reasoning": "..."}

      Question: #{question}
      Answer: #{answer}

      Rubric:
      5 - #{rubric[:excellent]}
      4 - #{rubric[:good]}
      3 - #{rubric[:acceptable]}
      2 - #{rubric[:poor]}
      1 - #{rubric[:unacceptable]}

      Score:
    PROMPT

    response = @llm.chat(messages: [{ role: 'user', content: prompt }])
    JSON.parse(response[:content], symbolize_names: true)
  end
end
```

### Evaluation Metrics for RAG

- **Faithfulness**: does the answer only use information from the retrieved context? (Prevents hallucination.)
- **Relevance**: are the retrieved chunks relevant to the question?
- **Answer correctness**: is the answer factually correct?
- **Context precision**: what fraction of retrieved chunks are actually useful?
- **Context recall**: did we retrieve all the chunks needed to answer the question?

---

## Production Considerations

### Latency and Streaming

LLM calls are slow (1-10 seconds). Use streaming responses to provide a better user experience.

```ruby
class StreamingLlmClient
  def chat_stream(messages:, &block)
    # Yields chunks as they arrive
    @client.chat(
      messages: messages,
      stream: true
    ) do |chunk|
      block.call(chunk[:content]) if chunk[:content]
    end
  end
end
```

### Cost Management

LLM calls cost money per token. Track and control costs.

```ruby
class CostTracker
  PRICING = {
    'claude-sonnet' => { input: 0.003, output: 0.015 },  # per 1K tokens
    'gpt-4o' => { input: 0.005, output: 0.015 }
  }.freeze

  def estimate_cost(model:, input_tokens:, output_tokens:)
    rates = PRICING[model]
    (input_tokens / 1000.0 * rates[:input]) +
      (output_tokens / 1000.0 * rates[:output])
  end
end
```

### Caching

Cache LLM responses for identical inputs to reduce latency and cost.

```ruby
class LlmCache
  def initialize(store:, ttl: 3600)
    @store = store
    @ttl = ttl
  end

  def fetch(messages:, &block)
    key = cache_key(messages)
    cached = @store.get(key)
    return cached if cached

    result = block.call
    @store.set(key, result, ex: @ttl)
    result
  end

  private

  def cache_key(messages)
    digest = Digest::SHA256.hexdigest(messages.to_json)
    "llm_cache:#{digest}"
  end
end
```

### Guardrails

Prevent harmful or off-topic outputs.

```ruby
class OutputGuardrail
  BLOCKED_PATTERNS = [
    /(?:password|secret|api.?key)\s*[:=]/i,
    /(?:DROP|DELETE|TRUNCATE)\s+(?:TABLE|DATABASE)/i,
  ].freeze

  def check(output)
    BLOCKED_PATTERNS.each do |pattern|
      if output.match?(pattern)
        return { safe: false, reason: "Output matched blocked pattern: #{pattern.source}" }
      end
    end
    { safe: true }
  end
end
```

---

## Common Interview Questions

1. **How would you reduce hallucination in a RAG system?** Use explicit grounding instructions, retrieve more context, add a verification step (LLM-as-judge), include source citations in the prompt.

2. **How do you evaluate a RAG pipeline?** Build a test set of question-answer pairs. Measure retrieval quality (precision@k, recall@k) separately from generation quality (faithfulness, correctness). Use LLM-as-judge for generation evaluation.

3. **How do you handle context window limits?** Chunking strategy, summarization of long contexts, hierarchical retrieval (retrieve summaries, then retrieve details from the best summary's source).

4. **How would you build a customer support chatbot?** RAG over support documentation + tool use for order lookup, refund initiation, etc. Agent loop with guardrails. Escalation to human for out-of-scope requests.

5. **What are the trade-offs of fine-tuning vs RAG?** Fine-tuning bakes knowledge into the model (good for style/behavior, hard to update). RAG keeps knowledge external (easy to update, but adds latency and retrieval complexity). Most production systems use RAG for factual knowledge and fine-tuning for behavioral adjustments.

---

## Exercises

- [[exercises/INSTRUCTIONS|Build a RAG Pipeline]] -- Implement a complete RAG system in Ruby: document indexing, vector search, and question answering with evaluation.

## Related Topics

- [[../03-api-design/index|API Design]] -- designing APIs for AI-powered features (streaming, async)
- [[../05-testing-and-quality/index|Testing & Quality]] -- testing non-deterministic AI outputs
- [[../system-design/index|System Design]] -- architecting ML-powered systems at scale
