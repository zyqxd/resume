# Answer Key -- Build a RAG Pipeline

---

## Part 1: Bugs Found

### Chunking Bugs

#### 1. `fixed_size` does not validate input (Line ~28)
**Severity: P1 -- crashes on nil/empty input**

```ruby
# BUG: no validation
def self.fixed_size(text, chunk_size: 500, overlap: 50)

# FIX:
def self.fixed_size(text, chunk_size: 500, overlap: 50)
  raise ArgumentError, "text must be a String" unless text.is_a?(String)
  return [] if text.empty?
  raise ArgumentError, "overlap must be less than chunk_size" if overlap >= chunk_size
```

#### 2. `fixed_size` infinite loop when overlap >= chunk_size (Line ~41)
**Severity: P0 -- hangs forever**

When `overlap >= chunk_size`, `start += chunk_size - overlap` produces zero or negative advancement.

```ruby
# FIX: validate or clamp
raise ArgumentError, "overlap must be < chunk_size" if overlap >= chunk_size
```

#### 3. `fixed_size` chunk_index always 0 (Line ~38)
**Severity: P2 -- incorrect metadata**

```ruby
# BUG
chunk_index: 0

# FIX: use an incrementing counter
chunks.each_with_index do |chunk, i|
  chunk[:chunk_index] = i
end
# Or: track index in the loop
```

#### 4. `fixed_size` splits mid-word (Line ~33)
**Severity: P2 -- retrieval quality degradation**

```ruby
# FIX: find the nearest word boundary
chunk_end = start + chunk_size
if chunk_end < text.length
  # Find last space before chunk_end
  last_space = text.rindex(' ', chunk_end)
  chunk_end = last_space if last_space && last_space > start
end
```

#### 5. `semantic` does not reset accumulator after emitting chunk (Line ~58)
**Severity: P0 -- chunks contain all previous content**

```ruby
# BUG: current_chunk and current_size are not reset
chunks << build_chunk(current_chunk.join("\n\n"), chunks.length)
# Missing:
current_chunk = []
current_size = 0
```

#### 6. `semantic` forgets the last chunk (Line ~63)
**Severity: P0 -- loses the final content**

```ruby
# BUG: commented out
# chunks << build_chunk(current_chunk.join("\n\n"), chunks.length) if current_chunk.any?

# FIX: uncomment
chunks << build_chunk(current_chunk.join("\n\n"), chunks.length) if current_chunk.any?
```

### Embedding Bugs

#### 7. `normalize` uses L1 norm instead of L2 norm (Line ~87)
**Severity: P0 -- cosine similarity is incorrect**

L2 normalization makes vectors unit-length, which is required for cosine similarity to equal dot product. L1 normalization (sum of absolutes) does not preserve angular relationships.

```ruby
# BUG: L1 norm
magnitude = vector.sum { |v| v.abs }

# FIX: L2 norm (Euclidean)
magnitude = Math.sqrt(vector.sum { |v| v ** 2 })
```

#### 8. `embed` does not validate empty text (Line ~75)
**Severity: P1 -- garbage embedding for empty input**

```ruby
# FIX
raise ArgumentError, "Cannot embed empty text" if text.nil? || text.strip.empty?
```

### Vector Store Bugs

#### 9. `search` sorts ascending (lowest similarity first) (Line ~115)
**Severity: P0 -- returns least relevant results**

```ruby
# BUG
results.sort_by { |r| r[:score] }.first(top_k)

# FIX
results.sort_by { |r| -r[:score] }.first(top_k)
```

#### 10. `cosine_similarity` does not handle zero vectors (Line ~126)
**Severity: P1 -- division by zero**

```ruby
# FIX
return 0.0 if mag_a.zero? || mag_b.zero?
dot / (mag_a * mag_b)
```

#### 11. `cosine_similarity` does not handle different-length vectors (Line ~123)
**Severity: P1 -- crash or incorrect result**

```ruby
# FIX: validate at entry
raise ArgumentError, "Vector dimension mismatch" unless a.length == b.length
```

### RAG Pipeline Bugs

#### 12. `build_prompt` puts context after question (Line ~228)
**Severity: P1 -- model may ignore context**

LLMs attend more strongly to content at the beginning and end of the prompt. Context should come before the question.

```ruby
# FIX: swap order
<<~PROMPT
  Context:
  #{context}

  Question: #{question}

  Answer based on the context above:
PROMPT
```

#### 13. No context token budget enforcement (Line ~220)
**Severity: P1 -- can exceed model's context window**

```ruby
# FIX: use TokenEstimator to truncate
def build_context(chunks)
  truncated = TokenEstimator.truncate_to_budget(chunks, MAX_CONTEXT_TOKENS)
  truncated.each_with_index.map { |chunk, i| "[#{i + 1}] #{chunk}" }.join("\n\n")
end
```

#### 14. No empty results check (Line ~207)
**Severity: P2 -- sends prompt with no context**

