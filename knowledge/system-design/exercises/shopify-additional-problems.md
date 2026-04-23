# Shopify Staff System Design: Additional Problems Beyond the Core 8

Research synthesis from three sources: candidate interview reports, Shopify's public engineering blog, and emerging AI/infrastructure work. Use this alongside the core 8 (checkout, flash sale, inventory, multi-tenant, webhooks, search, rate limiting, payments).

Each topic is tiered by interview probability and includes a one-line framing, key design considerations, and sources.

**Tier legend:**
- **T1** — High probability; prepare solidly
- **T2** — Medium probability; know the shape
- **T3** — Lower probability; name-drop if it comes up
- **ML** — ML-flavored rounds only
- **Bonus** — Shopify-specialty; unlikely but flagged

---

## Tier 1: High-Probability Problems

### 1. Recommendations / Personalization (Generative Recommender) — T1

**Framing:** Design a product recommendation system that serves real-time suggestions across millions of merchants and the Shop app, using cross-merchant behavioral event sequences.

**Key considerations:**
- **Cold start** for new merchants/products — fall back to popularity-based ranking
- **Cross-merchant data isolation** — don't recommend merchant X's products on merchant Y's store
- **Candidate generation vs ranking pipeline** — retrieve top-K cheaply, re-rank carefully
- **Embedding storage** at billions-of-products scale (pgvector, Weaviate, Pinecone, or Redis)
- **Ensemble with business constraints** (don't recommend competitor's products)
- **Sequence modeling** — autoregressive transformers treating events as tokens (HSTU, generative recommender approach)

**Signal:** Multiple prep guides + Shopify's 2026 public work on generative recommendations. Almost certainly asked.

### 2. Fraud Detection Pipeline — T1

**Framing:** Design a real-time fraud scoring system that evaluates every transaction before payment authorization, with strict latency and false-positive constraints.

**Key considerations:**
- **Stream + batch hybrid**: Kafka ingestion → feature extraction → model serving
- **Feature store** (online/offline split) — real-time features (last hour signals) + historical features (30-day rolling)
- **PII handling and tokenization** within the pipeline
- **Latency budget** — synchronous scoring adds to checkout critical path (sub-50ms)
- **False-positive cost vs false-negative cost** — which errs toward which and why
- **Model refresh without downtime** — shadow deployment, A/B testing
- **Fail-open policy** — if fraud service is down, accept with review queue (we covered this in payment degradation)

**Signal:** Strong prep guide consensus + Shopify engineering explicitly states "we assess fraud on every transaction."

### 3. Real-Time Merchant Analytics / In-Context Analytics — T1

**Framing:** Design a system that ingests transactions and storefront events from millions of merchants and serves real-time dashboard metrics (sales happening now, conversion rate, traffic).

**Key considerations:**
- **Lambda architecture** — batch pipelines for historical, streaming (Apache Flink) for recent
- **Unified API** serving web/iOS/Android from the combined view
- **Fan-out to live dashboards** via Server-Sent Events (SSE) or WebSockets
- **Pre-aggregation vs query-time rollup** trade-off
- **Multi-tenant isolation** in aggregation pipelines
- **Backpressure** when one merchant's event volume dominates

**Signal:** Shopify engineering has public content on this; Flink pipelines serving SSE to dashboards is their actual architecture.

### 4. Notifications at Scale — T1

**Framing:** Design a multi-channel notification system (email, SMS, push) handling transactional and marketing messages for 700M+ shoppers and 5M+ merchants.

