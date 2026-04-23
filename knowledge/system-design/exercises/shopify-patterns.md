# Shopify System Design: Cross-Cutting Patterns and Gotchas

These patterns and gotchas are distilled from all 8 Shopify system design exercises. They represent the recurring architectural decisions and failure modes that Shopify interviewers care about. Weave these into any Shopify system design answer -- they signal that you understand how commerce-scale systems actually work.

---

## Recurring Architecture Patterns

### 1. Pod-Based Tenant Isolation

**Appears in:** Checkout, Flash Sale, Inventory, Multi-Tenant, Rate Limiting

The signature Shopify pattern. Each pod is a self-contained unit (app servers + MySQL primary/replica + Redis + Memcached) hosting thousands of shops. Database-per-pod, not database-per-tenant.

**Why it matters:** Blast radius containment. A pod failure affects thousands of shops, not millions. A noisy tenant disrupts its pod, not the platform. Scaling is linear -- add pods.

**Interview signal:** If you propose a single shared database for millions of merchants, you have missed the core constraint. If you propose database-per-tenant, you have created millions of databases (unmanageable). Pod-based is the sweet spot.

### 2. Circuit Breakers with Regional Granularity (Semian)

**Appears in:** Checkout, Flash Sale, Payment, Multi-Tenant, Webhook

Always scoped to (provider, region) or (service, pod) -- never global. Semian is Shopify's Ruby circuit breaker library.

**Why it matters:** A global circuit breaker for "Stripe" means a US outage blocks EU and APAC. Regional scoping keeps healthy routes operational. This is the most common mistake candidates make with circuit breakers.

**Interview signal:** When discussing any external dependency (payment providers, webhooks, third-party APIs), mention circuit breakers and immediately specify the granularity: per-provider, per-region.

### 3. Graceful Degradation Tiers

**Appears in:** Checkout, Flash Sale, Product Search, Rate Limiting

Degradation is not binary (up/down). It follows a priority order:
1. Full features (normal)
2. Shed analytics, recommendations, personalization
3. Serve stale/cached content
4. Static storefront pages
5. Queue-based admission control
6. Emergency mode (maintenance page)

**The critical rule:** Checkout is the last thing to degrade. Even within checkout, shed non-critical parts (estimated tax → flat-rate shipping → simplified UI) before touching the payment path.

**Interview signal:** Say "checkout is the revenue path" and explain that you would shed product recommendations, analytics, and personalization long before touching checkout availability.

### 4. Idempotency / Exactly-Once Semantics

**Appears in:** Checkout (Resumption pattern), Payment (Resumption pattern), Webhook (idempotency keys), Inventory (reservation idempotency)

The Resumption pattern is Shopify's approach: each payment operation has a durable idempotency key with checkpoints. If the process crashes, it resumes from the last checkpoint. The idempotency key propagates end-to-end: client → your system → payment gateway.

**Key nuance:** Idempotency keys must be namespaced per provider. If you use the same key for Stripe and Adyen during failover, and Stripe later confirms the original charge, you have double-charged across providers.

**Interview signal:** Mention the Resumption pattern by name. Discuss the crash-at-every-step analysis: what happens if the process dies between calling the gateway and recording the result?

### 5. Edge-Layer Routing and Load Shedding (Sorting Hat)

**Appears in:** Flash Sale, Multi-Tenant, Rate Limiting

The Sorting Hat (OpenResty/Lua) sits at the edge, before the application layer. It handles:
- Shop-to-pod routing (sub-ms lookups against shared Redis/etcd)
- Load shedding (reject before consuming app server resources)
- Custom domain resolution

**Why it matters:** If load shedding happens at the Rails layer, you have already consumed a thread, a database connection, and memory. Shedding at the edge is orders of magnitude cheaper.

**Interview signal:** When discussing any high-traffic scenario, mention that routing and shedding decisions should happen at the edge layer, not the application layer.

### 6. TTL-Based Self-Healing

