# Databases & Storage

Choosing the right database is one of the most consequential decisions in system design. There is no universal best database -- the right choice depends on access patterns, consistency requirements, scale, and operational constraints. This section covers **SQL vs NoSQL selection criteria**, **CAP theorem and PACELC**, **consistency models**, **transaction isolation levels**, **database per service**, **polyglot persistence**, **time-series databases**, and **vector databases** (increasingly important in the AI era). A Staff-level answer demonstrates the ability to match storage technology to workload characteristics and articulate the trade-offs clearly.

---

## SQL Databases (Relational)

Relational databases (PostgreSQL, MySQL, SQL Server) store data in tables with predefined schemas and support ACID transactions. They excel when data has clear relationships, requires complex queries (joins, aggregations), and demands strong consistency.

### ACID Properties

| Property | Description |
|---|---|
| **Atomicity** | A transaction either fully completes or fully rolls back. No partial writes. |
| **Consistency** | Transactions move the database from one valid state to another. Constraints are always enforced. |
| **Isolation** | Concurrent transactions do not interfere with each other (to varying degrees, see isolation levels). |
| **Durability** | Once committed, data survives crashes (via WAL). |

### When to Choose SQL

- Data has strong relationships (orders -> line items -> products)
- You need complex queries with joins and aggregations
- ACID transactions are required (financial systems, inventory management)
- Schema is relatively stable and well-understood
- Dataset fits on a single machine or a small number of read replicas

### Limitations

- Horizontal scaling is hard (sharding relational data with foreign keys is painful)
- Schema migrations on large tables can be slow and disruptive
- Write throughput is limited by single-primary architecture

---

## NoSQL Databases

NoSQL is a broad category encompassing document stores, key-value stores, wide-column stores, and graph databases. They prioritize scalability, flexibility, and specific access patterns over general-purpose querying.

### Document Stores (MongoDB, DynamoDB, CouchDB)

Store data as semi-structured documents (JSON/BSON). Each document can have a different structure.

**Best for:** Variable schemas, hierarchical data, rapid iteration, document-oriented access (fetch entire document by key).

**Trade-offs:** No joins (denormalize or do application-side joins). Weaker consistency guarantees (though many now offer tunable consistency). Aggregation queries are less efficient than SQL.

### Key-Value Stores (Redis, DynamoDB, etcd)

Simplest model: store and retrieve values by key. Extremely fast for single-key lookups.

**Best for:** Caching, session storage, configuration, feature flags, rate limiting counters.

**Trade-offs:** No query language beyond key lookup. Range queries only if the store supports sorted keys. No relationships.

### Wide-Column Stores (Cassandra, HBase, ScyllaDB)

Store data in rows with dynamic columns grouped into column families. Optimized for write-heavy workloads and wide-row access patterns.

**Best for:** Time-series data, IoT sensor data, event logs, high-write-throughput workloads, geographically distributed data.

**Trade-offs:** Limited query flexibility (must design schema around query patterns). Eventual consistency by default. No joins.

### Graph Databases (Neo4j, Amazon Neptune, DGraph)

Store data as nodes and edges with properties. Optimized for traversing relationships.

**Best for:** Social networks, recommendation engines, fraud detection, knowledge graphs, any domain where the relationships between entities are as important as the entities themselves.

**Trade-offs:** Not suited for non-graph workloads. Scaling horizontally is challenging. Smaller ecosystem and fewer operational tools than relational databases.

---

## CAP Theorem

The CAP theorem states that a distributed data store can provide at most two of three guarantees:

- **Consistency (C):** Every read receives the most recent write
- **Availability (A):** Every request receives a response (not an error)
- **Partition tolerance (P):** The system continues to operate despite network partitions

Since network partitions are unavoidable in distributed systems, the practical choice is between **CP** (consistency over availability during partitions) and **AP** (availability over consistency during partitions).

```
        Consistency
           /\
          /  \
         /    \
    CP  /  CAP  \  CA (not practical in
       /  (not    \  distributed systems)
      /  possible) \
     /              \
    +----- AP -------+
  Availability     Partition Tolerance
```

### Examples

| System | CAP Trade-off | Behavior During Partition |
|---|---|---|
| PostgreSQL (single node) | CA (no partitions) | N/A (not distributed) |
| ZooKeeper, etcd | CP | Refuses writes if quorum lost |
| Cassandra, DynamoDB | AP | Accepts writes, reconciles later |
| MongoDB (default) | CP | Primary election, brief unavailability |

### PACELC Extension

PACELC extends CAP: if there is a **P**artition, choose between **A**vailability and **C**onsistency; **E**lse (normal operation), choose between **L**atency and **C**onsistency.

This captures the fact that even without partitions, there is a trade-off: stronger consistency requires coordination (higher latency), while weaker consistency allows faster responses.

