# frozen_string_literal: true

# RAG Pipeline Implementation
#
# A complete Retrieval-Augmented Generation system with:
# - Document chunking (fixed-size and semantic)
# - Embedding generation and vector storage
# - Vector similarity search
# - Hybrid search (vector + keyword)
# - Conversational RAG with multi-turn context
# - Evaluation framework
#
# This code has 15+ intentional bugs and several unimplemented methods.
# Find the bugs, implement the stubs, and write tests.

require 'json'
require 'digest'
require 'securerandom'

# ============================================================
# Document Chunking
# ============================================================

class DocumentChunker
  # Split text into fixed-size chunks with overlap
  def self.fixed_size(text, chunk_size: 500, overlap: 50)
    # B: No validation that text is a string
    # B: No handling of empty text
    # B: No validation that overlap < chunk_size

    chunks = []
    start = 0

    while start < text.length
      # B: Does not respect word boundaries -- splits mid-word
      chunk_end = start + chunk_size
      chunk_text = text[start...chunk_end]

      chunks << {
        id: SecureRandom.uuid,
        text: chunk_text,
        start_offset: start,
        end_offset: [chunk_end, text.length].min,
        # B: chunk_index not set correctly -- always 0
        chunk_index: 0
      }

      # B: When overlap >= chunk_size, this creates an infinite loop
      start += chunk_size - overlap
    end

    chunks
  end

  # Split text on paragraph boundaries
  def self.semantic(text, max_chunk_size: 1000)
    return [] if text.nil? || text.strip.empty?

    paragraphs = text.split(/\n\n+/)
    chunks = []
    current_chunk = []
    current_size = 0

    paragraphs.each do |para|
      para = para.strip
      next if para.empty?

      if current_size + para.length > max_chunk_size && current_chunk.any?
        chunks << build_chunk(current_chunk.join("\n\n"), chunks.length)
        # B: Does not reset current_chunk and current_size after adding chunk
        # This means content accumulates incorrectly
      end

      current_chunk << para
      current_size += para.length
    end

    # B: Forgets to add the last chunk
    # chunks << build_chunk(current_chunk.join("\n\n"), chunks.length) if current_chunk.any?

    chunks
  end

  def self.build_chunk(text, index)
    {
      id: SecureRandom.uuid,
      text: text,
      chunk_index: index
    }
  end
end

# ============================================================
# Embedding Service
# ============================================================

class EmbeddingService
  def initialize(api_client:, model: 'text-embedding-3-small', dimensions: 256)
    @client = api_client
    @model = model
    @dimensions = dimensions
  end

  def embed(text)
    # B: No validation of empty text (embedding empty string gives garbage)
    response = @client.create_embedding(model: @model, input: text)
    vector = response[:embedding]

    # B: Normalization is wrong -- divides by sum instead of L2 norm
    normalize(vector)
  end

  def embed_batch(texts)
    # B: Does not handle empty texts array
    texts.map { |t| embed(t) }
  end

  private

  def normalize(vector)
    # B: This computes L1 norm (sum of absolutes), not L2 norm (Euclidean)
    magnitude = vector.sum { |v| v.abs }
    return vector if magnitude.zero?
    vector.map { |v| v / magnitude }
  end
end

# ============================================================
# Vector Store
# ============================================================

class VectorStore
  def initialize
    @documents = []
    @index = {}  # id -> document
  end

  def add(id:, text:, embedding:, metadata: {})
    doc = { id: id, text: text, embedding: embedding, metadata: metadata }
    @documents << doc
    @index[id] = doc
  end

  def get(id)
    @index[id]
  end

  def search(query_embedding, top_k: 5, filter: nil)
    results = @documents.map do |doc|
      next if filter && !filter.call(doc)
      { document: doc, score: cosine_similarity(query_embedding, doc[:embedding]) }
    end.compact

    # B: Sorts ascending instead of descending -- returns LEAST similar first
    results.sort_by { |r| r[:score] }.first(top_k)
  end

  def size
    @documents.length
  end

  def delete(id)
    @documents.reject! { |d| d[:id] == id }
    @index.delete(id)
  end

  private

  def cosine_similarity(a, b)
    # B: Does not handle vectors of different lengths
    # B: Does not handle zero vectors (division by zero)
    dot = a.zip(b).sum { |x, y| x * y }
    mag_a = Math.sqrt(a.sum { |x| x ** 2 })
    mag_b = Math.sqrt(b.sum { |x| x ** 2 })
    dot / (mag_a * mag_b)
  end
end

# ============================================================
# Keyword Search (BM25)
# ============================================================

