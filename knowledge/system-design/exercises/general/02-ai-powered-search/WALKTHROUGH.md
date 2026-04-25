# Walkthrough: Design an AI-Powered Search System

## Step 1: Clarify Requirements and Scope

Key clarifications to make:
- Is this a new system or adding AI capabilities to an existing search? (Existing Elasticsearch-based keyword search; adding semantic layer)
- What is the latency budget for the AI components? (Keyword + semantic combined < 300ms p99; RAG answers < 3s)
- How personalized should results be? (Use browsing/purchase history, not real-time context)
- Is conversational search (multi-turn) required? (Single-turn for now, but design for extensibility)

---

## Step 2: High-Level Architecture

```
                        +------------------+
                        |   API Gateway    |
                        |  (rate limiting, |
                        |   auth, routing) |
                        +--------+---------+
                                 |
                    +------------+-------------+
                    |                          |
              +-----v------+           +------v-------+
              |Search API  |           | RAG Answer   |
              |(keyword +  |           | API          |
              | semantic)  |           | (LLM-backed) |
              +-----+------+           +------+-------+
                    |                          |
         +----------+----------+        +------+-------+
         |          |          |        |              |
   +-----v---+ +---v------+ +-v----+   |         +----v----+
   |  Query   | |Keyword   | |Vector|   |         |  LLM    |
   |Understand| |Search    | |Search|   |         | Service |
   |  (NLU)   | |(Elastic) | |(ANN) |   |         | (cache) |
   +----------+ +----------+ +------+   |         +---------+
                                        |
                              +---------v---------+
                              | Product Knowledge |
                              | Base (chunked     |
                              | product data +    |
                              | reviews)          |
                              +-------------------+

OFFLINE PIPELINE:
  Product Catalog -> Embedding Service -> Vector Store
  Product Catalog -> Elasticsearch Indexer -> ES Cluster
  Product Data + Reviews -> Chunking -> RAG Knowledge Base
```

### Core Components

1. **Search API** -- handles keyword + semantic search. Orchestrates query understanding, keyword search, vector search, and result merging.
2. **RAG Answer API** -- handles natural language product questions. Retrieves relevant product data and generates an answer via LLM.
3. **Query Understanding (NLU)** -- parses the query, extracts intent, entities, and filters. Rewrites the query for better retrieval.
4. **Keyword Search (Elasticsearch)** -- traditional inverted index search with BM25 scoring, typo tolerance, synonyms.
5. **Vector Search** -- semantic similarity search using product embeddings.
6. **LLM Service** -- generates RAG answers and handles query rewriting.
7. **Offline Pipeline** -- indexes products, generates embeddings, builds the knowledge base.

---

## Step 3: Indexing Pipeline (Offline)

### Product Indexing to Elasticsearch

```
Product Catalog (PostgreSQL)
    |
    | CDC (Change Data Capture) via Debezium
    v
Kafka Topic: product-changes
    |
    v
Elasticsearch Indexer (consumer)
    |
    | Bulk index operations
    v
Elasticsearch Cluster
    |
    Index mapping:
    - title (text, analyzed)
    - description (text, analyzed)
    - brand (keyword)
    - category (keyword, hierarchical)
    - price (float)
    - attributes (nested: color, size, material)
    - ratings (float)
    - synonyms (via synonym filter)
```

**Latency:** Product changes flow from DB to ES within minutes via CDC + Kafka. For time-sensitive updates (price changes, stock), use a fast-path direct update.

### Embedding Generation

```
Product Catalog
    |
    v
Embedding Service
    | Input: "Nike Air Zoom Pegasus 40 Men's Running Shoe - breathable mesh upper,
    |         responsive ZoomX foam, suitable for daily training and long runs"
    | Model: text-embedding-3-large (1536 dimensions)
    v
Vector Store (Qdrant / pgvector)
    |
    Stored: { product_id, embedding[1536], metadata }
```

**What to embed:** Concatenate title + key attributes + description summary. Do not embed the entire raw description (too noisy). Create a "search-optimized text" field per product.

**Batch processing:** Generate embeddings in batch via Kafka consumer. 50M products * 1536 dims * 4 bytes = ~300GB vector storage. At 1000 embeddings/sec, initial indexing takes ~14 hours. Incremental updates (100K/hour) are handled in real-time.

---

## Step 4: Query Processing (Online)

### Query Understanding