```ruby
# FIX
if results.empty?
  return { answer: "I don't have any relevant information to answer that question.",
           sources: [], num_chunks: 0 }
end
```

### BM25 Bug

#### 15. IDF calculation can produce Infinity when df=0 (Line ~162)
**Severity: P2 -- numeric instability**

The BM25 IDF formula used is actually the standard BM25 formula with smoothing, so `df + 0.5` prevents division by zero. However, when `df == 0`, the term does not appear in any document and the score contribution should arguably be zero (the term is not in the corpus). The current formula handles this correctly mathematically but may produce misleadingly high scores for query terms that do not exist in any document.

---

## Part 2: Stub Implementations

### HybridSearcher#search

```ruby
def search(query, top_k: 5)
  # Run both search methods
  query_embedding = @embedding_service.embed(query)
  vector_results = @vector_store.search(query_embedding, top_k: top_k * 2)
  keyword_results = @bm25.search(query, top_k: top_k * 2)

  # Build rank maps: doc_id -> rank (1-indexed)
  vector_ranks = {}
  vector_results.each_with_index do |r, i|
    vector_ranks[r[:document][:id]] = i + 1
  end

  keyword_ranks = {}
  keyword_results.each_with_index do |r, i|
    keyword_ranks[r[:document][:id]] = i + 1
  end

  # Collect all unique document IDs
  all_doc_ids = (vector_ranks.keys + keyword_ranks.keys).uniq

  # Calculate RRF scores
  rrf_constant = 60
  scored = all_doc_ids.map do |doc_id|
    score = 0.0
    sources = []

    if vector_ranks[doc_id]
      score += @vector_weight / (vector_ranks[doc_id] + rrf_constant)
      sources << :vector
    end

    if keyword_ranks[doc_id]
      score += @keyword_weight / (keyword_ranks[doc_id] + rrf_constant)
      sources << :keyword
    end

    # Find the document object from whichever result set has it
    doc = vector_results.find { |r| r[:document][:id] == doc_id }&.dig(:document) ||
          keyword_results.find { |r| r[:document][:id] == doc_id }&.dig(:document)

    { document: doc, score: score, sources: sources }
  end

  scored.sort_by { |s| -s[:score] }.first(top_k)
end
```

### RagEvaluator#evaluate_faithfulness

```ruby
def evaluate_faithfulness(question:, context:, answer:)
  prompt = <<~PROMPT
    Analyze the following answer for faithfulness to the provided context.
    Identify any claims in the answer that are NOT supported by the context.

    Context:
    #{context}

    Question: #{question}

    Answer: #{answer}

    Respond with JSON:
    {
      "faithful": true/false,
      "unsupported_claims": ["claim 1", "claim 2"]
    }

    If all claims in the answer are supported by the context, set faithful to true
    and unsupported_claims to an empty array.
  PROMPT

  response = @llm.chat(messages: [{ role: 'user', content: prompt }])

  begin
    result = JSON.parse(response[:content], symbolize_names: true)
    {
      faithful: result[:faithful],
      unsupported_claims: result[:unsupported_claims] || []
    }
  rescue JSON::ParserError
    # If LLM doesn't return valid JSON, assume unfaithful (safe default)
    { faithful: false, unsupported_claims: ["Unable to parse evaluation response"] }
  end
end
```

### ConversationalRag#query

```ruby
def query(question)
  rewritten = question

  # If there's history, rewrite the question to be standalone
  if @history.any?
    history_text = @history.last(MAX_HISTORY).map do |turn|
      "User: #{turn[:question]}\nAssistant: #{turn[:answer]}"
    end.join("\n\n")

    rewrite_response = @llm.chat(messages: [{
      role: 'user',
      content: <<~PROMPT
        Given the following conversation history and a new question,
        rewrite the question to be a standalone question that includes
        all necessary context. Return ONLY the rewritten question.

        Conversation history:
        #{history_text}

        New question: #{question}

        Standalone question:
      PROMPT
    }])

    rewritten = rewrite_response[:content].strip
  end

  # Query the RAG pipeline with the rewritten question
  result = @rag.query(rewritten)

  # Add to history
  @history << {
    question: question,
    rewritten_question: rewritten,
    answer: result[:answer]
  }

  # Trim history
  @history = @history.last(MAX_HISTORY) if @history.length > MAX_HISTORY

  {
    answer: result[:answer],
    sources: result[:sources],
    rewritten_question: rewritten
  }
end
```

---

## Part 3: Reference Tests