class BM25Searcher
  K1 = 1.2
  B = 0.75

  def initialize
    @documents = []
    @doc_lengths = []
    @avg_doc_length = 0
    @term_frequencies = []  # [{term => count}]
    @doc_frequencies = Hash.new(0)  # term => num docs containing term
  end

  def add(id:, text:)
    tokens = tokenize(text)
    @documents << { id: id, text: text, tokens: tokens }
    @doc_lengths << tokens.length

    tf = Hash.new(0)
    tokens.each { |t| tf[t] += 1 }
    @term_frequencies << tf

    tf.keys.each { |t| @doc_frequencies[t] += 1 }
    @avg_doc_length = @doc_lengths.sum.to_f / @doc_lengths.length
  end

  def search(query, top_k: 5)
    query_tokens = tokenize(query)
    n = @documents.length

    scores = @documents.each_with_index.map do |doc, i|
      score = 0.0
      query_tokens.each do |term|
        tf = @term_frequencies[i][term] || 0
        df = @doc_frequencies[term] || 0

        # B: IDF calculation uses log(N/df) without +1 smoothing
        # When df == 0, this is log(N/0) = Infinity
        # When df == N, this is log(1) = 0 (which is correct but loses signal)
        idf = Math.log((n - df + 0.5) / (df + 0.5) + 1)
        tf_norm = (tf * (K1 + 1)) / (tf + K1 * (1 - B + B * @doc_lengths[i] / @avg_doc_length))
        score += idf * tf_norm
      end

      { document: doc, score: score }
    end

    scores.sort_by { |s| -s[:score] }.first(top_k)
  end

  private

  def tokenize(text)
    text.downcase.gsub(/[^a-z0-9\s]/, '').split(/\s+/)
  end
end

# ============================================================
# Hybrid Search (Vector + Keyword)
# ============================================================

class HybridSearcher
  def initialize(vector_store:, bm25_searcher:, embedding_service:,
                 vector_weight: 0.7, keyword_weight: 0.3)
    @vector_store = vector_store
    @bm25 = bm25_searcher
    @embedding_service = embedding_service
    @vector_weight = vector_weight
    @keyword_weight = keyword_weight
  end

  # TODO: Implement hybrid search using Reciprocal Rank Fusion (RRF)
  #
  # Algorithm:
  # 1. Run vector search to get top-K results
  # 2. Run BM25 keyword search to get top-K results
  # 3. For each result, calculate RRF score:
  #    rrf_score = vector_weight / (rank_in_vector + 60) + keyword_weight / (rank_in_keyword + 60)
  #    (where 60 is the RRF constant, and rank starts at 1)
  # 4. If a result appears in only one list, use only that component's score
  # 5. Return results sorted by RRF score (descending), limited to top_k
  #
  # @param query [String] the search query
  # @param top_k [Integer] number of results to return
  # @return [Array<Hash>] [{document:, score:, sources: [:vector, :keyword]}]
  def search(query, top_k: 5)
    # YOUR IMPLEMENTATION HERE
    raise NotImplementedError, "Implement hybrid search"
  end
end

# ============================================================
# RAG Pipeline
# ============================================================

class RagPipeline
  MAX_CONTEXT_TOKENS = 4000  # approximate token budget for context

  def initialize(embedding_service:, vector_store:, llm_client:,
                 searcher: nil, top_k: 5)
    @embedding_service = embedding_service
    @vector_store = vector_store
    @llm_client = llm_client
    @searcher = searcher  # nil = vector-only search
    @top_k = top_k
  end

  def index_document(doc_id:, text:, metadata: {})
    chunks = DocumentChunker.semantic(text)
    chunks.each do |chunk|
      embedding = @embedding_service.embed(chunk[:text])
      @vector_store.add(
        id: "#{doc_id}:#{chunk[:chunk_index]}",
        text: chunk[:text],
        embedding: embedding,
        metadata: metadata.merge(doc_id: doc_id)
      )
    end
    chunks.length
  end

  def query(question)
    # Retrieve relevant context
    if @searcher
      results = @searcher.search(question, top_k: @top_k)
    else
      query_embedding = @embedding_service.embed(question)
      results = @vector_store.search(query_embedding, top_k: @top_k)
    end

    # B: Does not check if results are empty
    context_chunks = results.map { |r| r[:document][:text] }

    # B: Does not respect MAX_CONTEXT_TOKENS -- stuffs all chunks regardless
    context = build_context(context_chunks)
    prompt = build_prompt(question, context)

    response = @llm_client.chat(
      messages: [
        { role: 'system', content: system_prompt },
        { role: 'user', content: prompt }
      ]
    )

    {
      answer: response[:content],
      sources: results.map { |r| r[:document][:id] },
      num_chunks: context_chunks.length
    }
  end

  private

  def system_prompt
    <<~PROMPT
      You are a helpful assistant that answers questions based on the provided context.
      Only use information from the context. If the context does not contain enough
      information, say so. Cite your sources.
    PROMPT
  end

  def build_context(chunks)
    # B: No token budget enforcement
    chunks.each_with_index.map { |chunk, i| "[#{i + 1}] #{chunk}" }.join("\n\n")
  end

  def build_prompt(question, context)
    # B: Context placed after question -- model may ignore late context
    <<~PROMPT
      Question: #{question}

      Context:
      #{context}

      Answer:
    PROMPT
  end