Before searching, process the raw query to extract structured intent:

```
Raw query: "waterproof running shoes under $100 mens size 11"

NLU output:
{
  "search_terms": "waterproof running shoes",
  "filters": {
    "price_max": 100,
    "gender": "mens",
    "size": "11"
  },
  "intent": "product_search",
  "category_hint": "shoes/running"
}
```

**Implementation options:**
- **Rule-based + NER:** Fast, predictable, but brittle for novel queries
- **LLM-based:** Send the query to a small model (GPT-4o mini) with a structured output schema. More flexible but adds 50-100ms latency.
- **Hybrid:** Rules for common patterns (price filters, sizes), LLM for complex intent

For latency-critical search, use the hybrid approach. LLM parsing for the conversational RAG path where latency budget is larger.

### Dual Search Path

Execute keyword and semantic search in parallel:

```
Query: "comfortable work from home desk chair"

PARALLEL:
  1. Keyword Search (Elasticsearch):
     - BM25 on "comfortable work home desk chair"
     - Typo tolerance: fuzziness=AUTO
     - Synonym expansion: "work from home" -> "home office"
     - Filter by extracted facets
     - Return top 100 candidates with scores

  2. Semantic Search (Vector Store):
     - Embed the query: embed("comfortable work from home desk chair")
     - ANN search: find top 100 nearest product embeddings
     - Return candidates with cosine similarity scores

MERGE (Reciprocal Rank Fusion):
  For each document d:
    RRF_score(d) = sum(1 / (k + rank_in_list)) across both lists
    where k = 60 (standard constant)

  Re-rank merged results
  Return top 20
```

### Why Hybrid Search

- Keyword search catches exact brand names, model numbers, and specific terms that vector search may miss
- Semantic search catches intent and synonyms that keyword search misses
- RRF merge is simple, parameter-free (k=60 is the standard), and consistently outperforms either approach alone by 15-30%

---

## Step 5: Personalized Ranking

After retrieval, apply a personalized re-ranking layer:

```
Retrieved candidates (top 100)
    |
    v
Personalization Re-ranker
    |
    Inputs:
    - Base relevance score (from RRF)
    - User features (from feature store):
      - Purchase history categories
      - Price range preference
      - Brand affinity scores
      - Browsing history (recent categories)
    - Product features:
      - Category, brand, price
      - Popularity score, review score
    |
    Model: LightGBM or small neural ranker
    |
    v
Personalized top 20 results
```

**Feature store integration:** User features are precomputed and stored in the online feature store (Redis). At query time, fetch user features by user_id (< 5ms). See [[../../../ml-ai-infrastructure/index|ML/AI Infrastructure]] for feature store patterns.

**Cold start:** For new users or logged-out users, fall back to popularity-based ranking.

---

## Step 6: RAG-Powered Product Q&A

For natural language questions like "Does the MacBook Air M3 have enough RAM for video editing?":

```
User Question
    |
    v
Query Router: Is this a product search or a product question?
    |
    (product question)
    v
Retrieval:
    1. Identify relevant product(s) from query
    2. Retrieve product specs, description, and relevant review chunks
       from the knowledge base (vector search on chunked product data)
    3. Top 5 most relevant chunks

Prompt Assembly:
    "Based on the following product information:
     {retrieved chunks}

     Answer this question: {user question}

     If the information is not available, say so."

LLM Generation:
    -> "The MacBook Air M3 comes with 8GB or 16GB of unified memory.
        For video editing, the 16GB model is recommended..."
```

### Knowledge Base Design

Product data is chunked and embedded for RAG retrieval:

```
Product: MacBook Air M3
  Chunk 1: Specifications (processor, RAM, storage, display)
  Chunk 2: Description and key features
  Chunk 3-N: Top helpful reviews (chunked individually)
  Chunk N+1: Q&A pairs from the product page

Each chunk: ~256-512 tokens, embedded, stored in vector DB
Metadata: product_id, chunk_type, source
```

### Caching LLM Responses

LLM inference is expensive. Cache aggressively:

- **Exact match cache:** Same question for same product -> return cached answer
- **Semantic cache:** Similar questions (cosine similarity > 0.95) for same product -> return cached answer
- **Prompt caching:** Use provider prompt caching (shared system prompt + product context prefix)
- **TTL:** 24 hours for product Q&A (product data changes infrequently)

---

