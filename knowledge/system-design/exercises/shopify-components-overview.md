# Shopify Staff System Design: Component-by-Component Overview

A systematic walkthrough of each major component in a Shopify-scale commerce platform. Medium depth — enough to design it in an interview, not enough to build it from scratch.

**How to use this document:** read top-to-bottom once to build a mental map. Revisit individual sections when preparing for a specific deep dive. Each section ends with **"How to describe this in an interview"** — a one-to-two-sentence framing you can memorize.

---

## Table of Contents

1. [[#1. Edge / Request Routing Layer]]
2. [[#2. Pod Architecture (Multi-Tenancy)]]
3. [[#3. Control Plane & Shop Migration]]
4. [[#4. Monolith (Checkout, Admin, Core Writes)]]
5. [[#5. Storefront Rendering Service]]
6. [[#6. Payments Pipeline]]
7. [[#7. Inventory Management]]
8. [[#8. Search and Discovery]]
9. [[#9. Async Eventing (Kafka + Outbox + CDC)]]
10. [[#10. Webhook Delivery]]
11. [[#11. Notifications]]
12. [[#12. Rate Limiting (API)]]
13. [[#13. Global Platform Services]]
14. [[#14. Data Warehouse & Analytics]]

---

## 1. Edge / Request Routing Layer

**Purpose:** the first layer every request hits. Terminates TLS, serves cached static content, routes dynamic requests to the correct pod, applies first-line defense against overload.

**Components:**
- **CDN** (Cloudflare, Fastly): geographically distributed HTTP cache in front of everything. Serves static assets (images, JS, CSS) and cacheable HTML (product pages with `Cache-Control`) from edge PoPs. Cache hit rate exceeds 90% during BFCM.
- **Load balancers** (L7, like AWS ALB or GCP Cloud Load Balancing): distribute incoming traffic across a fleet of edge proxy instances.
- **Edge proxy with scripting** (Nginx + Lua / OpenResty, or Envoy): the "Sorting Hat" layer. Handles shop-to-pod routing, load shedding, custom domain resolution, and edge rate limiting.

**Request flow:**
```
shopper → DNS → CDN edge → (cache miss) → L7 LB → Nginx+Lua → pod
```

**Key decisions:**
- **Explicit `shop_id → pod_id` mapping** stored in a control-plane Postgres, cached in Redis fronting the edge proxies. Sub-millisecond lookup. Not hash-based — explicit mapping lets you move individual shops without rehashing.
- **Custom domain resolution:** `cool-shoes.com` → `cool-shoes.myshopify.com` → pod 7. Handled at the edge via a `domain → shop_id` lookup in the same control-plane cache.
- **Load shedding at the edge:** rejects overloaded requests with 503 before they consume app-layer resources (threads, DB connections, memory). Signals include: pod health check results, backend backpressure headers, active in-flight request counts, circuit breaker state.

**Common pitfalls:**
- Trying to load-shed at the application layer. By then, the request has already consumed resources.
- Conflating the CDN (public HTTP cache) with Memcached (in-pod application cache). Different layers.

**How to describe this in an interview:** "The edge has three jobs — serve cached content from the CDN, route requests to the right pod via an explicit `shop_id → pod_id` mapping, and shed load before it hits the application layer. The routing and shedding logic lives in an edge proxy with scripting, like Nginx+Lua."

---

## 2. Pod Architecture (Multi-Tenancy)

**Purpose:** solve multi-tenancy at millions-of-merchants scale by grouping tenants into isolated infrastructure units. Each pod is a self-contained stack (app servers + database + cache) hosting thousands of merchants.

**Why not alternatives:**
- **Single shared database:** no blast-radius containment. One merchant's flash sale takes down everyone.
- **Database-per-tenant:** operationally impossible at millions of databases (connection pooling, schema migrations, backups, monitoring all collapse).
- **Pod-based:** O(100) databases for O(millions) of tenants. A pod failure affects thousands of shops, not millions. Linear scaling by adding pods.

**What's inside a pod:**
- **Rails (or similar) application servers** — horizontally scaled within the pod
- **MySQL primary + read replicas** — the authoritative transactional store for the pod's shops
- **Redis** — caching, rate limits, hot-path state, job queues (Sidekiq)
- **Memcached** — in-pod caching of rendered templates and serialized blobs

**Sizing:**
- Thousands of small merchants per pod, or a small number of enterprise merchants per dedicated pod
- Pods are bin-packed by resource utilization (CPU, disk, DB QPS), not by count
- ~100-500 pods in a typical fleet

**Tenant isolation:**
- Every table has a `shop_id` column
- Application-level query scopes automatically add `WHERE shop_id = :current_shop`
- Module boundary enforcement (Packwerk in Rails, similar tools elsewhere) prevents code from querying outside the current tenant
- MySQL itself does not enforce tenant boundaries — it's application-enforced

**Pod tiering:**
- **Shared pods:** default, densely packed with long-tail merchants
- **Dedicated pods:** for enterprise / Plus merchants expecting high traffic or wanting isolation guarantees
- **Hot-spare pods:** ready for dynamic promotion of viral merchants detected in real time

**Noisy neighbor prevention:**
- Edge rate limiting per shop
- Per-shop database query budgets
- Per-shop Redis memory quotas
- Circuit breakers between the pod and external services, scoped per (service, region)

**How to describe this in an interview:** "Multi-tenancy at this scale is a cellular architecture problem. Shops are grouped into pods — each pod is a self-contained stack with its own DB, cache, and app servers. Database-per-pod, not database-per-tenant. Blast radius is contained at the pod level."

---

## 3. Control Plane & Shop Migration

**Purpose:** manage metadata that spans the entire platform (shop-to-pod mapping, migration state, pod health) and move shops between pods without downtime.

**Control plane data:**
- Shop-to-pod mapping (`shop_id → pod_id`)
- Custom domain registry (`domain → shop_id`)
- Pod fleet state (pod health, resource utilization, capacity)
- Migration records (which shops are being moved, their state)
- Rate limit tier configuration
- Feature flags

**Where it lives:**
- Separate PostgreSQL instance **outside** the pod structure (so a pod failure doesn't affect routing)
- Read cache in Redis at the edge for sub-ms routing lookups
- Application-level in-memory cache with periodic refresh (not on the hot request path)

**Shop migration (online database migration):**
Moving a shop between pods requires physically moving its data between database instances without downtime. Industry pattern, implemented by tools like Ghostferry (Shopify), gh-ost (GitHub), pt-online-schema-change (Percona):

1. **Bulk copy:** scan rows for the target shop on source DB, write to destination DB. Live traffic continues on source.
2. **Binlog streaming:** while bulk copy runs, tail source binlog and replay changes on destination until source and destination are in sync.
3. **Throttling:** the migration tool monitors its impact on the source (replica lag, query latency, IO) and slows down if needed.
4. **Cutover:** brief write pause (<1s), flip the routing table entry, unpause. New requests go to the destination.
5. **Verification:** checksum comparison before and after cutover. Mismatch → rollback.
6. **Cleanup:** background job deletes the shop's data from the source pod.

**What migrates vs. what doesn't:**
- **Migrates:** everything in the pod's MySQL (orders, products, customers, inventory, settings)
- **Doesn't migrate:** Redis cache (warms on destination), object storage (S3 product images — shared, references work regardless), external OAuth tokens (shop identity unchanged)

**Migration triggers:**
- Pod resource pressure (CPU > 70%, disk > 80%, QPS above threshold)
- Merchant growing past shared-pod threshold (promote to dedicated)
- Viral traffic spike detected (dynamic promotion to hot-spare pod)
- Operational rebalancing (scheduled)

**How to describe this in an interview:** "The control plane is a separate Postgres outside the pod structure, holding metadata like shop-to-pod mappings and pod health. Shop migration is online database migration via snapshot + binlog replay + cutover — the industry pattern, called Ghostferry at Shopify."

---

## 4. Monolith (Checkout, Admin, Core Writes)

**Purpose:** the single Rails application that handles write-heavy, ACID-critical operations — checkout, payment, order creation, inventory decrement, admin operations. Runs inside each pod.

**Why a monolith, not microservices:**
- Checkout touches orders + payments + inventory + customers + tax + shipping in a single transaction. In microservices, this becomes a distributed transaction — fragile, slow, hard to reason about.
- Sharing a database across services within a pod is simpler and faster than distributed coordination.
- Module boundary enforcement (Packwerk) gives you logical isolation without the operational cost of service boundaries.

**What the monolith owns:**
- Checkout flow (cart → address → shipping → tax → payment → order)
- Admin dashboard (merchant operations: product CRUD, order management, customer management)
- API (REST + GraphQL for merchants and apps)
- Core transactional writes (anything touching orders, payments, inventory)

**What the monolith does NOT own:**
- Storefront rendering (separate read-optimized service)
- Search (Elasticsearch cluster + query service)
- Webhook delivery (separate async service)
- Notifications (separate service)
- Long-running jobs (background workers via Sidekiq, reading from job queues)

**Scaling patterns:**
- Horizontal — add application server instances within the pod behind a load balancer
- Database scaled via read replicas for non-transactional reads
- Redis and Memcached for hot-path caching
- Pod itself scales out (add more pods) when resource pressure warrants

**Common pitfalls:**
- Treating the monolith as an all-or-nothing choice. Modern "monolith" architectures like Shopify's have strict internal module boundaries via Packwerk and still have separate services for workloads with different shapes.
- Over-rotating to microservices. Every service boundary adds distributed-transaction complexity. You want service boundaries where they matter (different scaling shapes, different failure domains), not everywhere.

**How to describe this in an interview:** "The monolith handles ACID-critical writes — checkout, payments, inventory decrements, admin operations. It's modular internally (enforced module boundaries) but runs as a single deployable. Services are carved out only when scaling shape or failure isolation justifies it, like storefront reads or webhook delivery."

---

## 5. Storefront Rendering Service

**Purpose:** generate the HTML that shoppers see — product pages, collection pages, cart pages, search results. Read-heavy, independently scaled, decoupled from the monolith's write path.

**Why separate from the monolith:**
- 95% of platform traffic is reads (storefront browsing). 5% is writes (checkout, admin). These have different scaling shapes.
- During BFCM, storefront traffic spikes 10-20x while checkout only spikes 2-5x. You want to scale them independently.
- Failure isolation: a bug in the monolith's admin code shouldn't crash the storefront.
- This is **CQRS** (Command Query Responsibility Segregation) at the service level — the industry term.

**Architecture:**
```
CDN (Cloudflare/Fastly) with aggressive caching
  ↓ cache miss
Storefront service (stateless, horizontally scaled)
  ↓
MySQL read replicas + Memcached
```

**What the storefront service does:**
- Renders Liquid templates (Shopify's templating language for merchant themes) into HTML
- Reads product, collection, page, and theme data from the pod's MySQL read replicas
- Serves search-result pages (may proxy to the search service for query execution)
- Handles cart display (cart state is often client-side, but cart totals, shipping estimates, etc., come from the storefront service)

**What it does NOT do:**
- Never writes. All mutations go through the monolith.
- No direct contact with the pod's MySQL primary.

**Caching layers:**
1. **CDN** — caches rendered HTML. Stale-while-revalidate lets it serve cached pages even after TTL expiry. 90%+ hit rate during BFCM.
2. **Memcached** — caches serialized product data, rendered template fragments, compiled theme assets.
3. **Application-level cache** — in-memory LRU for very hot objects.
4. **Replica reads** — MySQL read replicas absorb what's left.

**Graceful degradation under load:**
- Serve stale CDN content past TTL
- Disable non-critical page features (recommendations, reviews, personalization)
- Fall back to a simpler theme if Liquid rendering is slow
- Serve static "browse by category" pages if fully degraded

**How to describe this in an interview:** "The storefront is a separate read-only service — classic CQRS split from the monolith. Reads from replicas and Memcached, scales independently of the monolith, sits behind a CDN with stale-while-revalidate so a burst of traffic mostly hits the edge. 4-6x performance gain over leaving it in the monolith."

---

## 6. Payments Pipeline

**Purpose:** collect card data safely, charge it reliably, handle failures and retries without double-charging. The most compliance-heavy and correctness-critical part of the system.

**The three hard subproblems:**
1. **PCI scope isolation** — keep raw card data out of the main application.
2. **Exactly-once semantics** — never double-charge, never lose an order.
3. **Multi-gateway resilience** — no single payment provider is a SPOF.

### PCI scope isolation

Credit card numbers carry PCI DSS compliance obligations. Any system that touches card data is "in scope" and must meet strict rules (audits, clearances, logging restrictions, etc.). The pattern to avoid putting the monolith in scope:

```
Browser
  ├── Main checkout page (from monolith, NOT in PCI scope)
  └── Iframe from a separate PCI-scoped domain
        ↓ shopper types card number directly into iframe
        ↓ iframe POSTs card number to tokenization service
        ↓ tokenization service returns opaque token
        ↓ token passed to main page
        ↓ monolith uses token to charge (never sees card number)
```

**Enforcement mechanism:** browser same-origin policy. JavaScript on the main page cannot read inside the iframe. This is physical, not convention.

**Industry equivalents:** Stripe Elements, Braintree Hosted Fields, Adyen Web Components.

### Exactly-once (Resumption pattern)

Every payment operation has a durable idempotency key and checkpointed state. If the process crashes mid-operation, it resumes from the last checkpoint.

```
1. Generate idempotency key abc-123
2. Checkpoint: "pre-auth" in MySQL
3. Call gateway with idempotency key
4. Checkpoint: "auth-sent"
5. Receive gateway response
6. Checkpoint: "auth-confirmed"
7. Proceed with order creation
```

A crash at any step is recoverable — the recovery process reads the last checkpoint and continues from there.

**End-to-end key propagation:** the idempotency key travels from the client → your system → the payment gateway. The gateway deduplicates if it sees the same key twice.

**Per-provider tracking:** your ledger tracks each `(idempotency_key, provider)` pair separately — either via key prefixing (`stripe:abc-123` vs `adyen:abc-123`) or via a composite primary key `(idempotency_key, provider)` in a single table. Either is equivalent; pick whichever is cleaner for your schema. This is for your own bookkeeping, not a correctness mechanism — it doesn't prevent cross-provider double-charges.

**Multi-gateway failover rule:** before failing over from Stripe to Adyen, **query Stripe for the transaction status.** If Stripe succeeded, don't fail over. Only fail over if you can confirm Stripe didn't charge. Blind failover on timeout causes double-charges.

### Circuit breakers

Wrap each gateway call with a circuit breaker scoped to `(provider, region)`. On repeated failures, the breaker opens and skips calls for a cooldown period. Never scope breakers globally — a US Stripe outage shouldn't kill EU traffic.

### Sync vs async boundary

The payment path is **synchronous**: monolith → gateway (HTTPS) → MySQL (transaction) → shopper (HTTP response). Total ~3-5 seconds.

Post-commit, an event goes through Kafka (via outbox) to downstream services: notifications, webhooks, analytics, search index.

Kafka is never in the synchronous critical path.

**How to describe this in an interview:** "Payments is an exactly-once distributed-transaction problem with compliance constraints. PCI isolation via iframe + tokenization keeps card data out of the monolith. Idempotency keys with checkpointed state handle crash recovery. Multi-gateway failover requires querying the original provider for transaction status before switching, or you risk double-charges."

---

## 7. Inventory Management

**Purpose:** track stock across merchants and locations, allow shoppers to reserve stock during checkout, never oversell.

### The core insight: display vs. allocation

- **Display** (stock badge on product page) tolerates staleness. Worst case: shopper sees "in stock," then "sold out" at checkout. Recoverable.
- **Allocation** (the actual decrement on purchase) must be strictly consistent. Worst case: overselling. Broken merchant trust, manual refunds.

Underselling is a lost sale (mild). Overselling is a broken promise (catastrophic). Design for overselling prevention; accept occasional underselling.

### Data model

```
shops (id, name, ...)
items (id, shop_id, title, description, ...)
item_variants (id, item_id, size, color, sku, ...)
locations (id, shop_id, name, address, type)
inventory_levels (variant_id, location_id, on_hand, reserved, version)
reservations (id, variant_id, cart_id, qty, status, expires_at)
inventory_events (append-only audit log)
```

Key schema details:
- `inventory_levels.version` column for optimistic locking (CAS — Compare And Swap)
- `CHECK (on_hand >= reserved)` — database-level oversell guard
- `reservations.expires_at` — TTL for self-healing on abandonment

### Reservation timing

Reserve at **checkout-start**, not add-to-cart. Add-to-cart is browsing intent; checkout is commit intent. Reserving at add-to-cart during BFCM creates zombie reservations from abandoned carts, locking up legitimate buyers.

Flow:
1. Shopper clicks "Check Out"
2. Reserve stock (insert `reservations` row + increment `inventory_levels.reserved`)
3. Shopper completes address, payment
4. On payment success: confirm reservation (decrement `on_hand`, clear `reserved` for that row)
5. On payment failure / timeout / abandonment: reservation expires via TTL, background reaper releases stock

### Concurrency control (adaptive)

- **Low contention (99% of SKUs):** optimistic locking. Read with version, UPDATE with `WHERE version = :expected`. Retry on conflict.
- **High contention (hot SKUs detected via Redis concurrency counter):** escalate to pessimistic locking (`SELECT FOR UPDATE NOWAIT`) to avoid retry storms.

### Hot SKU handling: virtual sharding

For extreme contention (sneaker drops with 10K concurrent buyers on one SKU), a single row/key becomes the bottleneck. Split a single logical SKU across N sub-rows/keys that each hold a fraction of the stock. Incoming reservations hash to a sub-shard. Contention spreads across N rows.

**Trade-off (last-unit problem):** shards drain at different rates. As total stock gets low, some sub-shards empty before others, causing "sold out" errors for shoppers hashing to empty shards even when stock exists elsewhere. Mitigations: fallback probing (try another shard), periodic rebalancing, single-shard mode at low stock.

**Static vs dynamic sharding:** pre-shard known hot SKUs (planned BFCM drops). Dynamically shard on detecting unexpected hot SKUs via a Redis concurrency counter crossing a threshold. Most systems do both.

### Storage choice: authoritative store

Two defensible designs:

- **MySQL-authoritative (simpler):** reservations in MySQL, TTL handled by background reaper. Single source of truth. Latency per reservation: ~10ms.
- **Redis fast-path + MySQL durable (more complex):** Redis atomic Lua check-and-decrement for reservation, async persistence to MySQL via outbox, MySQL is the recovery source on Redis failure. Latency: ~100μs.

### Multi-warehouse fulfillment

Distinguish two stages:

- **Shipping rate calculation (pre-purchase):** during checkout, the shopper sees a shipping cost computed from their address, package dimensions, and merchant-configured warehouses/carriers. This cost is **locked in at checkout** — the shopper is charged exactly this.
- **Fulfillment routing (post-purchase):** after the order is created, the system decides which warehouse actually ships, which carrier, which service level. Factors: stock availability per location, capacity, cost optimization, proximity. May split a single order across warehouses. Runs async.

The routing may pick a different warehouse than the rate calculation assumed, which means the merchant's actual shipping cost can differ from the shopper-facing rate. Merchants absorb small differences or use flat-rate tables (same source of truth for both calculations) to eliminate drift. The shopper is never re-charged after checkout for shipping variance.

### Cross-channel sync (Shopify POS, Amazon, eBay)

Shopify is authoritative for inventory. External channels receive updates via Kafka events with eventual consistency. POS tolerates offline mode with local cache and reconciliation on reconnection. **Buffer stock**: withhold a merchant-configurable percentage from each external channel to absorb sync lag (prevent overselling on Amazon during the seconds-to-minutes sync window).

**How to describe this in an interview:** "Inventory is a high-contention distributed write problem with a hard correctness requirement. Reservation-based allocation with TTL for self-healing. Adaptive concurrency control — optimistic default, pessimistic escalation for hot SKUs, virtual sharding for extreme contention. Display reads from cache; allocation goes through ACID."

---

## 8. Search and Discovery

**Purpose:** product search within a merchant's catalog. Full-text search, faceted filtering, autocomplete. Multi-tenant — millions of merchants sharing infrastructure.

**Technology:** Elasticsearch (the dominant industry choice for multi-tenant search at scale).

### Multi-tenant indexing: shared vs dedicated

- **Index-per-merchant doesn't work at 5M merchants.** Every index has metadata in the cluster state (held in memory on every node); millions of indices collapse it.
- **Single giant shared index has load-distribution problems.** Without routing, every query fans out to all shards — so every shard handles every query, and at BFCM volumes all shards are saturated ("all shards are hot"). With routing, each query hits exactly one shard, dividing per-shard load by N. Also, a single global index hits ES shard size limits (10-50GB per shard, ~200M docs per shard) at this scale.

**The hybrid pattern:**
- **Long tail (< 10K products):** shared indices with `shop_id` as the ES routing key. Each document's shard is decided by `hash(shop_id) % shards_in_index`. All of one merchant's documents land on the same shard. Queries also pass `routing=shop_id`, so they hit only one shard instead of fanning out.
- **Large merchants (10K+ products):** dedicated index per merchant.
- **Metadata layer** (Postgres + Redis) maps `shop_id → index_name + routing_type`.

**Important: routing is not a filter.** Routing is physical shard placement — a performance optimization. You **also** need a `term: { shop_id }` filter in the query body for correctness, because multiple merchants share the same shard in shared indices.

### Document model

One document per product, variant attributes as flattened arrays. Not one document per variant (a product with 300 variants would become 300 documents).

```json
{
  "shop_id": "shop_42",
  "product_id": "prod_123",
  "title": "Nike Air Max",
  "description": "...",
  "tags": ["sneaker", "running"],
  "variant_skus": ["A-S-RED", "A-M-RED", "A-L-RED"],
  "variant_sizes": ["S", "M", "L"],
  "variant_colors": ["red"],
  "price_range": {"min": 89.99, "max": 109.99},
  "in_stock": true,
  "new_arrival": true,
  "bestseller": false
}
```

`in_stock: boolean` is indexed (not counts — counts change too frequently to index without overwhelming the indexer).

### Real-time updates via CDC

Change Data Capture via Debezium:
1. MySQL binlog captures row changes on `products`, `item_variants` tables.
2. Debezium publishes to Kafka.
3. An index updater consumer applies changes to Elasticsearch.
4. CDC fires on **product-level changes** (including `in_stock` threshold crossings), not on every unit sold.

### Relevance and merchant customization

Each merchant has their own boost rules (boost new arrivals, bestsellers, products with images, etc.). Stored in a config table per merchant, cached in Redis.

**Applied at query time via `function_score`:**

```json
{
  "function_score": {
    "query": { "match": { "title": "red sneaker" } },
    "functions": [
      { "filter": { "term": { "new_arrival": true } }, "weight": 2.0 },
      { "filter": { "term": { "bestseller": true } }, "weight": 1.5 }
    ],
    "score_mode": "multiply"
  }
}
```

Not at index time — reindexing every merchant whenever their boost config changes would be prohibitively expensive.

### Autocomplete (separate subsystem)

Full ES queries are too slow (100-300ms) for autocomplete (budget: 50-100ms per keystroke). The pattern:

- **Completion Suggester** (ES built-in) or a **prefix trie** on a smaller, purpose-built index.
- **Edge n-grams** at index time for partial matching.
- Indexes both:
  - **Query completions** from query log analysis (popular searches)
  - **Product suggestions** from the catalog (handles cold start for never-searched products)
- Popularity-weighted. Per-merchant scoped. Aggressively edge-cached for common prefixes.

### Failure modes

- **ES cluster down:** fall back to database search (slower, less relevant, but functional), drop facets, serve cached results.
- **Indexing pipeline lag:** Kafka buffers during ES outages. On recovery, indexer replays from last offset. Monitor Kafka consumer lag.

**How to describe this in an interview:** "Search is a two-stage problem — cheap retrieval via an inverted index, followed by careful ranking. Multi-tenancy uses shared indices with `shop_id` routing for the long tail and dedicated indices for whales. CDC keeps ES in sync with MySQL, relevance is merchant-customizable via query-time `function_score`, autocomplete is a separate subsystem optimized for latency."

---

## 9. Async Eventing (Kafka + Outbox + CDC)

**Purpose:** propagate events across services without synchronous coupling. Order created here, notification sent there, analytics updated everywhere, with no direct RPC chain.

### Why async eventing

- Synchronous cross-service calls make order creation latency proportional to the number of downstream consumers
- A slow or failing downstream service shouldn't crash order creation
- Replayability — you can re-derive downstream state from the event log if a consumer was broken

### Kafka as the backbone

Events flow through Kafka topics. Properties that matter:
- **Durability:** Kafka persists messages to disk, replicated across brokers
- **Ordering (per-partition):** messages within a partition are delivered in order. Across partitions, no ordering guarantee.
- **Replay:** consumers can reset offsets and re-read from any point
- **At-least-once delivery:** duplicates happen; consumers must dedupe

### Topic structure

- **Topic-per-event-type:** `orders.created`, `orders.paid`, `inventory.updated`, `products.updated`
- **Partitioned by `shop_id`:** per-shop events are ordered; cross-shop ordering is not guaranteed
- **Multiple consumer groups per topic:** each downstream service (notifications, webhooks, analytics, search) has its own consumer group and receives its own copy of the stream
- **Independent scaling per consumer group:** search indexer runs 10 workers; analytics runs 2; they don't interfere

### Transactional outbox pattern

The problem: committing to MySQL and publishing to Kafka are two separate writes. A crash between them can lose the event. Direct Kafka publishes from application code are a dual-write anti-pattern.

The pattern:
```
Application transaction:
  BEGIN
    INSERT INTO orders (...)
    INSERT INTO outbox (event_type, payload, ...)
  COMMIT

Relay process (separate):
  SELECT * FROM outbox WHERE sent_at IS NULL
  → publish to Kafka
  → UPDATE outbox SET sent_at = NOW()
```

The outbox row is atomic with the business data, so it cannot be lost. The relay publishes at-least-once (a crash can cause a duplicate publish), and consumers dedupe on message IDs.

### CDC (Change Data Capture)

An alternative / complement to outbox. A tool like Debezium tails the database's transaction log (MySQL binlog, PostgreSQL WAL) and emits every row change to Kafka automatically, with no application code changes.

**When to use each:**
- **Outbox:** for semantic events ("OrderCompleted" with custom payload). Explicit, deliberate.
- **CDC:** for shipping all state changes to downstream systems (search index, analytics warehouse, caches) without having to remember to emit events in every code path.

Most systems use both.

### Consumer idempotency

At-least-once delivery means consumers see duplicates. The pattern:
- Each event has a unique `event_id` (set by the producer)
- Consumer checks a "processed events" store (Redis with TTL, or a DB table) before processing
- If seen, skip. If new, process and record the ID.
- TTL on the dedup store is longer than Kafka's maximum redelivery window (e.g., 7 days)

### Consumer lag as backpressure signal

Kafka tracks how far behind each consumer group is from the tip of the topic. During traffic spikes, lag growth signals "downstream can't keep up." Responses:
- Auto-scale consumer count
- Shed low-priority events (stop processing analytics during BFCM to prioritize financial events)
- Alert on-call

**How to describe this in an interview:** "Kafka is the event backbone, partitioned by shop_id with topic-per-event-type and independent consumer groups per downstream service. Producer-side reliability via transactional outbox, consumer-side dedup via idempotency keys in a Redis set. CDC for state-change streams, explicit outbox events for semantic events."

---

## 10. Webhook Delivery

**Purpose:** deliver event notifications to thousands of third-party apps subscribed to merchant events (order created, product updated, etc.). Apps are external — varying reliability, varying response times.

**Architecture:**
```
Monolith (outbox → Kafka) → webhook fan-out service → per-endpoint delivery workers → external app endpoints
```

### Fan-out

A single `orders.created` event may have 50 subscribers for a merchant (various apps installed). The fan-out service:
1. Reads the event from Kafka
2. Looks up active subscriptions: `(shop_id, event_type) → list of destination URLs`
3. Enqueues one delivery job per destination

**Critical:** fan-out is a separate service, not inline in the order producer. Inline fan-out makes order-creation latency proportional to subscriber count.

### Per-endpoint queue isolation

One slow consumer endpoint (30-second timeouts) must not block deliveries to healthy endpoints. Use per-destination virtual queues so head-of-line blocking is contained to one endpoint.

### Retry strategy

At-least-once delivery. Exponential backoff with jitter — typical schedule over 48 hours:
- 30s → 2m → 15m → 1h → 4h → 24h → 48h

After retry exhaustion: dead letter queue. After sustained endpoint failure (e.g., 95% failure over 24 hours): auto-disable the webhook subscription, notify the merchant.

### Idempotency for consumers

Each delivery carries a deterministic `Webhook-Idempotency-Key` header, typically derived from `(event_id, subscription_id)`. If the same delivery is retried, consumers see the same key and can dedupe.

### HMAC signing

Each delivery is signed with HMAC-SHA256 using the app's shared secret. Consumers verify the signature to confirm the request came from Shopify and wasn't tampered with.

```
X-Shopify-Hmac-SHA256: <base64 signature of (body + timestamp) using shared secret>
```

### Rate limiting per destination

Apply a token bucket per destination URL. If an endpoint is slow or rate-limiting us back, back off rather than piling up more requests.

### BFCM scaling

Webhook volume spikes 100x during BFCM. Pre-provision worker capacity. Apply priority lanes: financial events (order paid) get dedicated workers; analytics events go to lower-priority workers.

**How to describe this in an interview:** "Webhooks are at-least-once async fan-out. Kafka for ingestion, a fan-out service enqueues per-destination jobs, workers deliver with exponential backoff. Per-endpoint queues prevent head-of-line blocking. HMAC signing for authenticity, deterministic idempotency keys for consumer dedup, DLQ + auto-disable for persistent failures."

---

## 11. Notifications

**Purpose:** send transactional emails, SMS, and push notifications to shoppers and merchants. Order confirmations, shipping updates, password resets, merchant alerts.

**Architecture:**
```
Order event (Kafka) → Notification service → Template engine → Provider adapter → Email/SMS provider
```

### Provider abstraction

Notification service talks to multiple providers: SendGrid, Mailgun, Amazon SES, Twilio (SMS). Provider adapter pattern: a unified interface, with per-provider implementations.

Multi-provider failover (similar to payments):
- Circuit breakers per (provider, region)
- Waterfall failover on provider errors
- Retry safety classification (5xx safe to retry; certain errors not)

### Templating

Merchants customize their transactional email templates (brand colors, logo, copy). The notification service:
1. Receives the event
2. Fetches the merchant's template for this event type
3. Renders with the event data (order details, shipping info)
4. Sends via provider

Templates stored in the monolith's database; notification service fetches and caches.

### Delivery guarantees

- **At-least-once:** consumer dedup via `event_id` to avoid sending duplicate emails. Duplicate order confirmations are a bad customer experience.
- **No ordering guarantee:** order confirmation and shipping notification might arrive out of order if sent very close together. Acceptable for user-facing notifications.

### Scheduled and triggered sends

- **Immediate:** order confirmation, shipping notification
- **Scheduled:** abandoned cart recovery (2 hours after cart abandonment), review requests (7 days after delivery)
- Scheduled sends backed by a delayed-job queue (Sidekiq scheduled jobs, or a workflow engine like Temporal for complex sequences)

### BFCM scaling

Notification volume spikes with order volume (100x during BFCM). Rate-limited by the upstream provider's API limits (SendGrid caps at X emails/minute). Queue-based delivery absorbs the spike; provider quotas determine drain rate.

**How to describe this in an interview:** "Notifications are async event-driven sends via provider abstractions with failover. Templating per merchant, dedup via event idempotency keys, delayed scheduling for abandoned-cart and follow-up emails. Upstream provider rate limits are the bottleneck during BFCM; queue-based delivery absorbs the spike."

---

## 12. Rate Limiting (API)

**Purpose:** prevent abuse and unfair resource consumption of the public APIs. For GraphQL APIs specifically, Shopify does cost-based rate limiting — different queries cost different amounts based on computational complexity.

### REST API: traditional rate limiting

Per-app, per-shop request counters. Token bucket or leaky bucket algorithm. Typical limit: 40 requests/second for standard apps, higher for partners.

### GraphQL API: cost-based rate limiting

Because a single GraphQL query can fetch nested data (imagine `products(first: 50) { variants(first: 100) }` — a query for 5,000 objects in a single call), request-count-based rate limiting doesn't work. Shopify uses cost-based limiting:

**Cost calculation (static analysis, before execution):**
- Root connection field cost = `first` or `last` argument value
- Nested connections multiply: `products(first:50) { variants(first:100) }` = 50 × 100 = 5,000 points
- Scalars on already-fetched nodes: 0 (free)
- Mutations: fixed cost per mutation type

**Leaky bucket with cost:**
- Each (app, shop) pair has a bucket: 1,000 point capacity, 50 points/sec restore rate
- On each query: compute cost → check bucket fill level → reject if overflow → else deduct cost

### Distributed enforcement

Redis holds per-bucket state across all pods (a query for shop X might hit any pod). Atomic check-and-deduct via Lua script. Sub-ms latency on the hot path.

**Local approximation for extreme latency:** some systems keep a local in-memory counter per app server, periodically syncing to Redis. Trades strict accuracy for lower latency. Brief over-admission is acceptable.

### Fail-open

If Redis is unavailable, allow traffic. A rate-limiter failure should not take down the API. Log and alert, but serve.

### Response headers

Every response carries:
```
X-Shopify-Shop-Api-Call-Limit: 342/1000
```

On 429:
```
Retry-After: 2.0
```

Gives clients exact information for client-side throttling.

**How to describe this in an interview:** "For REST, it's token bucket per (app, shop) in Redis. For GraphQL, it's cost-based rate limiting — static query complexity analysis before execution, leaky bucket with per-(app, shop) buckets, Redis-backed with atomic Lua scripts. Fail-open on Redis failure, transparent to clients via response headers."

---

## 13. Global Platform Services

**Purpose:** services that span all merchants — shared across pods. Separate services, each with their own appropriate data store, scaled independently.

### Authentication

- OAuth 2.0 for merchants and apps, plus session-based auth for shoppers with cookie-backed sessions
- Token issuance, validation, revocation
- MFA (multi-factor authentication)
- Data store: SQL (PostgreSQL or MySQL) — sessions and credentials are row-oriented
- Sessions cached in Redis for fast validation on the hot path
- **Scaling:** auth is on every request, so low-latency is critical. Token validation usually stateless (signed JWT) where possible.

### Billing (Shopify's own subscription billing)

- Monthly subscription charges to merchants for their Shopify plan
- Invoicing, dunning (retry failed charges), plan upgrades/downgrades
- Data store: SQL — money is ACID-critical. Invoices, charges, plan configs are relational.
- Lower volume than the rest of the platform — thousands of monthly charges, not millions of requests

### App Marketplace

- Directory of third-party apps merchants can install
- OAuth flow for apps, permission model, webhook subscription registration
- Data store: SQL for app registry, Elasticsearch for app search
- Low-write, high-read workload — aggressive caching

### Shop Identity / Directory

- Primary shop records (name, domain, plan, creation date, etc.)
- Sometimes merged with auth
- Used by the control plane for routing decisions

### Why separate services, not one shared DB

- Different scaling shapes: auth is hot-path, billing is low-volume batch
- Different failure impact: an auth outage blocks all logins; a billing outage delays charges (recoverable)
- Different consistency needs: auth is latency-sensitive, billing is correctness-sensitive
- Isolation reduces blast radius — one service's DB issues don't cascade

**How to describe this in an interview:** "Global platform services — auth, billing, app marketplace — sit outside the pod structure, each as a separate service with their own appropriate data store. Auth is on the hot path with Redis session caching; billing is ACID-critical low-volume; app marketplace is read-heavy with ES for search. Isolated so their scaling shapes and failure domains don't interfere."

---

## 14. Data Warehouse & Analytics

**Purpose:** cross-tenant analytics, merchant-facing reporting dashboards, BI for Shopify's internal teams. Separate from the OLTP (Online Transaction Processing) databases.

**Technology:** Snowflake, BigQuery, or Redshift — columnar OLAP (Online Analytical Processing) stores optimized for aggregate queries over huge datasets.

### Data flow

Everything flows into the warehouse via CDC and events:

```
Pod MySQL → Debezium → Kafka → data warehouse ingest
Kafka event topics → data warehouse ingest
```

Ingest jobs (ETL or ELT) denormalize and load into warehouse tables optimized for analytical queries.

### What lives in the warehouse

- Full copy of orders, products, customers, inventory across all merchants
- Historical snapshots (not just current state)
- Analytical models (customer lifetime value, product affinity, seasonality)
- Aggregate rollups (daily sales per merchant, hourly traffic by region)

### Merchant-facing analytics

Merchant dashboards show "sales by product," "traffic by source," "conversion rate over time." These queries run against the warehouse, not the OLTP database.

**Why not run them on the pod's MySQL?** Analytical queries are large aggregations that would kill OLTP latency. Columnar warehouses are 100-1000x faster for this workload.

### Cold storage of audit logs

Old audit logs (orders > 1 year, fraud events > 2 years, etc.) move from hot MySQL partitions to the warehouse for long-term compliance retention. Queryable but not low-latency.

### Latency expectations

- Pod OLTP: milliseconds
- Warehouse: seconds to minutes per query
- Ingest lag: typically 5-15 minutes behind production (real-time CDC for hot tables, batch for others)

**How to describe this in an interview:** "A separate columnar data warehouse like Snowflake for analytics and BI. Fed via CDC from pod MySQLs and Kafka event streams. Merchant dashboards run against the warehouse, not OLTP. Query latency is seconds-to-minutes — acceptable for analytics, never for the request path."

---

## How to Tie These Together in an Interview

When asked to design Shopify end-to-end, don't try to cover every component at equal depth. Instead:

1. **Set context:** multi-tenant commerce, BFCM scale, checkout is the revenue path (~2 min)
2. **Scale and per-pod math:** establishes pod architecture as load-bearing (~3 min)
3. **10,000-ft architecture:** edge, pods, monolith, storefront service, Kafka, global services (~5 min)
4. **Pick 1-2 deep dives based on interviewer interest** (~20-30 min)
5. **Wrap:** summarize key decisions and trade-offs; flag what you'd cover with more time

Common deep-dive triggers:
- "How do you handle BFCM?" → inventory + hot SKU + graceful degradation
- "How do you handle payments?" → Resumption + PCI + multi-gateway
- "How does search work?" → multi-tenant ES + CDC + relevance
- "How does scaling work?" → pods + edge routing + Ghostferry migration
- "How do webhooks work?" → Kafka + per-endpoint isolation + retries

Each of these components has enough depth to fill a 45-minute interview on its own. Knowing them at the level of this document is probably enough for most Staff-level rounds.

---

## Companion Documents

- **[shopify-crash-course.md](shopify-crash-course.md)** — Reference on patterns, tech stack, and vocabulary. Read for the "why" behind design choices.
- **[shopify-patterns.md](shopify-patterns.md)** — Cross-cutting patterns mapped back to specific exercises.
- **[shopify-practice-cheatsheet.md](shopify-practice-cheatsheet.md)** — Post-practice recap in one-sentence form.
- **Individual exercise walkthroughs (04-11)** — Deep dives on each major problem with full ASCII diagrams and trade-off analysis.