| System | During Partition (PAC) | Normal Operation (ELC) |
|---|---|---|
| Cassandra | PA | EL (fast, eventually consistent) |
| DynamoDB | PA | EL (eventual by default) |
| MongoDB | PC | EC (consistent, higher latency) |
| PostgreSQL + sync replicas | PC | EC (consistent, higher latency) |
| CockroachDB | PC | EC (serializable, higher latency) |

**Interview tip:** CAP is often oversimplified. Discuss PACELC to show deeper understanding. Also note that CAP applies to the *entire system* -- a single system can make different trade-offs for different data (e.g., user profiles = eventual consistency, account balance = strong consistency).

---

## Consistency Models

Consistency models define what guarantees a system provides about the order and visibility of operations.

### Strong Consistency (Linearizability)

Every read returns the most recent write. Operations appear to execute atomically in a single total order. This is what you get from a single-node database or a consensus-based replicated system (etcd, CockroachDB).

**Cost:** Higher latency (requires quorum writes/reads or leader-based coordination).

### Sequential Consistency

Operations from each client appear in the order the client issued them, but operations from different clients may be interleaved arbitrarily. Weaker than linearizability (no real-time ordering guarantee).

### Causal Consistency

Operations that are causally related appear in the same order at all replicas. Concurrent operations (no causal relation) may appear in different orders at different replicas.

**Example:** If User A posts a message and User B replies, all replicas see A's message before B's reply. But two unrelated posts may appear in different orders.

### Eventual Consistency

If no new writes occur, all replicas will eventually converge to the same value. No guarantee about *when* they converge or what intermediate states are visible.

**Good enough for:** Caches, social media feeds, product catalogs, analytics.

### Spectrum

```
Strong -----> Sequential -----> Causal -----> Eventual
(slowest,                                     (fastest,
 safest)                                       riskiest)
```

---

## Transaction Isolation Levels

Isolation levels control how much concurrent transactions can "see" each other's uncommitted work. Higher isolation prevents more anomalies but reduces concurrency.

| Level | Dirty Read | Non-Repeatable Read | Phantom Read | Performance |
|---|---|---|---|---|
| **Read Uncommitted** | Possible | Possible | Possible | Highest |
| **Read Committed** | Prevented | Possible | Possible | Good |
| **Repeatable Read** | Prevented | Prevented | Possible | Moderate |
| **Serializable** | Prevented | Prevented | Prevented | Lowest |

### Anomalies Explained

- **Dirty read:** Reading data written by a transaction that has not yet committed (and might roll back)
- **Non-repeatable read:** Reading the same row twice in a transaction and getting different values (another transaction committed an update between reads)
- **Phantom read:** A range query returns different rows on re-execution (another transaction inserted/deleted rows)

### MVCC (Multi-Version Concurrency Control)

Most modern databases (PostgreSQL, MySQL InnoDB) use MVCC to implement isolation without heavy locking. Each transaction sees a snapshot of the database at a specific point in time. Writers create new versions of rows; readers see the version consistent with their snapshot.

**PostgreSQL default:** Read Committed. **MySQL InnoDB default:** Repeatable Read.

**Interview tip:** Know the default isolation level of the databases you discuss and be prepared to explain why you would change it. Serializable is the safest but can cause more aborted transactions due to serialization conflicts.

---

## Database Per Service

In a microservices architecture, each service owns its data and exposes it only through its API. No service directly accesses another service's database.

### Benefits

- **Independent scaling** -- each service chooses the database technology and scale appropriate for its workload
- **Independent deployment** -- schema changes do not cascade across services
- **Fault isolation** -- a database failure affects only one service

### Challenges

- **Cross-service queries** -- no joins across service boundaries. Requires API composition or denormalization.
- **Distributed transactions** -- cannot use a single database transaction. Use [[../05-async-processing/index|sagas]] instead.
- **Data consistency** -- eventual consistency between services. Events/CDC propagate changes.

---

## Polyglot Persistence

Use different database technologies for different parts of the system, chosen based on each workload's characteristics.

```
User Service          -> PostgreSQL (relational, ACID)
Product Catalog       -> MongoDB (flexible schema, document access)
Shopping Cart         -> Redis (fast, ephemeral)
Search                -> Elasticsearch (full-text search, faceted queries)
Analytics/Reporting   -> ClickHouse (columnar, fast aggregations)
Recommendations       -> Neo4j (graph relationships)
AI/Embeddings         -> Pinecone/pgvector (vector similarity search)
```

**Trade-offs:** Operational complexity increases with each new database technology. Each requires different monitoring, backup, upgrade, and scaling procedures. Use polyglot persistence only when the performance or capability gains justify the operational cost.

---

## Time-Series Databases

