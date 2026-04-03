# System Design Cheat Sheet

## 1. Requirements (3-5 min)

Drive the scoping -- don't wait for the interviewer to tell you.

- **Functional**: Core user actions. What does the system do? What's out of scope?
- **Scale**: DAU, read:write ratio, peak vs average traffic, data growth rate
- **Access patterns**: Read-heavy or write-heavy? Bursty or steady? Real-time or batch?
- **Non-functional**: Latency targets, availability (99.9% vs 99.99%), consistency model (strong vs eventual)
- **Data characteristics**: Relational or document? Time-series? Need full-text or semantic search?

## 2. Estimation (2-3 min)

Orders of magnitude only -- this tells you where bottlenecks will live.

- **QPS**: DAU x actions/day / 86,400. Peak = 2-5x average.
- **Storage**: Records x avg size x retention. Growth per year.
- **Benchmarks**: Single Postgres ~10K QPS reads, ~5K writes. Redis ~100K ops/s. Kafka ~1M msgs/s per broker / 10-20Mb per partition.
- **Bandwidth**: QPS x avg payload size.

## 3. High-Level Design (5-10 min)

Draw the data flow: request enters -> processed -> stored -> served. Identify the 2-3 most architecturally interesting components.

**Storage**
- SQL (Postgres, MySQL) -- relational, transactional, CP (strong consistency, sacrifices availability during partition)
- NoSQL: Cassandra -- high-write, flexible schema, AP (available, eventually consistent)
- NoSQL: DynamoDB -- AP default, optional strong reads per-query
- MongoDB -- CP default (single primary), tunable with replica reads
- Redis -- cache, sessions, leaderboards, AP in cluster mode
- Vector DB (Pinecone, pgvector) -- embeddings, semantic search

**Caching**
- Cache-aside -- lazy, most common
- Write-through -- consistent, higher write latency
- Write-back -- fast writes, risk of data loss
- Read replicas -- read-heavy workloads
- CDN -- static assets, geo-distributed
- Materialized views -- expensive aggregations

**Messaging**
- Kafka -- ordered, durable, replayable
- SQS -- simple queue
- RabbitMQ -- routing, priority
- Delivery guarantees: at-most-once, at-least-once, exactly-once
- DLQs for poison messages, backpressure to protect consumers

**Traffic & Networking**
- Load balancer: round robin, least conn, P2C
- API gateway: auth, rate limiting, aggregation
- Rate limiting: token bucket, sliding window
- BFF pattern, service discovery, CDN for edge

**Real-Time**
- WebSockets (bidirectional), SSE (server push), long polling (fallback)
- Pub/sub for fan-out
- CRDTs for collaborative editing
- Scaling challenge = fan-out to millions at low latency

**ML/AI**
- Embedding generation + vector retrieval
- RAG architecture
- Model serving, feature stores
- LLM caching/routing

## 4. Deep Dives (15-25 min)

Pick the hardest components and go deep. Proactively discuss trade-offs and failure modes -- don't wait to be asked. "I chose X because Y" not "we can use X."

**Scaling Reads**
- Caching -- invalidation is the hard part
- Read replicas -- watch for replication lag
- Indexing: B-tree (range), LSM-tree (write-heavy), covering indexes (avoid lookups)
- Denormalization -- trades consistency for read speed

**Scaling Writes**
- Sharding: hash (uniform), range (locality), geo (compliance)
- Consistent hashing -- minimize reshuffling
- Bad shard key = hot spots = game over
- Write batching, WAL
- CQRS / event sourcing for complex domains

**Fault Tolerance**
- Layer defenses: gateway (rate limit) -> service (circuit breaker) -> data (idempotency) -> infra (self-healing)
- Retries with exponential backoff + jitter
- Bulkheads to isolate failures
- Graceful degradation over total outage

**Distributed Fundamentals**
- Consensus (Raft, Paxos) -- leader election, coordination
- Distributed locks (Redlock)
- Lamport / vector clocks -- ordering
- 2PC for cross-service txns (or avoid -- use sagas)
- Gossip for membership
- Quorum reads/writes -- tunable consistency

**Async Patterns**
- Saga: choreography vs orchestration
- Workflow engines (Temporal) for complex multi-step
- Worker pools with autoscaling
- Exactly-once = idempotent consumer + at-least-once delivery

**Observability**
- Metrics, logs, traces (OpenTelemetry)
- mTLS for service-to-service
- Sidecar proxy pattern

## 5. Wrap-Up (2-3 min)

- Summarize the 2-3 key design decisions and their trade-offs
- What you'd add with more time: monitoring/alerting, security, edge cases, multi-region
- Connect to real experience briefly: "At Square we hit this exact problem and solved it by..."
