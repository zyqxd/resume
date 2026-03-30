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

### [[scaling-reads/index|Scaling Reads]]

Most production systems are read-heavy. Scaling reads involves caching strategies (write-through, write-back, write-around, cache-aside), read replicas, CDNs, indexing strategies (B-tree, LSM-tree, covering indexes), materialized views, and denormalization. Understanding when to cache versus replicate versus denormalize -- and the consistency trade-offs of each -- is fundamental to every system design discussion.

### [[scaling-writes/index|Scaling Writes]]

Scaling writes is harder than reads because writes must maintain data integrity. Core strategies include sharding (hash, range, geo), consistent hashing, write batching, WAL (Write-Ahead Logging), async writes, CQRS, and event sourcing. Sharding decisions are among the most impactful in a system design -- a poor shard key can create hot spots that undermine the entire scaling strategy.

### [[real-time-systems/index|Real-Time Systems]]

Real-time communication underpins chat, collaborative editing, live dashboards, notifications, and gaming. Key technologies are WebSockets, Server-Sent Events, long polling, pub/sub architectures, and fan-out patterns. Advanced topics include presence systems and conflict-free replicated data types (CRDTs) for collaborative editing. The scaling challenge is fan-out: delivering a message to millions of subscribers with low latency.

### [[async-processing/index|Async Processing]]

Asynchronous processing decouples time-sensitive request handling from background work. Core tools are message queues (Kafka, RabbitMQ, SQS), worker pools, saga pattern, workflow engines (Temporal), dead letter queues, and backpressure mechanisms. Understanding delivery guarantees (at-most-once, at-least-once, exactly-once) and when to use each queue technology is essential for any system that does work beyond the request-response cycle.

### [[fault-tolerance-and-reliability/index|Fault Tolerance & Reliability]]

In distributed systems, failures are the norm. This topic covers retries with exponential backoff and jitter, idempotency keys, circuit breakers, bulkheads, health checks, self-healing, chaos engineering, and graceful degradation. A Staff-level answer shows layered defense: rate limiting at the gateway, circuit breakers at the service level, idempotency at the data level, and self-healing at the infrastructure level.

### [[databases-and-storage/index|Databases & Storage]]

Choosing the right database is one of the most consequential design decisions. This covers SQL vs NoSQL selection, CAP theorem and PACELC, consistency models, transaction isolation levels, database-per-service, polyglot persistence, time-series databases, and vector databases. The 2025 landscape adds vector DBs as a critical storage primitive for AI-powered features. The key skill is matching storage technology to workload characteristics.

### [[distributed-systems-fundamentals/index|Distributed Systems Fundamentals]]

The theoretical foundation for everything else. Covers consensus algorithms (Raft, Paxos), leader election, distributed locks, clock synchronization (Lamport clocks, vector clocks), partition tolerance, two-phase commit, gossip protocols, and quorums. You do not need to implement Raft in an interview, but you must understand why it exists, what it guarantees, and when to use consensus-based systems.

### [[api-gateway-and-service-mesh/index|API Gateway & Service Mesh]]

Traffic management in microservices architectures. Covers load balancing strategies (round robin, least connections, P2C), rate limiting algorithms (token bucket, sliding window), service discovery, API gateway patterns (BFF, aggregation), sidecar proxy, mTLS, and observability (metrics, logs, traces, OpenTelemetry). These are the operational patterns that make production systems actually work.

### [[ml-ai-infrastructure/index|ML/AI Infrastructure]]

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

---

## Resources

- [System Design Primer (GitHub)](https://github.com/donnemartin/system-design-primer) -- comprehensive reference with diagrams
- [Hello Interview: System Design in a Hurry](https://www.hellointerview.com/learn/system-design/in-a-hurry/introduction) -- structured learning path
- [Tech Interview Handbook: System Design](https://www.techinterviewhandbook.org/system-design/) -- framework and tips
