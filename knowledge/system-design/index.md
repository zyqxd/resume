# System Design Interview Prep

System design interviews evaluate your ability to architect large-scale distributed systems under realistic constraints. At the Staff level, interviewers expect you to drive the conversation: identify the right questions to ask, make and justify design decisions with clear trade-off analysis, go deep on the components that matter most, and demonstrate practical experience with production systems. The landscape has shifted in 2025-2026 -- AI/ML infrastructure is now a first-class topic, and interviewers increasingly expect candidates to discuss embedding systems, RAG architectures, and model serving alongside the traditional scaling, storage, and reliability topics.

---

## How to Approach System Design Interviews

### The Framework (adapt, do not follow rigidly)

**1. Requirements Clarification (3-5 minutes)**
Ask questions to narrow scope. Identify functional requirements (what the system does), non-functional requirements (scale, latency, availability), and what is explicitly out of scope. This is where Staff candidates differentiate -- you should be driving the scoping, not waiting for the interviewer to tell you.

**2. Back-of-the-Envelope Estimation (2-3 minutes)**
Estimate scale: QPS, storage, bandwidth. This informs which components need to scale and where bottlenecks will appear. Do not spend too long here -- rough orders of magnitude are sufficient.

**3. High-Level Design (5-10 minutes)**
Draw the major components and their interactions. Start with the data flow: how does a request enter the system, where is data stored, how is it served? Identify the 2-3 components that are most architecturally interesting.

**4. Deep Dives (15-25 minutes)**
This is where you spend most of your time. Pick the most interesting/challenging components and go deep. Discuss data models, algorithms, trade-offs, failure modes, and scaling strategies. The interviewer may redirect you -- follow their lead.

**5. Wrap-Up (2-3 minutes)**
Summarize key decisions and trade-offs. Mention what you would add with more time (monitoring, security, edge cases).

### Staff-Level Differentiators

- **Drive the conversation.** Do not wait to be asked about trade-offs -- proactively discuss them.
- **Justify decisions with context.** "I chose Kafka here because we need ordered, durable event delivery and the ability to replay" beats "we can use Kafka."
- **Discuss failure modes.** What happens when this component fails? How do we detect it? How do we recover?
- **Show breadth and depth.** Cover the full architecture at a high level, then go deep on the hardest parts.
- **Connect to real experience.** "At my previous company, we hit this exact problem and solved it by..." (but do not ramble).

---

## Topics

### 1. [[01-databases-and-storage/index|Databases & Storage]]

Choosing the right database is one of the most consequential design decisions — every design starts with "where does the data live?" This covers SQL vs NoSQL selection, CAP theorem and PACELC, consistency models, transaction isolation levels, database-per-service, polyglot persistence, time-series databases, and vector databases. The 2025 landscape adds vector DBs as a critical storage primitive for AI-powered features. The key skill is matching storage technology to workload characteristics.

### 2. [[02-scaling-reads/index|Scaling Reads]]

Most production systems are read-heavy. Scaling reads involves caching strategies (write-through, write-back, write-around, cache-aside), read replicas, CDNs, indexing strategies (B-tree, LSM-tree, covering indexes), materialized views, and denormalization. Understanding when to cache versus replicate versus denormalize -- and the consistency trade-offs of each -- is fundamental to every system design discussion.

### 3. [[03-scaling-writes/index|Scaling Writes]]

Scaling writes is harder than reads because writes must maintain data integrity. Core strategies include sharding (hash, range, geo), consistent hashing, write batching, WAL (Write-Ahead Logging), async writes, CQRS, and event sourcing. Sharding decisions are among the most impactful in a system design -- a poor shard key can create hot spots that undermine the entire scaling strategy.

### 4. [[04-fault-tolerance-and-reliability/index|Fault Tolerance & Reliability]]

In distributed systems, failures are the norm. This topic covers retries with exponential backoff and jitter, idempotency keys, circuit breakers, bulkheads, health checks, self-healing, chaos engineering, and graceful degradation. A Staff-level answer shows layered defense: rate limiting at the gateway, circuit breakers at the service level, idempotency at the data level, and self-healing at the infrastructure level.