Time-series databases (TimescaleDB, InfluxDB, QuestDB) are optimized for data that is naturally ordered by time: metrics, IoT sensor data, financial ticks, event logs.

### Why Not a Regular Database?

- **Write pattern:** Append-only, high-ingestion rate (millions of data points per second)
- **Read pattern:** Range queries by time window, aggregations (avg, max, percentile over last hour)
- **Retention:** Old data can be downsampled or expired automatically
- **Compression:** Time-series data has high temporal locality, enabling 10-20x compression

### Key Features

- Automatic partitioning by time (time-bucketed chunks)
- Built-in downsampling and retention policies
- Time-windowed aggregation functions
- High write throughput with columnar storage

**TimescaleDB** is notable because it is built on PostgreSQL -- you get time-series performance with full SQL compatibility.

---

## Vector Databases (AI Era)

Vector databases store and query high-dimensional vectors (embeddings). They are the backbone of semantic search, recommendation systems, and RAG (Retrieval-Augmented Generation) architectures that power modern AI applications.

### What Are Embeddings?

An embedding is a dense numerical vector (typically 768-1536 dimensions) that captures the semantic meaning of text, images, or other data. Similar items have vectors that are close together in the embedding space.

```
"How to cook pasta" -> [0.12, -0.34, 0.56, ..., 0.78]  (1536 dims)
"Pasta recipe"      -> [0.11, -0.33, 0.55, ..., 0.77]  (nearby!)
"Quantum physics"   -> [0.89, 0.12, -0.67, ..., -0.23] (far away)
```

### Similarity Search

Vector databases perform **approximate nearest neighbor (ANN)** search to find the most similar vectors to a query vector. ANN trades a small amount of accuracy for dramatic speed improvements over brute-force search.

### Indexing Algorithms

| Algorithm | Description | Trade-off |
|---|---|---|
| **HNSW** (Hierarchical Navigable Small World) | Graph-based index with multiple layers. Dominant in production. | High memory, excellent query speed |
| **IVF** (Inverted File Index) | Clusters vectors, searches nearest clusters | Lower memory, slightly less accurate |
| **PQ** (Product Quantization) | Compresses vectors, loses some accuracy | Much lower memory, reduced accuracy |
| **Flat/Brute-force** | Exact search, no index | Perfect accuracy, does not scale |

### Options

**Dedicated vector DBs:** Pinecone, Weaviate, Qdrant, Milvus -- purpose-built for vector search at scale.

**pgvector (PostgreSQL extension):** Adds vector columns and ANN search to PostgreSQL. Compelling for datasets under 5M vectors or when you want to keep embeddings alongside relational data (no separate infrastructure).

**Hybrid search:** Combine vector similarity with keyword search (BM25) using Reciprocal Rank Fusion (RRF) for 15-30% better retrieval accuracy than pure vector search. This is now considered baseline for production RAG systems.

### RAG Architecture

RAG combines retrieval from a vector database with LLM generation:

```
User Query -> Embed Query -> Vector DB (retrieve relevant docs)
                                |
                                v
                          Retrieved Context + Query -> LLM -> Response
```

See [[../09-ml-ai-infrastructure/index|ML/AI Infrastructure]] for the full RAG system design.

---

## Choosing the Right Database: Decision Framework

```
What is the primary access pattern?
  Key-value lookups -> Redis, DynamoDB
  Document retrieval -> MongoDB, DynamoDB
  Complex relational queries -> PostgreSQL, MySQL
  Graph traversals -> Neo4j, Neptune
  Time-series aggregations -> TimescaleDB, InfluxDB
  Full-text search -> Elasticsearch
  Vector similarity -> Pinecone, pgvector
  Wide-row / high-write -> Cassandra, ScyllaDB

What are the consistency requirements?
  ACID transactions -> PostgreSQL, MySQL, CockroachDB
  Eventual consistency OK -> Cassandra, DynamoDB, MongoDB
  Tunable consistency -> DynamoDB, Cassandra

What is the scale?
  Single region, moderate scale -> PostgreSQL with read replicas
  Multi-region, massive scale -> CockroachDB, Cassandra, DynamoDB

What are the operational constraints?
  Managed/serverless preferred -> DynamoDB, Aurora, Cloud SQL
  Open source, self-hosted -> PostgreSQL, MySQL, Cassandra
  Minimize operational burden -> Start with one database, add others only when needed
```

---

## Related Topics

- [[../02-scaling-reads/index|Scaling Reads]] -- indexing, caching, read replicas
- [[../03-scaling-writes/index|Scaling Writes]] -- sharding, WAL, write-optimized engines
- [[../06-distributed-systems-fundamentals/index|Distributed Systems]] -- consensus, replication, consistency
- [[../09-ml-ai-infrastructure/index|ML/AI Infrastructure]] -- vector DBs in AI systems
- [[../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- database failover and recovery
