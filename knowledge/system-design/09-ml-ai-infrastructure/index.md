# ML/AI Infrastructure

ML/AI infrastructure has become one of the hottest system design interview topics since 2024. As AI moves from research to production, engineers are expected to understand how to serve models at scale, manage feature pipelines, store and retrieve embeddings, build RAG systems, schedule GPU workloads, and test ML models in production. This section covers **model serving**, **feature stores**, **embedding storage and retrieval**, **RAG architecture**, **GPU scheduling**, **A/B testing ML models**, and **LLM caching/routing**. Even for non-ML-focused roles, familiarity with these patterns signals awareness of modern architecture trends.

---

## Model Serving at Scale

Model serving is the infrastructure that takes a trained model and makes it available for inference (predictions) at production scale.

### Online vs Batch Inference

| Aspect | Online (Real-time) | Batch (Offline) |
|---|---|---|
| Latency | Milliseconds (p99 < 100ms) | Minutes to hours |
| Throughput | Thousands of req/sec | Millions of records |
| Use case | Search ranking, recommendations, fraud detection | Email campaigns, report generation, data enrichment |
| Infrastructure | Serving framework + auto-scaling | Spark/Flink jobs, scheduled pipelines |

### Serving Architectures

**Direct model hosting:** Load model into application memory. Simplest approach but couples model lifecycle to application deployment.

**Model server (dedicated):** A separate service that hosts the model and exposes an inference API. Decouples model deployment from application code.

```
Client -> Application Server -> Model Server (gRPC/HTTP) -> Return prediction
                                    |
                              Model Registry
                              (MLflow, S3)
```

**Serving frameworks:** TensorFlow Serving, TorchServe, Triton Inference Server (NVIDIA), vLLM (for LLMs). These handle model loading, versioning, batching, GPU allocation, and health checks.

### Key Challenges

- **Model size:** Large models (LLMs with billions of parameters) may not fit in a single GPU's memory. Requires model parallelism (tensor parallelism, pipeline parallelism) or quantization.
- **Latency optimization:** Batching inference requests (dynamic batching), model compilation (TensorRT, ONNX Runtime), quantization (FP16, INT8, INT4).
- **Canary deployment:** Roll out a new model version to a small percentage of traffic before full deployment.
- **Multi-model serving:** Serve multiple models from the same infrastructure, routing by model ID. Share GPU resources efficiently.

---

## Feature Stores

A feature store is a centralized platform for managing, storing, and serving ML features (the input variables a model uses for predictions). It bridges the gap between offline training and online serving.

### The Feature Problem

Without a feature store, teams often compute features differently for training (batch, Python/Spark) and serving (real-time, application code). This "training-serving skew" causes models to behave differently in production than in training.

### Architecture

```
Data Sources -> Feature Engineering Pipeline -> Feature Store
                                                   |
                                          +--------+--------+
                                          |                 |
                                   Offline Store       Online Store
                                  (historical data)    (low-latency)
                                   (S3, BigQuery)      (Redis, DynamoDB)
                                          |                 |
                                    Training Jobs     Serving Requests
```

### Key Components

- **Feature definitions:** Schema and transformation logic for each feature
- **Offline store:** Historical feature values for training. Stored in data warehouses (BigQuery, Snowflake) or object storage (S3, Parquet files).
- **Online store:** Latest feature values for real-time inference. Low-latency stores (Redis, DynamoDB). Must serve in < 10ms.
- **Feature registry:** Metadata catalog of all features (ownership, description, data type, freshness SLA).
- **Materialization pipeline:** Moves features from offline to online store, keeping them fresh.

### Tools

Feast (open source), Tecton (managed), Hopsworks, SageMaker Feature Store, Vertex AI Feature Store.

### Interview Tip

When designing a recommendation system or fraud detection system, mention a feature store to show you understand the importance of consistent feature computation between training and serving. Discuss the latency requirements for the online store and how frequently features need to be refreshed.

---

## Embedding Storage & Retrieval

Embeddings are dense vector representations of data (text, images, users, products). Storing, indexing, and retrieving them efficiently is central to modern AI applications.

### Storage Options

| Option | Scale | Latency | Ops Overhead | Best For |
|---|---|---|---|---|
| **pgvector** (PostgreSQL) | < 5M vectors | 100-200ms | Low (it is just Postgres) | Small-medium datasets, co-located with relational data |
| **Pinecone** | Billions | < 50ms | None (managed) | Production vector search, serverless |
| **Weaviate** | Hundreds of millions | < 100ms | Moderate | Hybrid search (vector + keyword) |
| **Qdrant** | Hundreds of millions | < 50ms | Moderate | Filtering + vector search |
| **Milvus** | Billions | < 100ms | Higher | Large-scale, self-hosted |
| **Elasticsearch (knn)** | Hundreds of millions | < 100ms | Moderate | Adding vector search to existing ES |

### Indexing for Speed

Brute-force search (compare query vector to every stored vector) is O(N) and does not scale. Approximate Nearest Neighbor (ANN) algorithms trade a small accuracy loss for dramatic speed gains:

- **HNSW (Hierarchical Navigable Small World):** Graph-based index. Build a multi-layer graph where higher layers are sparse (for fast traversal) and lower layers are dense (for precision). Query: start at top layer, greedily navigate to approximate nearest neighbor. Dominant in production due to excellent query speed.
- **IVF (Inverted File Index):** Cluster vectors (k-means), then at query time search only the nearest clusters. Faster build than HNSW, lower memory, slightly less accurate.
- **Product Quantization (PQ):** Compress vectors by splitting them into subvectors and quantizing each. Dramatically reduces memory (10-50x) at the cost of accuracy. Often combined with IVF (IVF-PQ).

### Hybrid Search

Pure vector search misses exact keyword matches. Pure keyword search (BM25) misses semantic similarity. Hybrid search combines both:

```
Query: "best Ruby ORM for PostgreSQL"

Vector search results:     BM25 keyword results:
  1. ActiveRecord guide      1. "Ruby PostgreSQL ORM comparison"
  2. Sequel tutorial          2. "ActiveRecord PostgreSQL setup"
  3. ROM framework            3. "Best ORMs for Ruby developers"

Reciprocal Rank Fusion (RRF):
  score(doc) = sum(1 / (k + rank_in_list)) for each list
  -> Merged, re-ranked results
```

Hybrid search with RRF shows 15-30% better retrieval accuracy than either approach alone. This is now considered baseline for production RAG.

---

## RAG Architecture (Retrieval-Augmented Generation)

RAG combines information retrieval with LLM generation. Instead of relying solely on the model's training data, RAG retrieves relevant context from a knowledge base and includes it in the prompt.

### Why RAG

- LLMs have knowledge cutoffs (do not know recent information)
- LLMs hallucinate (confidently generate false information)
- RAG grounds responses in actual documents, reducing hallucination
- RAG allows domain-specific knowledge without fine-tuning the model

### Two-Phase Architecture

```
OFFLINE (Indexing Pipeline -- runs once or periodically):
  Documents -> Chunking -> Embedding -> Vector Store
                |
                v
         Chunk strategy:
         - Fixed size (512 tokens, 20% overlap)
         - Semantic (split at paragraph/section boundaries)
         - Hierarchical (parent-child chunks for context)

ONLINE (Query Pipeline -- runs per request):
  User Query -> Embed Query -> Vector Search (retrieve top-K chunks)
                                    |
                                    v
                              Re-ranking (optional, cross-encoder)
                                    |
                                    v
                              Prompt Assembly:
                              "Given this context: {chunks}
                               Answer this question: {query}"
                                    |
                                    v
                              LLM Generation -> Response
```

### Key Design Decisions

**Chunking strategy:** One of the highest-signal topics in RAG interviews. Too small: chunks lack context. Too large: dilute relevance. Best practices: 256-1024 tokens with 10-20% overlap, split at semantic boundaries (paragraphs, sections), include document metadata.

**Embedding model:** OpenAI `text-embedding-3-large` (1536 dims), Cohere `embed-v3`, or open-source models (BGE, E5). Smaller models (384 dims) are faster and cheaper; larger models are more accurate.

**Retrieval count (top-K):** More chunks = more context but more noise. Typical: retrieve 10-20, re-rank, pass top 3-5 to the LLM.

**Re-ranking:** A cross-encoder (e.g., Cohere Rerank, BGE-reranker) scores each (query, chunk) pair for relevance. More accurate than pure vector similarity but slower (must evaluate each pair). Applied to top-K candidates.

### Advanced RAG Patterns

- **Query transformation:** Rewrite the user query for better retrieval (expand acronyms, decompose multi-part questions)
- **Hypothetical Document Embedding (HyDE):** Generate a hypothetical answer, embed it, use that embedding for retrieval (finds more relevant chunks than the raw query)
- **Self-RAG:** The LLM decides whether to retrieve, evaluates retrieval quality, and generates citations
- **Agentic RAG:** The LLM uses tools to decide what to retrieve, from which sources, and iterates until it has sufficient information

---

## GPU Scheduling

GPU resources are expensive and scarce. Efficient scheduling maximizes utilization while meeting latency SLAs.

### Challenges

- **GPU memory fragmentation:** Large models may need contiguous memory blocks
- **Multi-tenancy:** Multiple models sharing GPUs without interference
- **Heterogeneous hardware:** Mix of A100, H100, L40S GPUs with different capabilities
- **Preemption:** Should a high-priority inference request preempt a training job?

### Approaches

**Kubernetes + NVIDIA Device Plugin:** Basic GPU allocation -- one GPU per pod. Simple but wastes resources if a pod does not fully utilize the GPU.

**GPU sharing (MIG, MPS):** NVIDIA Multi-Instance GPU (MIG) physically partitions an A100/H100 into isolated instances. Multi-Process Service (MPS) allows multiple processes to share a GPU with time-slicing.

**Dedicated schedulers:** KubeRay, Run:ai, Volcano -- GPU-aware schedulers that understand model requirements, memory, and multi-GPU jobs.