### 5. [[05-async-processing/index|Async Processing]]

Asynchronous processing decouples time-sensitive request handling from background work. Core tools are message queues (Kafka, RabbitMQ, SQS), worker pools, saga pattern, workflow engines (Temporal), dead letter queues, and backpressure mechanisms. Understanding delivery guarantees (at-most-once, at-least-once, exactly-once) and when to use each queue technology is essential for any system that does work beyond the request-response cycle.

### 6. [[06-distributed-systems-fundamentals/index|Distributed Systems Fundamentals]]

The theoretical foundation for everything else. Covers consensus algorithms (Raft, Paxos), leader election, distributed locks, clock synchronization (Lamport clocks, vector clocks), partition tolerance, two-phase commit, gossip protocols, and quorums. You do not need to implement Raft in an interview, but you must understand why it exists, what it guarantees, and when to use consensus-based systems.

### 7. [[07-real-time-systems/index|Real-Time Systems]]

Real-time communication underpins chat, collaborative editing, live dashboards, notifications, and gaming. Key technologies are WebSockets, Server-Sent Events, long polling, pub/sub architectures, and fan-out patterns. Advanced topics include presence systems and conflict-free replicated data types (CRDTs) for collaborative editing. The scaling challenge is fan-out: delivering a message to millions of subscribers with low latency.

### 8. [[08-api-gateway-and-service-mesh/index|API Gateway & Service Mesh]]

Traffic management in microservices architectures. Covers load balancing strategies (round robin, least connections, P2C), rate limiting algorithms (token bucket, sliding window), service discovery, API gateway patterns (BFF, aggregation), sidecar proxy, mTLS, and observability (metrics, logs, traces, OpenTelemetry). These are the operational patterns that make production systems actually work.

### 9. [[09-ml-ai-infrastructure/index|ML/AI Infrastructure]]

The newest and fastest-growing topic area. Covers model serving at scale, feature stores, embedding storage and retrieval, RAG architecture, GPU scheduling, A/B testing ML models, and LLM caching/routing. Even for non-ML roles, understanding how to build infrastructure for AI features (semantic search, recommendations, conversational AI) is increasingly expected at the Staff level.

---

## Exercises

Practice these end-to-end system design exercises. Each includes a prompt with constraints and a detailed walkthrough showing how to approach it step by step.

### [[exercises/01-collaborative-document-editor/PROMPT|Exercise 1: Real-Time Collaborative Document Editor]]

Design a system like Google Docs. Covers CRDTs vs Operational Transformation, WebSocket scaling, conflict resolution, offline editing, and cursor synchronization. This exercise tests your understanding of real-time systems, distributed consistency, and managing concurrent writes.

**[[exercises/01-collaborative-document-editor/WALKTHROUGH|Full walkthrough]]**

### [[exercises/02-ai-powered-search/PROMPT|Exercise 2: AI-Powered Search System]]

Design an e-commerce search system combining keyword and semantic search. Covers embedding generation, vector databases, hybrid search with RRF, RAG for product Q&A, personalized ranking, and LLM caching. This exercise is representative of the new wave of AI-integrated system design questions.

**[[exercises/02-ai-powered-search/WALKTHROUGH|Full walkthrough]]**

### [[exercises/03-distributed-task-scheduler/PROMPT|Exercise 3: Distributed Task Scheduler]]

Design a distributed cron-like system. Covers partitioned polling, consensus-based coordination, exactly-once semantics via idempotency, worker pool scaling, multi-tenant isolation, and failure recovery. This exercise tests distributed systems fundamentals and fault tolerance.

**[[exercises/03-distributed-task-scheduler/WALKTHROUGH|Full walkthrough]]**

### Shopify System Design Exercises

Commerce-specific system design exercises modeled after Shopify's most frequently asked interview questions. Start with the **[[exercises/shopify-crash-course|Shopify Staff System Design Crash Course]]** for a self-contained guide to the architecture patterns, technology choices, and failure modes. The [[exercises/shopify-patterns|cross-cutting patterns and gotchas]] reference maps these patterns back to specific exercises.