end

# ============================================================
# Conversational RAG (multi-turn)
# ============================================================

class ConversationalRag
  MAX_HISTORY = 10  # max conversation turns to keep

  def initialize(rag_pipeline:, llm_client:)
    @rag = rag_pipeline
    @llm = llm_client
    @history = []
  end

  # TODO: Implement multi-turn conversational RAG
  #
  # The approach:
  # 1. If there is conversation history, use the LLM to rewrite the
  #    user's question as a standalone question (incorporating context
  #    from history). Example: if user previously asked about "Ruby"
  #    and now asks "What about its GIL?", rewrite to
  #    "What is the GIL in Ruby?"
  # 2. Pass the rewritten question to the RAG pipeline
  # 3. Add the question and answer to conversation history
  # 4. Trim history to MAX_HISTORY turns
  #
  # @param question [String] the user's question
  # @return [Hash] { answer:, sources:, rewritten_question: }
  def query(question)
    # YOUR IMPLEMENTATION HERE
    raise NotImplementedError, "Implement conversational RAG"
  end

  def reset
    @history = []
  end
end

# ============================================================
# RAG Evaluator
# ============================================================

class RagEvaluator
  def initialize(llm_client:)
    @llm = llm_client
  end

  # Evaluate if the retrieved context is relevant to the question
  def evaluate_relevance(question:, context_chunks:)
    relevant_count = 0

    context_chunks.each do |chunk|
      response = @llm.chat(messages: [{
        role: 'user',
        content: "Is the following text relevant to answering the question?\n\n" \
                 "Question: #{question}\n\nText: #{chunk}\n\n" \
                 "Respond with only 'yes' or 'no'."
      }])

      relevant_count += 1 if response[:content].strip.downcase == 'yes'
    end

    {
      precision: context_chunks.empty? ? 0 : relevant_count.to_f / context_chunks.length,
      relevant_count: relevant_count,
      total_count: context_chunks.length
    }
  end

  # TODO: Evaluate if the answer only uses information from the context
  # (no hallucination)
  #
  # Approach:
  # 1. Send the question, context, and answer to the LLM
  # 2. Ask it to identify any claims in the answer that are NOT
  #    supported by the context
  # 3. Return {faithful: true/false, unsupported_claims: [...]}
  #
  # @param question [String]
  # @param context [String] the context provided to the RAG
  # @param answer [String] the RAG's answer
  # @return [Hash] { faithful:, unsupported_claims: }
  def evaluate_faithfulness(question:, context:, answer:)
    # YOUR IMPLEMENTATION HERE
    raise NotImplementedError, "Implement faithfulness evaluation"
  end

  # Evaluate answer correctness against a reference answer
  def evaluate_correctness(question:, answer:, reference_answer:)
    response = @llm.chat(messages: [{
      role: 'user',
      content: <<~PROMPT
        Compare the following answer to the reference answer.
        Score from 1-5 where 5 means fully correct and complete.
        Respond with JSON: {"score": N, "reasoning": "..."}

        Question: #{question}
        Reference answer: #{reference_answer}
        Answer to evaluate: #{answer}
      PROMPT
    }])

    JSON.parse(response[:content], symbolize_names: true)
  end
end

# ============================================================
# Token Estimator (approximate)
# ============================================================

class TokenEstimator
  # Rough estimate: 1 token ~= 4 characters for English text
  CHARS_PER_TOKEN = 4

  def self.estimate(text)
    return 0 if text.nil? || text.empty?
    (text.length.to_f / CHARS_PER_TOKEN).ceil
  end

  def self.truncate_to_budget(texts, budget)
    result = []
    remaining = budget

    texts.each do |text|
      tokens = estimate(text)
      break if tokens > remaining

      result << text
      remaining -= tokens
    end

    result
  end
end