```ruby
require_relative 'rag_pipeline'
require_relative 'rag_test_data'

RSpec.describe DocumentChunker do
  describe '.fixed_size' do
    it 'splits text into chunks of specified size' do
      text = 'a' * 1000
      chunks = DocumentChunker.fixed_size(text, chunk_size: 300, overlap: 0)

      expect(chunks.length).to eq(4)  # 300 + 300 + 300 + 100
      expect(chunks.first[:text].length).to eq(300)
    end

    it 'returns empty array for empty text' do
      chunks = DocumentChunker.fixed_size('', chunk_size: 100)
      expect(chunks).to eq([])
    end

    it 'handles text shorter than chunk_size' do
      chunks = DocumentChunker.fixed_size('short', chunk_size: 100)
      expect(chunks.length).to eq(1)
      expect(chunks.first[:text]).to eq('short')
    end

    it 'applies overlap correctly' do
      text = 'abcdefghij'  # 10 chars
      chunks = DocumentChunker.fixed_size(text, chunk_size: 5, overlap: 2)

      expect(chunks[0][:text]).to eq('abcde')
      expect(chunks[1][:start_offset]).to eq(3)  # 5 - 2 = 3
      expect(chunks[1][:text]).to eq('defgh')
    end

    it 'raises when overlap >= chunk_size' do
      expect {
        DocumentChunker.fixed_size('text', chunk_size: 5, overlap: 5)
      }.to raise_error(ArgumentError)
    end

    it 'assigns incrementing chunk_index' do
      text = 'a' * 100
      chunks = DocumentChunker.fixed_size(text, chunk_size: 30, overlap: 0)
      indices = chunks.map { |c| c[:chunk_index] }
      expect(indices).to eq([0, 1, 2, 3])
    end
  end

  describe '.semantic' do
    it 'splits on paragraph boundaries' do
      text = "Paragraph one.\n\nParagraph two.\n\nParagraph three."
      chunks = DocumentChunker.semantic(text, max_chunk_size: 50)

      expect(chunks.length).to be >= 1
      expect(chunks.flat_map { |c| c[:text] }.join).to include('Paragraph one')
    end

    it 'returns empty array for nil input' do
      expect(DocumentChunker.semantic(nil)).to eq([])
    end

    it 'returns empty array for whitespace-only input' do
      expect(DocumentChunker.semantic('   ')).to eq([])
    end

    it 'does not lose the last paragraph' do
      text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
      chunks = DocumentChunker.semantic(text, max_chunk_size: 10000)

      all_text = chunks.map { |c| c[:text] }.join(' ')
      expect(all_text).to include('Third paragraph')
    end
  end
end

RSpec.describe VectorStore do
  let(:store) { VectorStore.new }

  it 'returns most similar documents first' do
    # Add three documents with known embeddings
    store.add(id: 'a', text: 'ruby', embedding: [1.0, 0.0, 0.0], metadata: {})
    store.add(id: 'b', text: 'python', embedding: [0.0, 1.0, 0.0], metadata: {})
    store.add(id: 'c', text: 'ruby-ish', embedding: [0.9, 0.1, 0.0], metadata: {})

    results = store.search([1.0, 0.0, 0.0], top_k: 3)

    # 'a' should be first (exact match), 'c' second (similar)
    expect(results.first[:document][:id]).to eq('a')
    expect(results[1][:document][:id]).to eq('c')
  end

  it 'respects top_k limit' do
    10.times { |i| store.add(id: "doc-#{i}", text: "text", embedding: [rand], metadata: {}) }
    results = store.search([0.5], top_k: 3)
    expect(results.length).to eq(3)
  end

  it 'handles zero vectors gracefully' do
    store.add(id: 'zero', text: 'empty', embedding: [0.0, 0.0], metadata: {})
    results = store.search([1.0, 0.0], top_k: 1)
    expect(results.first[:score]).to eq(0.0)
  end
end

RSpec.describe RagEvaluator do
  let(:llm) { FakeLlmClient.new }
  let(:evaluator) { RagEvaluator.new(llm_client: llm) }

  describe '#evaluate_faithfulness' do
    it 'returns faithful for grounded answers' do
      llm.stub_response('Analyze the following',
        '{"faithful": true, "unsupported_claims": []}')

      result = evaluator.evaluate_faithfulness(
        question: 'What is the GVL?',
        context: 'The GVL prevents parallel Ruby execution.',
        answer: 'The GVL prevents parallel Ruby execution.'
      )

      expect(result[:faithful]).to be true
      expect(result[:unsupported_claims]).to be_empty
    end

    it 'returns unfaithful for hallucinated answers' do
      llm.stub_response('Analyze the following',
        '{"faithful": false, "unsupported_claims": ["Ruby was created in 2020"]}')

      result = evaluator.evaluate_faithfulness(
        question: 'When was Ruby created?',
        context: 'Ruby is a programming language.',
        answer: 'Ruby was created in 2020.'
      )

      expect(result[:faithful]).to be false
      expect(result[:unsupported_claims]).not_to be_empty
    end
  end
end
```

---

## Summary

| Category | Count | P0 | P1 | P2 |
|---|---|---|---|---|
| Chunking bugs | 6 | 3 | 1 | 2 |
| Embedding bugs | 2 | 1 | 1 | 0 |
| Vector store bugs | 3 | 1 | 2 | 0 |
| Pipeline bugs | 3 | 0 | 2 | 1 |
| BM25 bugs | 1 | 0 | 0 | 1 |
| **Total** | **15** | **5** | **6** | **4** |