## Step 7: Autocomplete and Suggestions

```
User types: "waterpr"
    |
    v
Autocomplete Service:
    1. Prefix search on popular queries (Trie / Elasticsearch prefix)
    2. "waterproof shoes", "waterproof jacket", "waterproof phone case"

    Ranking by:
    - Global popularity (query frequency)
    - Personal relevance (user's category affinity)
    - Recency (trending queries)

    Latency: < 50ms (aggressive caching + edge)
```

**Implementation:** Precompute top completions for common prefixes and cache them at the edge (CDN or Redis). For the long tail, fall back to Elasticsearch prefix queries.

---

## Step 8: Scale and Infrastructure

### Search Latency Budget

```
Total budget: 300ms (p99)
  - Query understanding (NLU): 20ms (rule-based) or 80ms (LLM)
  - Keyword search (ES): 30-50ms
  - Vector search (ANN): 20-40ms
  - (keyword + vector in parallel: max 50ms)
  - RRF merge: 5ms
  - Personalization re-rank: 20ms
  - Feature store lookup: 5ms
  - Network overhead: 20ms
  ─────────────────────────
  Total: ~120ms (comfortable under 300ms budget)
```

### Elasticsearch Cluster

- 50M products, ~1KB per document = 50GB index
- 3 primary shards, 1 replica each = 6 shards across 3+ nodes
- Read replicas for high query throughput

### Vector Store

- 50M vectors * 1536 dims * 4 bytes = ~300GB
- HNSW index with ef_construction=200, M=16
- 3 replicas for availability
- Query latency: < 40ms for top-100 retrieval

### Caching Layers

- **Edge cache (CDN):** Autocomplete suggestions for common prefixes
- **Application cache (Redis):** Popular search results (TTL: 5 min), user features
- **Semantic cache:** LLM responses for product Q&A (TTL: 24 hours)

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Search approach | Hybrid (keyword + semantic) | Keyword only | Semantic catches intent; keyword catches exact matches |
| Merge strategy | Reciprocal Rank Fusion | Learned merge model | RRF is simple, effective, and requires no training |
| Vector store | Qdrant | pgvector | Scale (50M vectors) and latency requirements favor dedicated store |
| Embedding model | text-embedding-3-large | Open source (BGE) | Quality matters for search; cost is amortized over batch indexing |
| Re-ranking | LightGBM on features | Cross-encoder re-ranker | Faster at query time; cross-encoder adds 50-100ms |
| Query understanding | Hybrid (rules + LLM) | Pure LLM | Latency constraint; rules handle 80% of cases |
| RAG for Q&A | Separate path with LLM | No RAG | Differentiating feature; higher latency budget acceptable |

---

## Common Mistakes to Avoid

1. **Using only vector search.** Pure semantic search misses exact product names, model numbers, and brand matches. Always combine with keyword (BM25) search.

2. **Embedding raw product descriptions.** Product descriptions are often marketing copy with filler text. Create a "search-optimized" text field that concatenates the most relevant attributes.

3. **Ignoring latency budgets.** Adding LLM-based query understanding to every search query adds 50-100ms. Use it selectively (complex queries) or use a fast classifier to decide.

4. **Not caching LLM responses.** LLM inference is expensive. Product Q&A answers are highly cacheable because product data changes infrequently.

5. **Single search path for all query types.** A keyword search ("Nike Pegasus 40") and a conversational query ("shoes for my marathon next month") require different processing. Route them accordingly.

6. **Forgetting about the indexing pipeline.** The offline pipeline (CDC -> embedding -> index) is as important as the online search path. Discuss how product updates flow through the system and the freshness SLA.

7. **Over-engineering personalization.** Start with simple signals (category affinity, price range). Complex personalization models add latency and can hurt relevance if poorly calibrated.

---

## Related Topics

- [[../../../ml-ai-infrastructure/index|ML/AI Infrastructure]] -- embedding models, vector DBs, RAG, LLM serving
- [[../../../scaling-reads/index|Scaling Reads]] -- caching, CDN, read replicas for search
- [[../../../databases-and-storage/index|Databases & Storage]] -- Elasticsearch, vector stores, polyglot persistence
- [[../../../async-processing/index|Async Processing]] -- indexing pipeline via Kafka, embedding batch jobs
- [[../../../api-gateway-and-service-mesh/index|API Gateway]] -- rate limiting search queries, routing