### Inference Optimization

| Technique | Speedup | Accuracy Loss | When to Use |
|---|---|---|---|
| **FP16/BF16** | 2x | Minimal | Almost always |
| **INT8 quantization** | 2-4x | Small | Latency-sensitive, moderate quality OK |
| **INT4 quantization** | 4-8x | Moderate | Edge deployment, cost-sensitive |
| **KV cache optimization** | Variable | None | LLM inference (vLLM's PagedAttention) |
| **Speculative decoding** | 1.5-3x | None | LLM inference |
| **Continuous batching** | 2-5x throughput | None | High-throughput serving |

---

## A/B Testing ML Models

A/B testing ML models has unique challenges compared to testing UI changes.

### Challenges

- **Delayed feedback:** A recommendation model's success might not be measurable for days (did the user buy the product?)
- **Metric sensitivity:** ML model differences may be small (0.1% CTR improvement) requiring large sample sizes
- **Feature interactions:** Changing one model may affect features used by another
- **Winner determination:** Statistical significance is harder when effects are small

### Traffic Splitting Approaches

- **Random split:** Route N% of users to the new model. Standard A/B test.
- **Shadow mode:** Run the new model in parallel but do not serve its results. Compare outputs offline. Safe but does not capture user interaction effects.
- **Interleaved experiments:** Mix results from both models in the same response (e.g., search results). More sensitive to differences with less traffic.
- **Multi-armed bandit:** Dynamically shift traffic toward the better-performing model. Faster convergence but harder to analyze.

### Online Evaluation Metrics

| Metric Type | Examples |
|---|---|
| **Engagement** | Click-through rate, time on page, scroll depth |
| **Revenue** | Conversion rate, revenue per session, average order value |
| **Quality** | NDCG (search ranking), precision@K, user satisfaction score |
| **System** | Latency p50/p99, error rate, GPU utilization |

---

## LLM Caching & Routing

As LLM inference is expensive (both in latency and cost), caching and intelligent routing are critical for production LLM applications.

### Semantic Caching

Unlike exact-match caching, semantic caching recognizes that different phrasings of the same question should return the same cached answer.

```
Query: "What is the capital of France?"
  -> Cache MISS, call LLM, store response with query embedding

Query: "capital city of France"
  -> Embed query, find similar cached query (cosine similarity > 0.95)
  -> Cache HIT, return cached response

Query: "What is the capital of Germany?"
  -> Similar phrasing but different intent
  -> Cosine similarity < threshold
  -> Cache MISS, call LLM
```

**Trade-offs:** Requires a vector store for cache keys. Similarity threshold must be tuned carefully -- too low and you return wrong answers; too high and the cache hit rate is low.

### LLM Routing

Route requests to different models based on complexity, cost, and latency requirements:

```
User Query -> Classifier/Router
                |
    +-----------+-----------+
    |           |           |
  Simple    Medium       Complex
  (GPT-4o   (Claude      (Claude
   mini)     Sonnet)      Opus)
```

**Routing strategies:**
- **Keyword/rule-based:** Simple queries to cheap models, complex to expensive
- **Classifier-based:** Train a small model to predict query complexity
- **Cascading:** Try the cheapest model first; if confidence is low, escalate to a more capable model
- **Cost-aware:** Set a per-request budget and route accordingly

### Prompt Caching

LLM providers (Anthropic, OpenAI) now offer prompt caching: if the prefix of your prompt matches a recent request, the cached KV-cache is reused, reducing both latency and cost. This is especially valuable for RAG systems where the system prompt and context are often identical.

---

## Putting It Together: ML System Design Framework

```
1. Problem Framing
   - What are you predicting/generating?
   - Online or batch inference?
   - Latency and throughput requirements?

2. Data Pipeline
   - Where does training data come from?
   - Feature engineering (feature store for consistency)
   - Data versioning and quality checks

3. Model Training
   - Model selection and architecture
   - Training infrastructure (distributed training, GPU scheduling)
   - Experiment tracking (MLflow, W&B)

4. Model Serving
   - Serving framework (Triton, vLLM, TorchServe)
   - Optimization (quantization, batching, caching)
   - Canary deployment and rollback

5. Retrieval (if RAG)
   - Chunking and embedding pipeline
   - Vector store selection and indexing
   - Hybrid search + re-ranking

6. Evaluation
   - Offline metrics (accuracy, F1, NDCG)
   - Online metrics (A/B testing, business metrics)
   - Feedback loops (retrain on production data)

7. Monitoring
   - Model drift detection
   - Data quality monitoring
   - Latency, error rate, cost tracking
```

---

## Related Topics

- [[../01-databases-and-storage/index|Databases & Storage]] -- vector databases, storage options
- [[../02-scaling-reads/index|Scaling Reads]] -- caching strategies for model outputs
- [[../05-async-processing/index|Async Processing]] -- batch inference pipelines, training job orchestration
- [[../08-api-gateway-and-service-mesh/index|API Gateway]] -- model serving behind gateways, LLM routing
- [[../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- handling model serving failures, fallback models