### [[exercises/04-shopify-checkout-system/PROMPT|Exercise 4: Checkout System (Shopify)]]

Design a checkout system handling BFCM-scale traffic. Covers CartSink/CardServer PCI isolation, the Resumption pattern for exactly-once payments, cart-to-order state machines, and multi-provider failover with Semian circuit breakers.

**[[exercises/04-shopify-checkout-system/WALKTHROUGH|Full walkthrough]]**

### [[exercises/05-shopify-flash-sale-system/PROMPT|Exercise 5: Flash Sale / BFCM Traffic (Shopify)]]

Design a system handling 284M req/min during flash sales. Covers pod-based scaling, Sorting Hat load shedding, storefront extraction, queue-based admission control, and pre-event preparation with Genghis load testing.

**[[exercises/05-shopify-flash-sale-system/WALKTHROUGH|Full walkthrough]]**

### [[exercises/06-shopify-inventory-management/PROMPT|Exercise 6: Inventory Management (Shopify)]]

Design real-time inventory tracking across warehouses and channels. Covers reservation-based allocation with TTL, adaptive concurrency control (optimistic + pessimistic), cross-channel sync via Kafka, and oversell prevention under flash sale concurrency.

**[[exercises/06-shopify-inventory-management/WALKTHROUGH|Full walkthrough]]**

### [[exercises/07-shopify-multi-tenant-platform/PROMPT|Exercise 7: Multi-Tenant Platform (Shopify)]]

Design pod-based multi-tenant architecture for millions of merchants. Covers database-per-pod sharding, Sorting Hat routing, Ghostferry zero-downtime migration, noisy neighbor prevention, and Packwerk module boundaries.

**[[exercises/07-shopify-multi-tenant-platform/WALKTHROUGH|Full walkthrough]]**

### [[exercises/08-shopify-webhook-delivery/PROMPT|Exercise 8: Webhook Delivery (Shopify)]]

Design webhook delivery for thousands of third-party apps. Covers at-least-once delivery, Kafka-based event ingestion, per-endpoint queue isolation, HMAC signing, exponential backoff with jitter, and BFCM-scale fan-out.

**[[exercises/08-shopify-webhook-delivery/WALKTHROUGH|Full walkthrough]]**

### [[exercises/09-shopify-product-search/PROMPT|Exercise 9: Product Search (Shopify)]]

Design multi-tenant product search with variant-aware indexing. Covers hybrid index isolation, CDC-based real-time updates, faceted search, merchant-customizable relevance boosting, autocomplete, and AI-powered discovery extensions.

**[[exercises/09-shopify-product-search/WALKTHROUGH|Full walkthrough]]**

### [[exercises/10-shopify-rate-limiting/PROMPT|Exercise 10: Rate Limiting (Shopify)]]

Design cost-based rate limiting for a GraphQL API. Covers static query complexity analysis, leaky bucket with distributed Redis enforcement, fail-open policy, per-app per-merchant buckets, and local approximation for sub-ms latency.

**[[exercises/10-shopify-rate-limiting/WALKTHROUGH|Full walkthrough]]**

### [[exercises/11-shopify-payment-processing/PROMPT|Exercise 11: Payment Processing (Shopify)]]

Design a PCI-compliant payment pipeline. Covers CardSink/CardServer tokenization, the Resumption pattern for exactly-once semantics, payment state machines, multi-gateway waterfall failover, and per-region Semian circuit breakers.

**[[exercises/11-shopify-payment-processing/WALKTHROUGH|Full walkthrough]]**

---

## Resources

- [System Design Primer (GitHub)](https://github.com/donnemartin/system-design-primer) -- comprehensive reference with diagrams
- [Hello Interview: System Design in a Hurry](https://www.hellointerview.com/learn/system-design/in-a-hurry/introduction) -- structured learning path
- [Tech Interview Handbook: System Design](https://www.techinterviewhandbook.org/system-design/) -- framework and tips
