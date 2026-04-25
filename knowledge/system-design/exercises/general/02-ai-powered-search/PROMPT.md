# Exercise: Design an AI-Powered Search System

## Prompt

Design a search system for a large e-commerce platform that combines traditional keyword search with AI-powered semantic understanding. The system should understand user intent, handle typos and synonyms, and provide personalized results. It should also support a conversational search experience where users can ask natural language questions like "waterproof running shoes under $100 with good arch support."

## Requirements

### Functional Requirements
- Keyword search with typo tolerance and synonym handling
- Semantic search (understand "laptop for video editing" matches "high-performance notebook with GPU")
- Natural language query understanding ("show me something like this but cheaper")
- Personalized ranking based on user history and preferences
- Faceted filtering (price, brand, category, ratings) applied post-retrieval
- Autocomplete and search suggestions
- Product question answering using RAG ("Does this laptop have USB-C?")

### Non-Functional Requirements
- Search latency: p50 < 100ms, p99 < 300ms for keyword + semantic search
- RAG answer latency: p50 < 1s, p99 < 3s
- Handle 10K search queries per second at peak
- Index 50M products
- Update index within 5 minutes of product changes
- 99.99% availability

### Out of Scope (clarify with interviewer)
- Image search (search by photo)
- Voice search
- Recommendation engine (separate system)
- Marketplace seller tools

## Constraints
- 50M products in the catalog
- 100M registered users
- 10K queries/second peak
- Product data changes: 100K updates/hour
- Average query length: 3-5 words (keyword), 10-20 words (natural language)

## Key Topics Tested
- [[../../../ml-ai-infrastructure/index|ML/AI Infrastructure]] -- embeddings, vector DBs, RAG, model serving
- [[../../../scaling-reads/index|Scaling Reads]] -- caching, indexing, read replicas
- [[../../../databases-and-storage/index|Databases & Storage]] -- Elasticsearch, vector stores, polyglot persistence
- [[../../../async-processing/index|Async Processing]] -- indexing pipeline, embedding generation