**Key considerations:**
- **Multi-provider abstraction** (SendGrid, Mailgun, SES, Twilio) with circuit breakers per (provider, region)
- **Channel preference management** per user
- **Backpressure from upstream providers** — SendGrid caps emails/minute; queue-based delivery absorbs spikes
- **Transactional vs marketing priority queues** — order confirmations get dedicated capacity
- **Deduplication** via event_id (don't send duplicate order confirmations)
- **Delivery receipts** and retry on bounce/failure
- **Compliance** — suppression lists, GDPR, unsubscribe
- **Delayed scheduling** — abandoned cart recovery, review requests

**Signal:** Consistently named across prep guides; covers async + external provider integration patterns.

### 5. Order Management / Fulfillment Routing — T1

**Framing:** Design the system that routes placed orders to the right fulfillment location, generates shipping labels, integrates with carriers, and tracks orders to delivery.

**Key considerations:**
- **Multi-warehouse routing** — scoring function (proximity, stock, cost, capacity)
- **Split shipments** — partial fulfillment from multiple warehouses
- **Carrier API integration** with retries, circuit breakers per carrier
- **Idempotent label generation** — don't generate duplicate labels on retry
- **Order state machine** — placed → routed → labeled → shipped → out-for-delivery → delivered (with cancellation/return branches)
- **Real-time tracking** — ingest carrier webhooks, push updates to buyers via SSE/push
- **Async after checkout** — fulfillment routing is not on the synchronous checkout path

**Signal:** One direct candidate report; strong prep guide mention; core Shopify concern.

### 6. A/B Testing / Experimentation Platform — T1

**Framing:** Design Shopify's internal experimentation platform for feature flag rollouts and A/B tests across millions of storefronts.

**Key considerations:**
- **Assignment consistency** — same user/merchant always sees the same variant (sticky hashing)
- **Statistical validity** — sample size, confidence intervals, bias correction
- **Feature flag delivery** — fast rollout/rollback, no-deploy changes
- **Kill switch latency** — how fast can you disable a bad experiment
- **Multi-tenancy** — per-merchant experiments, per-shop targeting
- **Event tracking and analysis** — pipe to warehouse for statistical analysis
- **Experiment lifecycle** — design → launch → monitor → analyze → promote/roll back

**Signal:** Explicitly named in prep guides; Shopify has "Tangle" for ML experimentation.

---

## Tier 2: Medium-Probability Problems

### 7. Shop Pay / Cross-Merchant Identity & Wallet — T2

**Framing:** Design the backend for Shop Pay — a persistent buyer identity layer that enables one-click checkout across all Shopify merchants (150M+ users, 72% conversion lift).

**Key considerations:**
- **Cross-merchant SSO/session management** — buyer has one identity, many stores
- **Stored payment method vault** — PCI scope; Shopify owns this vault (not per-merchant Stripe accounts)
- **Address book sync** — one address, used across stores
- **Autofill trust signals** — when to require re-auth
- **Fraud on compromised accounts** — account takeover detection
- **Multi-factor authentication**

### 8. Custom Domain Provisioning & TLS — T2

**Framing:** Design the system that lets merchants point their own domain (e.g., `coolsneakers.com`) at a Shopify store, with automated TLS, edge routing per-tenant.

**Key considerations:**
- **DNS record management** (CNAME or A records pointing to Shopify's edge)
- **Automated TLS issuance at scale** — Let's Encrypt / ACME protocol
- **Certificate renewal** before expiration — rolling renewal queue
- **CDN edge routing** — `domain → shop_id` lookup at edge
- **Cold start** for newly-added domains — DNS propagation time, first-request cert fetch
- **Abuse prevention** — domain squatting, typo-squatting of popular brands

### 9. App Marketplace / Plugin Ecosystem — T2

**Framing:** Design the Shopify App Store backend — app submission, review, installation, OAuth, and sandboxed execution across 13,000+ apps and millions of merchants.

**Key considerations:**
- **App sandboxing/isolation** — script tags vs. app extensions vs. Shopify Functions (WASM)
- **Billing API** for app subscription charges (per-merchant, usage-based, recurring)
- **Rate limiting per app per merchant** — don't let one app hammer the API
- **App review pipeline** — security scan, manual review, automated checks
- **OAuth install flow at scale** — concurrent installs during BFCM
- **App update mechanism** — version rollouts, mandatory updates vs opt-in
- **Permissions model** — what scopes an app can request, consent flow

### 10. Multi-Currency & Tax Calculation — T2

**Framing:** Design a system that determines correct price, tax, duties, and currency for a buyer in any country in real time during checkout.

**Key considerations:**
- **Tax rule caching vs live lookup** — jurisdictions rarely change; cache aggressively
- **Currency conversion rate freshness** — daily vs real-time rates
- **Jurisdiction resolution** — IP vs. shipping address
- **Rounding rules by locale** — different countries handle cents differently
- **Compliance audit trail** — which rate was used, when, why
- **Fallback when tax provider is down** — graceful degradation (we covered this in payment dependencies)
- **Regulatory changes** — new tax laws, duties, import rules

### 11. Real-Time Order Tracking to Buyers — T2

**Framing:** Design a system that pushes live order status updates to buyers with sub-minute latency (shipped → out for delivery → delivered).

**Key considerations:**
- **Transport choice**: SSE (simple, unidirectional) vs WebSocket (bidirectional, overkill here) vs long polling (fallback)
- **Carrier webhook ingestion** — normalize events from UPS, FedEx, DHL into unified format
- **State machine idempotency** — duplicate tracking events from carriers
- **Fan-out** — one order update → multiple notification channels (email, push, SSE)
- **Estimated delivery time** — live recomputation based on carrier signals
- **Cold start** — buyer opens tracking page after days; pull current state from source of truth

---

## ML-Flavored Rounds (Tier ML)

### 12. Multi-Tenant ML Platform (Merlin Pattern) — ML

**Framing:** Design an ML platform supporting diverse use cases (fraud, recommendations, search ranking) across many teams with conflicting resource, framework, and latency requirements.

**Key considerations:**
- **Short-lived compute clusters per job** (Ray + Kubernetes)
- **Online feature store** for low-latency inference (Feast-based, sub-10ms lookups)
- **Offline feature store** for training (data warehouse integration)
- **Unified API** from Jupyter to production
- **Model serving infrastructure** — tensor serving, caching, batching
- **Multi-tenancy** — fair scheduling across teams, isolation of noisy neighbors
- **GPU resource scheduling** and cost tracking

### 13. Production Agentic AI (Sidekick Pattern) — ML

**Framing:** Design a production AI assistant with 50+ tools that executes complex merchant workflows reliably.

**Key considerations:**
- **Tool scaling problem** — past ~50 tools, systems degrade from context bloat
- **Just-in-time context injection** — inject only relevant tool context per request (preserve prompt cache)
- **Evaluation infrastructure** — LLM-as-judge calibrated against human raters
- **Conversation simulator** for replay testing before production
- **RL reward hacking** — model exploits training signal instead of solving task
- **Latency under agentic loops** — multiple LLM calls per user request
- **Error recovery** — what happens when a tool call fails mid-workflow

### 14. Multimodal Catalog Intelligence — ML

**Framing:** Design a system that classifies billions of products into a global taxonomy using multimodal (image + text) inference.

**Key considerations:**
- **Batch inference at scale** — hundreds of millions of inferences/day
- **Human-in-the-loop validation** for edge cases
- **Taxonomy as graph** — not a fixed tree; evolves as categories emerge
- **Agent-driven schema evolution** — taxonomy is updated by ML agents, not just humans
- **Cost vs accuracy trade-off** — smaller models for most, larger for ambiguous cases
- **Fine-tuning pipeline** — fine-tuned Qwen for catalog, fine-tuned Nomic for embeddings

### 15. Multi-Cloud GPU Orchestration — ML

**Framing:** Design a system that schedules ML inference and training across GCP, AWS, and neo-clouds (Nebius, Lambda Labs) with workload-specific routing.

**Key considerations:**
- **Multi-cloud abstraction layer** (SkyPilot, Kueue)
- **Different workloads, different SLAs** — throughput-oriented (batch classification) vs latency-oriented (fraud scoring)
- **GPU supply volatility** — cloud capacity fluctuates; need fallback providers
- **Inference acceleration** (CentML, TensorRT, vLLM)
- **Model versioning and rollout** across clusters
- **Cost optimization** — reserved capacity vs spot instances

---

## Bonus: Shopify-Specialty Problems

### 16. Shopify Functions / Untrusted WASM Execution — Bonus

**Framing:** Design a system that runs merchant-provided custom business logic (discount rules, shipping logic, checkout validation) as WebAssembly modules at checkout, with strict latency and security constraints.

**Key considerations:**
- **Sandboxed execution** (Lucet, now Wasmtime) with deterministic memory/CPU budgets
- **Multi-tenant fairness** — one merchant's bad function can't starve others
- **Cold start optimization** — ahead-of-time compilation, module caching
- **Narrow I/O interface** — functions can only access explicitly-exposed platform state
- **Latency budget** — <5ms per function invocation
- **API design** — how to expose platform data to user code without security attack surface
- **Developer experience** — compile Rust/JS/Go to WASM, local testing

### 17. POS Offline-First with Conflict Resolution — Bonus

**Framing:** Design the Shopify POS system such that a merchant can continue selling in a physical store when internet is down, with correct inventory and financial reconciliation on reconnect.

**Key considerations:**
- **Offline-first sync** — local-first write, queue for upload
- **Inventory conflict resolution** — CRDTs or operational transforms for counters
- **Split-brain scenarios** — multiple POS terminals offline simultaneously
- **Financial integrity** — tax records, payment captures must not duplicate on reconnect
- **User experience on reconnect** — what does the merchant see if there are conflicts
- **Timestamp-based vs logical-clock-based resolution**
- **Classic CAP theorem trade-off** — availability over consistency for POS, with reconciliation later

### 18. Shopify Capital / Merchant Credit Underwriting — Bonus

**Framing:** Design a system that continuously assesses merchant GMV trends and credit risk to offer working capital loans.

**Key considerations:**
- **Streaming GMV aggregation** — real-time revenue tracking
- **ML model for credit decisions** — tabular transformers on merchant features
- **Feature freshness vs model retraining cadence**
- **Decision latency SLA** — pre-approve before merchant asks
- **Regulatory compliance** — data retention, explainability of credit decisions
- **Multi-currency GMV normalization**
- **Repayment model** — auto-deduct from future sales

### 19. CDC from Sharded Monolith (Debezium at Scale) — Bonus

**Framing:** Design a Change Data Capture pipeline that captures every row change from ~100 sharded MySQL instances and publishes to downstream consumers (search, analytics, caches).

**Key considerations:**
- **Per-shard Debezium instances** reading each MySQL's binlog
- **Kafka topic abstraction** — consumers shouldn't care about sharding topology
- **Per-table compacted topics** — latest value per key for cache consumers
- **Large records** — exceed Kafka's 1MB limit → store in GCS with Kafka holding a pointer
- **Throughput** — 65K records/sec sustained
- **Schema evolution** — how to handle DB schema changes without breaking consumers
- **Ordering guarantees** — per-key within a partition, not global

### 20. Liquid Template Engine Optimization (Liquid-C) — Bonus

**Framing:** Design how to optimize a Ruby-based template engine into a production-fast system for rendering millions of storefront pages per minute.

**Key considerations:**
- **Bytecode VM** — compile templates to bytecode, interpret at runtime
- **C implementation** of hot paths
- **Template caching** — compile once, render many times
- **Sandboxing merchant-authored templates** — prevent merchants from exfiltrating data or causing DoS
- **JIT compilation potential** — refactoring to enable future JIT
- **Memory vs. speed trade-offs** — decoupling constant and instruction pointers for compiled control flow

### 21. Universal Commerce Protocol (Agent-Native Commerce) — Bonus

**Framing:** Design a protocol that lets AI agents negotiate commerce capabilities (pricing, inventory, checkout, fulfillment) across platforms — inspired by TCP/IP layering.

**Key considerations:**
- **Layered architecture** — stable core + extensible capability layers
- **Decentralized extensions** — reverse-domain namespacing, each org controls its own
- **Two-sided negotiation** — agents negotiate payment, fulfillment
- **Human escalation** — agent-blocked transactions fall back to embedded human checkout
- **Security model** — who authorizes what, on whose behalf
- **This is very forward-looking (2026) and may not reflect shipped systems**

---

## How to Prepare With This List

**If you have limited time:** focus on the T1 list (recommendations, fraud, real-time analytics, notifications, fulfillment, experimentation). These are the most likely to come up.

**If it's a generalist Staff interview:** T1 + one or two T2 of your choice. Shop Pay and custom domains are the most Shopify-distinctive T2 items.

**If it's an ML-flavored interview:** add the ML tier (Merlin, Sidekick, catalog intelligence).

**For bonus topics:** name-drop them if the interviewer asks, but don't go deep unless prompted. "Shopify Functions runs merchant code in WASM at checkout" is enough to signal awareness.

**Patterns that recur across every problem** (worth memorizing):
- Multi-tenancy (per-merchant isolation, sharding, routing)
- BFCM as design forcing function (10-100x spikes)
- Graceful degradation of non-critical dependencies
- At-least-once async via Kafka + outbox pattern
- ACID for money/inventory; cache + reconciliation for approximate state
- Fail-open on infrastructure failure
- Circuit breakers with regional scoping

---

## Companion Documents

- **[shopify-crash-course.md](shopify-crash-course.md)** — patterns, tech stack, vocabulary
- **[shopify-components-overview.md](shopify-components-overview.md)** — component-by-component walkthrough
- **[shopify-patterns.md](shopify-patterns.md)** — cross-cutting patterns
- **[shopify-practice-cheatsheet.md](shopify-practice-cheatsheet.md)** — post-practice recap
- **Individual exercise walkthroughs (04-11)** — deep dives on the core 8 with ASCII diagrams