**Appears in:** Inventory (reservation TTL), Flash Sale (admission tokens), Webhook (retry budget), Rate Limiting (bucket refill)

Reservations, tokens, and locks have explicit TTLs. When a cart is abandoned, the inventory reservation expires automatically. No manual cleanup. No orphaned state.

**Why it matters:** During BFCM, abandoned carts can lock up entire inventory within minutes if reservations do not expire. TTL-based self-healing is the difference between a flash sale that works and one that shows "out of stock" while stock sits in zombie carts.

### 7. Dual-Path Architecture (Fast + Durable)

**Appears in:** Inventory (Redis fast path + PostgreSQL durable), Rate Limiting (local cache + Redis), Flash Sale (Redis reservation + MySQL truth)

The pattern: use Redis/in-memory for the hot path (sub-ms latency) and PostgreSQL/MySQL as the durable source of truth. Reconcile periodically.

**Why it matters:** The checkout latency budget cannot afford a database round-trip for every inventory check. Redis handles the hot path. If Redis dies, fall back to the database (slower but correct). Periodic reconciliation catches drift.

### 8. Event-Driven Architecture (Kafka)

**Appears in:** Inventory (cross-channel sync), Webhook (event ingestion), Product Search (CDC pipeline), Flash Sale (merchant dashboard)

Kafka is the backbone for async communication. Common pattern: transactional outbox → Kafka → consumers. CDC (change data capture) via Debezium captures database mutations without dual-write risk.

**Why it matters:** Synchronous cross-service communication creates cascading failure risk. Kafka decouples producers from consumers, handles backpressure naturally, and supports replay for recovery.

### 9. Fail-Open over Fail-Closed

**Appears in:** Rate Limiting (Redis down → allow traffic), Checkout (degraded features → still process payment), Flash Sale (stale cache → still serve pages)

Revenue-critical systems fail open. A Redis outage should not block all API traffic. A tax calculation failure should not prevent checkout. Brief over-admission is cheaper than total unavailability.

**Interview signal:** Explicitly state your failure mode policy. "If Redis is down, we fail open with local-only rate limiting. Brief over-admission is acceptable; blocking all API traffic is not."

### 10. PCI Scope Isolation (CardSink/CardServer)

**Appears in:** Checkout, Payment

Card data is captured in a cross-origin iframe (CardSink) served from a PCI-scoped domain. The iframe submits to CardServer, which tokenizes and returns a payment token. The Rails monolith never sees raw card data.

**Why it matters:** PCI compliance is scoped by data touch. If raw card data touches any part of the monolith -- even in a log statement -- that entire system is in PCI audit scope. The iframe boundary makes it physically impossible for card data to reach the monolith.

---

## Top Gotchas Across All Exercises

These are the mistakes that recur most frequently across the 8 exercises. If you avoid these, you are already ahead of most candidates.

### 1. Global circuit breakers instead of regional

**Exercises:** Checkout, Payment, Flash Sale

A single circuit breaker for "Stripe" means a US outage blocks all Stripe traffic globally. Always scope to (provider, region). This mistake appears in 3 of 8 exercises -- interviewers actively probe for it.

### 2. Treating all traffic/tenants/events equally

**Exercises:** Flash Sale, Webhook, Rate Limiting, Multi-Tenant

Not all requests are equal. Checkout > product pages > analytics. Financial webhooks > catalog updates. Enterprise merchants > hobby shops. Without priority lanes and tiered treatment, a spike in low-priority traffic kills high-priority paths.

### 3. No TTL on reservations or locks

**Exercises:** Inventory, Flash Sale

Reservations without TTLs create zombie locks. During BFCM, thousands of abandoned carts can lock entire inventory within minutes. Self-healing via expiration is non-negotiable.

### 4. Synchronous operations where async is needed

**Exercises:** Webhook (fan-out), Inventory (cross-channel sync), Payment (settlement)

Synchronous fan-out in the event producer means order creation latency increases with every webhook subscriber. Cross-channel inventory sync cannot be synchronous because external APIs have inherent latency. Decouple with Kafka.

### 5. Shedding load at the application layer instead of the edge

**Exercises:** Flash Sale, Multi-Tenant

If the request already hit your Rails process, you have consumed a thread, a database connection, and memory. The Sorting Hat (OpenResty/Lua) rejects at the edge for near-zero cost. Candidates who propose application-layer-only shedding miss this cost difference.

### 6. Single locking strategy for all concurrency levels

**Exercises:** Inventory, Checkout

Optimistic locking (CAS with version counter) works for 99% of SKUs. But for a limited-edition drop with 10,000 concurrent buyers on one SKU, optimistic locking causes a retry storm. The system needs adaptive concurrency control: optimistic by default, escalate to pessimistic for hot SKUs.

### 7. Not propagating idempotency keys end-to-end

**Exercises:** Checkout, Payment, Webhook

Your system may be idempotent, but if you send the same charge to the payment gateway twice with different idempotency keys, the gateway processes it twice. The key must flow: client → your system → external provider. For webhooks, the key must be deterministic (derived from event_id + subscription_id), not random per delivery attempt.

### 8. Database-per-tenant at Shopify scale

**Exercises:** Multi-Tenant, Inventory

Millions of tenants = millions of databases. Connection pooling, schema migrations, backups, and monitoring become impossible. Database-per-pod (O(100) databases for O(millions) tenants) is the correct granularity.

### 9. Storing volatile data in slow systems

**Exercises:** Product Search (inventory in ES), Rate Limiting (counters in DB)

Inventory changes on every purchase. Storing per-variant stock counts in Elasticsearch creates a firehose of index updates. Store only `in_stock: boolean` in the search index. Similarly, rate limit counters in a database cannot meet sub-ms latency requirements -- use Redis or in-memory.

### 10. Fail-closed on infrastructure failure

**Exercises:** Rate Limiting, Checkout, Flash Sale

If Redis goes down and your rate limiter blocks all traffic, you have turned a cache failure into a platform outage. Revenue-critical systems fail open: allow traffic with approximate local enforcement, accept brief over-admission, and recover when infrastructure returns.

---

## Shopify-Specific Vocabulary to Use in Interviews

Using Shopify's own terminology shows you have done your homework:

| Term | Meaning |
|---|---|
| **Pod** | Self-contained infrastructure unit (app servers + DB + cache) hosting a group of shops |
| **Sorting Hat** | OpenResty/Lua edge routing layer mapping shops to pods |
| **Ghostferry** | Zero-downtime MySQL-to-MySQL shop migration tool |
| **Semian** | Ruby circuit breaker library with per-resource granularity |
| **CardSink/CardServer** | PCI isolation architecture for payment tokenization |
| **Resumption pattern** | Checkpoint-based idempotency framework for exactly-once payment semantics |
| **Packwerk** | Module boundary enforcement for the Rails monolith |
| **Genghis** | Internal load testing tool for BFCM preparation |
| **Toxiproxy** | Chaos engineering proxy for simulating network failures (Game Days) |
| **BFCM** | Black Friday / Cyber Monday -- the peak traffic event that drives all scalability decisions |

---

## Related Exercises

- [[04-shopify-checkout-system/PROMPT|Exercise 4: Checkout System]]
- [[05-shopify-flash-sale-system/PROMPT|Exercise 5: Flash Sale / BFCM Traffic]]
- [[06-shopify-inventory-management/PROMPT|Exercise 6: Inventory Management]]
- [[07-shopify-multi-tenant-platform/PROMPT|Exercise 7: Multi-Tenant Platform]]
- [[08-shopify-webhook-delivery/PROMPT|Exercise 8: Webhook Delivery]]
- [[09-shopify-product-search/PROMPT|Exercise 9: Product Search]]
- [[10-shopify-rate-limiting/PROMPT|Exercise 10: Rate Limiting]]
- [[11-shopify-payment-processing/PROMPT|Exercise 11: Payment Processing]]
