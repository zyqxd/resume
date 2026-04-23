# Shopify Staff System Design: Crash Course

A self-contained guide to the architecture patterns, technology choices, and failure modes that Shopify interviewers expect Staff candidates to know. Read this before any Shopify system design round.

**A note on vocabulary:** Shopify has internal names for many of its infrastructure components (Sorting Hat, Ghostferry, Semian, Resumption). In the interview, name-drop them only once to show you've done your homework, then describe the underlying industry pattern. You don't need experience with the specific tools -- you need to recognize the categories.

---

## How Shopify Thinks About Architecture

Shopify is a multi-tenant commerce platform running millions of merchants on shared infrastructure. Every design decision is downstream of three constraints:

1. **BFCM is the design target.** BFCM = Black Friday / Cyber Monday, the annual peak shopping event. 2024: 284 million HTTP requests per minute at the edge, 10.5 trillion database queries, 57.3 PB of data transferred. Systems are built for 10-100x normal traffic. If your design handles steady-state but collapses under a flash sale, it fails.

2. **Merchant revenue is the top priority.** Checkout is the revenue path. Every architectural trade-off bends toward "can the merchant still take a payment?" Tax service down? Use estimated tax. Recommendation engine slow? Skip it. Cache layer degraded? Fail open (allow the request, accept slight accuracy loss). The payment path is the last thing to degrade.

3. **Multi-tenancy is the hard problem.** Millions of merchants sharing infrastructure. A viral TikTok merchant cannot take down the platform. An enterprise merchant doing $1M/day cannot be treated the same as a hobby shop doing $10/month. Isolation, fairness, and blast radius containment are first-class concerns.

**How to frame any Shopify problem in an interview:** "At the core this is a multi-tenant commerce problem. The shape of the answer is: isolate tenants so one noisy merchant can't harm others, optimize for the write path of checkout above all, and design explicit degradation paths for when traffic is 100x normal."

---

## The Technology Stack

### Databases

**MySQL (primary OLTP store)**

OLTP = Online Transaction Processing. This means the live application database serving real-time reads and writes, as opposed to OLAP (Online Analytical Processing), the separate data warehouse for analytics.

Shopify's core data lives in MySQL. The database is **sharded by pod** (see [Pod-Based Tenant Isolation](#pod-based-tenant-isolation) below) -- each pod has its own independent MySQL primary and read replicas. Within a pod, all tables have a `shop_id` column and every query is scoped to a specific shop. MySQL itself does not enforce this tenant boundary; it's enforced at the application layer (the ORM adds `WHERE shop_id = ?` to every query automatically, and module boundary tools prevent code from leaking outside its tenant scope).

**When to reach for MySQL (or any ACID-compliant relational DB):**
- Any transactional data requiring ACID guarantees (orders, payments, inventory, reservations). ACID = Atomicity, Consistency, Isolation, Durability -- the classic transactional database guarantees.
- Audit logs and append-only event trails
- State machines where you need conditional updates (`UPDATE ... WHERE status = 'authorized' AND version = :v`)
- Data that must survive a cache failure

**Key patterns to know:**
- **Optimistic concurrency with a `version` column.** Read a row with its version number, update with `WHERE version = :expected_version`. If another transaction beat you to it, the update affects zero rows and you retry. Also called CAS (Compare-And-Swap).
- **Pessimistic locking.** Several flavors: `SELECT FOR UPDATE` (blocks other writers until you commit), `SELECT FOR UPDATE NOWAIT` (errors immediately if locked -- good for "try-lock"), `SELECT FOR UPDATE SKIP LOCKED` (skips locked rows -- the standard pattern for database-backed job queues). Plus advisory locks (`GET_LOCK('name')` in MySQL) for coordinating non-row-level operations.
- **CHECK constraints** as a last line of defense (e.g., `CHECK (quantity_on_hand >= quantity_reserved)` prevents oversell even if application logic has a bug).
- **Transactional outbox pattern.** To reliably publish an event after a database commit, write the event to an `outbox` table in the same transaction as the business data. A separate relay process reads the outbox and publishes to Kafka. This closes the gap where a crash between "DB commit" and "Kafka publish" would lose the event.
- **Replication:** MySQL primary writes to its binary log (binlog); replicas tail that log and apply changes.
  - **Async (default):** primary doesn't wait for replica acks. Fast but can lose last transactions on failover.
  - **Semi-sync:** primary waits for at least one replica to acknowledge receipt (not apply). Falls back to async if no replica responds in time. Safer, mildly slower.
  - **Sync:** primary blocks until all replicas ack apply. High correctness, poor availability -- rare in MySQL.
  - **Replica lag is the operational concern.** Under write bursts, replicas fall seconds or minutes behind. Remedies:
    - Monitor lag; remove replicas from the read pool when lag crosses a threshold (usually 5 seconds) via ProxySQL/MaxScale health checks.
    - Read-your-writes routing: after a write, route the client's reads to the primary for N seconds, or use GTID (Global Transaction ID) tracking to only route to replicas that have replayed past the client's write.
    - Route critical reads (checkout, cart, payment status) to the primary. Accept the load.
    - Enable parallel replication (MySQL 8) so replicas can apply binlog events on multiple threads instead of the default single thread.
    - Pre-scale replicas before known traffic events -- BFCM replicas should be provisioned the week before, not during the event.
    - Alert on sustained lag: a few seconds during a burst is normal; sustained lag signals a problem (long-running transaction, disk IO saturation, schema migration replay).
- **Integer cents + explicit currency column for money.** Never float (IEEE 754 rounding bugs). Never implicit currency (multi-currency platforms cannot assume USD).

**Redis (fast-path caching, distributed counters, coordination)**

Redis is an in-memory data store used alongside MySQL, not instead of it. It handles operations that cannot afford a disk round-trip.

**When to reach for Redis:**
- Rate limit counters (leaky bucket state per app/merchant)
- Cached views of hot data (stock levels displayed on storefront pages)
- Request routing state (shop-to-pod mapping tables)
- Queue-based admission control (sorted sets for FIFO waiting rooms)
- Short-lived distributed locks (coordinating background jobs across instances)
- Reservations on the fast path (sub-ms "check and hold", with MySQL as the ACID source of truth)

**Key patterns to know:**
- **Lua scripts for atomicity.** Redis can execute a small Lua program server-side with a guarantee that no other command interleaves. This is how you implement "read counter, check limit, decrement if under" as one atomic operation. Without Lua, you'd need to either accept race conditions or use `WATCH/MULTI/EXEC` (optimistic transactions with retry).
  - Example use: the atomic check-and-deduct for a leaky-bucket rate limiter. One script, one round-trip, guaranteed consistency.
- **Fail-open.** If Redis is down, fall back to MySQL or in-memory approximations. Never block all traffic because the cache is unavailable.
- **TTL on everything.** TTL = Time To Live. Reservations, rate-limit keys, cached stock levels all have explicit expirations. Redis is designed for ephemeral data.
- **Periodic reconciliation with MySQL to catch drift.** A background worker runs on a schedule (every N minutes via cron or Sidekiq cron), compares cached values to the database truth, and corrects any discrepancies. It's a sweeper, not a continuous sync.

**Redis vs. Memcached (since both are in-memory caches):**

| Dimension | Memcached | Redis |
|---|---|---|
| Threading | Multi-threaded | Single-threaded commands |
| Scaling on one box | Add cores | Run more instances |
| Data types | Strings/blobs only | Strings, hashes, lists, sets, sorted sets, streams, HyperLogLog, etc. |
| Persistence | None (pure cache) | RDB + AOF optional |
| Replication | None built-in | Primary/replica + Cluster |
| Memory efficiency | Slab allocator, very efficient for uniform small values | More overhead per key, but richer structures |
| Eviction | LRU only | 8 policies (LRU, LFU, TTL, random, etc.) |
| Max value size | 1 MB default | 512 MB (but keep < 100 KB) |

Shopify uses both. Memcached caches rendered templates and serialized product blobs -- dumb "if miss, recompute and store" patterns. Redis handles anything that needs atomic server-side logic: rate limits, reservations, waiting rooms, leaderboards.

**MySQL vs. Redis capacity reference (order-of-magnitude thresholds):**

Use this to sanity-check any claim about what a single node can handle in an interview.

| Dimension | MySQL | Redis |
|---|---|---|
| Read QPS (single node) | 10K–20K | 100K+ (200K+ with pipelining) |
| Write QPS (single node) | 1K–5K (up to ~10K tuned) | 100K+ |
| Typical latency | 1–10 ms | < 1 ms (sub-ms p50) |
| Dataset size (single node) | 1–2 TB comfortable, 5 TB painful | 10–100 GB practical (RAM-bound) |
| Index / working set | Must fit in buffer pool (~70–80% RAM) | Entire dataset lives in RAM |
| Row/key count (warning zone) | 100M+ rows | Billions fine if memory holds |
| Connections | 1K–5K before pooler needed | 10K+, but single-threaded execution |
| Scale reads via | Read replicas → 100K+ QPS | Replicas (eventual consistency) |
| Scale writes via | Sharding (last resort) | Redis Cluster (16,384 hash slots) |
| Main bottleneck | Write throughput, working set vs. RAM | Memory capacity, single-threaded commands |
| Shard/cluster when | > 5–10K writes/sec OR > 1–2 TB | Dataset exceeds single-node RAM OR hot-key contention |

**How to use this in an interview:**
- When someone asks "can MySQL handle X writes/sec?" — under 5K is trivial, 10K is tuned, above 10K you shard.
- When someone asks "can Redis handle X?" — if it fits in RAM, almost certainly yes; the ceiling is memory, not throughput.
- When reaching for a database, the question is always "does my per-shard load fit inside the single-node thresholds?" If yes, don't shard. If no, shard.

**Elasticsearch (search and discovery)**

Used for product search across merchant catalogs. Not a primary data store -- always fed by a CDC pipeline from MySQL (CDC = Change Data Capture, explained below).

**When to reach for Elasticsearch:**
- Full-text product search with relevance ranking
- Faceted filtering (price, color, size, availability)
- Autocomplete and typeahead suggestions

**Sizing considerations:**
- Ideal shard size: 10-50 GB per shard, up to ~200 million documents per shard.
- Total indices per cluster: low thousands is fine; tens of thousands strains the cluster state (which is held in memory on every node).
- **Index-per-merchant does not work at Shopify scale.** Millions of merchants would mean millions of indices, which collapses cluster state.
- The pragmatic pattern: shared indices with a routing key (`tenant_id`) that pins each document to one shard, so a per-merchant query only hits one shard rather than all of them. Dedicated indices only for large merchants (>10K products), merchants with unique analyzer needs (language-specific stemming), or merchants with very high query load justifying isolation.

**Key patterns:**
- **Routing keys for multi-tenancy.** Routing is shard-placement, not a query filter -- it's lower-level than a filter. `PUT /products/_doc/123?routing=tenant_42` pins the document to shard `hash("tenant_42") % num_shards`. At query time, `?routing=tenant_42` sends the query to only that one shard instead of fanning out to all of them. You still apply a `tenant_id` filter in the query itself for correctness (multiple tenants share a shard). **Routing for speed, filter for correctness.**
- **Variant-aware documents.** One document per product with variant attributes flattened as arrays. Never one document per variant (a product with 300 variants becomes 300 documents, ballooning the index and duplicating results).
- **`post_filter` for faceted search** so aggregation counts reflect the full result set, not the filtered subset. Otherwise selecting "red" hides all other color facets.
- **`function_score`** for merchant-customizable relevance boosting (boost "new arrivals" or "best sellers" without reindexing). Index-time boosts would require reindexing on every change.
- **Store `in_stock: boolean`, not real-time inventory counts.** Inventory changes too frequently for ES to keep up; it's meant for search, not hot counters. The boolean flips only on threshold crossings (count reaches 0, or crosses low-stock threshold), which generates reasonable index update volume.
- **OOS items stay in the index with `in_stock: false`, not removed.** Keeping them discoverable matters for SEO, "notify me when back in stock" intent, and merchant UX. Only on product deletion (merchant removes the product entirely) is the document removed.
- **CDC fires on product-level state changes, not on every unit sale.** The product table has `in_stock`; the inventory_levels table has the actual counts. CDC on products → ES works; CDC on inventory_levels would overwhelm the indexer.

**PostgreSQL (control plane, platform metadata)**

Used for platform-level data that lives outside the pod structure: pod fleet state, shop-to-pod routing tables, migration records, rate limit tier configuration, feature flags. Decoupled from tenant data so the control plane survives a pod failure.

**Latency concern:** you don't read the control plane on every request. The pattern is:
1. Application loads configuration into in-memory cache on startup.
2. A background thread polls PostgreSQL every 30-60 seconds for updates.
3. The hot path reads from the in-memory cache. Control-plane latency is not on the request path.
4. If the control plane is down, the application keeps running with its last-known config.

**Data warehouse (OLAP -- Snowflake, BigQuery, Redshift, or similar)**

OLAP = Online Analytical Processing. Separate from the OLTP databases. Used for:
- Cross-tenant analytics (revenue across all merchants, cohort analyses)
- Long-term cold storage of audit logs (7-year regulatory retention after hot tier expires)
- BI dashboards and merchant-facing reports

Populated via CDC from MySQL and via Kafka event streams. Query latency is seconds-to-minutes, which is fine for analytics but never for the request path.

### Message Queues

**Kafka (event backbone)**

Kafka is a distributed log-structured message system. Events are written to topics (named streams). Each topic is partitioned; each partition is an ordered log of events.

**When to reach for Kafka:**
- Cross-service event propagation (order created, inventory changed, product updated)
- CDC pipelines for feeding search indices, analytics, external sync
- Webhook event ingestion and fan-out
- Real-time streaming for merchant dashboards

**Key patterns to know:**
- **Topic-per-event-type with consumer groups.** Each event type gets its own topic (`orders.created`, `orders.paid`, `inventory.updated`). A consumer group is a set of workers that cooperatively consume a topic -- Kafka partitions the work across them, so the group as a whole gets each message exactly once. Multiple consumer groups on the same topic each get their own independent copy of the stream. The Search Indexer, Analytics, and Webhook Delivery services each have their own consumer groups on `orders.created`, so they scale independently, fail independently, and can rewind offsets independently (e.g., Analytics replays a day of data without affecting Search).
- **Consumer lag as backpressure signal.** Kafka tracks how far each consumer group is behind the tip of the topic. During traffic spikes, producers keep writing at full speed; if consumers can't keep up, lag grows. Once lag crosses a threshold, you respond: auto-scale consumers, shed low-priority work, or alert on-call. Kafka acts as a buffer, absorbing bursts.
- **Transactional outbox → Kafka relay.** Never publish to Kafka directly from application code after a DB commit (dual-write risk -- a crash between commit and publish loses the event). Write the event to an outbox table in the same DB transaction, and have a separate process relay from outbox to Kafka.
- **CDC via Debezium.** Debezium is a tool that tails MySQL's binlog (or PostgreSQL's WAL) and emits row changes as Kafka events. Mentioned in more detail in [CDC](#change-data-capture-cdc).
- **Per-partition ordering.** Messages within a partition are ordered; across partitions they're not. Typical partitioning key is `shop_id` -- so per-shop ordering is guaranteed, but global ordering is not.

**Redis-backed job queues (Sidekiq, Resque)**

These are a different pattern from Kafka. Where Kafka is a durable log of events, a job queue is a work queue with at-least-once execution semantics.

**When to reach for job queues:**
- Short-lived async work that needs low-latency pickup (within seconds).
- Webhook HTTP deliveries, email sends, background sweepers.
- Work with per-job retry logic and dead-letter behavior.

In practice: Kafka is the event backbone ("this happened"), and job queues are the worker dispatch ("do this thing now"). They often chain: a Kafka consumer reads events and enqueues jobs.

### Caching

**Memcached** for in-pod caching of rendered templates and product blobs. See the Redis comparison above.

**CDN / Edge** (Cloudflare, in Shopify's case) as the first line of defense during BFCM. Static assets, cached storefront pages, and stale-while-revalidate responses are served at the edge. Cache hit rates exceed 90% during peak events, meaning 90% of requests never touch the application layer.

---

## Architecture Patterns

### Pod-Based Tenant Isolation

**How to describe this problem:** "At Shopify scale the multi-tenant problem has a specific shape -- millions of tenants on shared infrastructure. A single shared database doesn't isolate tenants (one flash sale kills everyone). Database-per-tenant is operationally impossible at millions of databases. The standard answer is cellular architecture: group tenants into isolated 'cells' or 'pods,' each with its own independent data tier."

A pod is a self-contained infrastructure unit:

```
Pod N
  ├── Application Servers (horizontally scaled within the pod)
  ├── MySQL Primary + Read Replicas
  ├── Redis
  └── Memcached
```

Thousands of shops per pod. ~100+ pods in the fleet.

**How are shops assigned to pods?** Not by hashing the shop ID. There is an explicit `shop_id → pod_id` mapping table in the central control-plane database. This matters because:
- **Explicit mapping is rebalanceable.** To move a shop to a different pod, update one row. If you hashed, moving one shop forces rehashing many.
- **Pods are bin-packed by resource consumption, not by tenant count.** A pod hosting 5,000 tiny shops may have similar load to a pod hosting 50 medium shops. The scheduler places new shops to balance resource usage.
- **Dedicated pods for high-value tenants.** Enterprise merchants (Shopify Plus) get their own pod or small-N pods -- the "hot shard" pattern. Deliberately isolate the merchants that could be noisy or whose uptime is most critical.
- **Shared pods for the long tail.** SMB merchants share pods densely.

**Pod isolation is near-total:**
- Tenant data never crosses pods. Shop A's orders, products, and customers live only on its pod.
- Global platform services (authentication, OAuth, app marketplace, billing, admin consoles) are shared across pods -- separate services outside the pod structure.
- Cross-tenant analytics (e.g., "top products across all merchants") does not live-query pods. It goes through the data warehouse, which has a copy of everything via CDC.
- A merchant lives on exactly one pod at a time. Migrating between pods is explicit and uses zero-downtime tooling (see [Ghostferry](#zero-downtime-migration) below).

### Edge Routing and Load Shedding (Shopify calls it "Sorting Hat")

**How to describe this problem:** "We need a layer at the edge -- before the application -- that handles tenant-aware routing and admission control. The industry pattern here is an edge proxy with scripting capability: Nginx + Lua (OpenResty), Envoy filters, or a custom Go service at the L7 load balancer."

Shopify's implementation is OpenResty (Nginx with embedded Lua). It handles three things:

1. **Shop-to-pod routing.** Looks up shop_id in a fast store (Redis or etcd) to determine which pod owns the shop. Sub-millisecond. Custom domain resolution (converting `cool-store.com` to `cool-store.myshopify.com` and then to Pod 7) also happens here.
2. **Load shedding.** Rejects overloaded requests before they consume application-layer resources. A 503 at the edge costs microseconds. A 503 from a Rails process costs a thread, a database connection, and memory.
3. **Admission control.** During BFCM, per-pod and per-shop capacity limits enforce fairness. A single merchant cannot exhaust a pod's resources.

**How the edge detects overload (signals it combines):**

- **Health check polling.** Periodically ping each pod's `/health` endpoint; pods return structured stats (active connections, DB pool usage, queue depth, p99 latency, error rate). Thresholds flag pods as degraded.
- **Backend-reported backpressure headers.** Pods add headers to every response: `X-Pod-Load: 0.92`, `X-Queue-Depth: 800`. Edge uses these on the next routing decision. Cheap because it piggybacks on existing traffic.
- **Active in-flight request counting.** Edge tracks how many requests are currently in flight to each pod; above a threshold, shed new requests.
- **Response latency observation.** Edge measures proxied request latency; rising p99 is a leading indicator of saturation.
- **Circuit breaker state.** Too many recent failures or timeouts for a pod → trip the breaker, shed or reroute.
- **Per-tenant rate counters.** Independent of pod health; if one shop exceeds its quota, shed its excess at the edge so it cannot starve other tenants sharing the pod.

The edge combines these with configurable rules: "if pod p99 > 500ms AND request rate > capacity, shed browse requests; if p99 > 800ms, shed everything except checkout." All decisions are microseconds from in-memory or Redis state.

**Key insight:** any load-shedding strategy that operates at the application layer is too late. The request has already consumed resources by the time the application sees it.

### Graceful Degradation Tiers

**How to describe this problem:** "When load exceeds capacity, degradation isn't binary (up/down). We shed features in priority order, protecting the revenue path above all."

```
Priority (highest → lowest):        Shed order (first → last):
1. Payment / checkout completion     5. Analytics, tracking pixels
2. Cart operations                   4. Recommendations, reviews
3. Product pages (core)              3. Dynamic content (serve stale cache)
4. Recommendations, reviews          2. Cart operations
5. Analytics, marketing pixels       1. Checkout (NEVER, if avoidable)
```

Even within checkout, there are degradation levels: estimated tax instead of live tax calculation, flat-rate shipping instead of carrier API lookup, simplified UI. The payment path itself is the absolute last thing to degrade.

**Mechanisms for implementing degradation:**
- **Feature flags.** A boolean-per-feature config that code checks at runtime: `if feature_enabled?(:product_recommendations)`. Flags can be flipped globally, per-tenant, or rolled out gradually. Tools: LaunchDarkly, Flipper, or homegrown.
- **Circuit breakers.** Per-dependency state (CLOSED/OPEN/HALF-OPEN) that skips calls to a failing service. Code wraps external calls: `breaker.run { tax_service.estimate(...) }`.
- **Load-based config.** Thresholds that auto-disable features when the system is struggling: "if p99 latency > 500ms for 2 minutes, disable recommendations."
- **Timeouts with fallback values.** If tax service times out, return an estimate rather than failing the checkout.
- **Traffic splitting at the load balancer.** Route some percentage of traffic to a simpler fallback service.
- **Static fallback pages at the CDN.** If the app layer is overwhelmed, serve a pre-rendered HTML page with no dynamic content.

### Circuit Breakers

**How to describe this problem:** "Any call to an external or downstream service can fail. We need to prevent a failing dependency from cascading into our own service's failure. The pattern is a circuit breaker -- track the failure rate per dependency, and stop calling it temporarily once it crosses a threshold."

Shopify uses a Ruby library called Semian for this. The industry equivalents: Hystrix (Java, deprecated but the canonical design), resilience4j (Java), gobreaker (Go). Any competent circuit-breaker library provides the same three-state model.

**States:**
- **CLOSED** (normal): requests flow through. Track failure rate.
- **OPEN** (failing): skip the call entirely, return a fallback. After a cooldown, move to HALF-OPEN.
- **HALF-OPEN** (probing): send one test request. On success, move back to CLOSED. On failure, back to OPEN.

**Critical detail: scope breakers to (service, region) or (provider, region), never global.** If Stripe's US region is degraded but EU is healthy, a global circuit breaker kills all Stripe traffic unnecessarily. Regional scoping keeps healthy routes operational. Interviewers actively probe for this.

Apply to: payment gateways, external APIs (tax, shipping, marketplaces), inter-service calls, even database connections within a pod.

### Idempotency and Exactly-Once Operations (Shopify calls it "Resumption")

**How to describe this problem:** "For operations where 'we don't know if it succeeded' is dangerous (payments, inventory decrements, order creation), we need exactly-once semantics across process crashes and network failures. The industry term for this is idempotency with durable checkpointing. A client-generated idempotency key identifies the operation, and we persist checkpoints as the operation progresses so we can resume after a crash."

1. Generate a durable idempotency key at the start of the operation.
2. Persist checkpoints as the operation progresses (e.g., "pre-auth," "auth-sent," "auth-confirmed") in a state table.
3. If the process crashes, a recovery mechanism reads the last checkpoint and resumes from there instead of starting over.
4. The idempotency key propagates end-to-end: client → your system → external provider (payment gateway).

**Key nuances (important -- the common framing here has a trap):**

- **Within a single provider: idempotency keys work.** Retrying the same request to Stripe with the same key `abc-123` makes Stripe deduplicate. This is the whole point of idempotency keys.

- **Across providers: idempotency keys do NOT prevent double-charging.** If Stripe times out on key `abc-123` and you fail over to Adyen with any key (same or different), Adyen processes the charge as brand new. If Stripe later confirms the original also succeeded, you've charged twice. Idempotency keys are scoped to a single provider -- they are not a global concept.

- **The real protection against cross-provider double-charges: status check before failover.** Before sending anything to Adyen, query Stripe for the status of `abc-123`. If Stripe says "succeeded," do not fail over. Only fail over if you can confirm the original didn't charge. Blind failover on timeout is how double-charges happen.

- **Namespace keys per provider anyway.** Not to prevent double-charging (it doesn't), but so your own idempotency ledger tracks which provider you've attempted. `stripe:abc-123 → status: sent` and `adyen:abc-123 → status: not_attempted` is clearer bookkeeping than a single `abc-123` key whose provider is ambiguous.

- **Background sweeper for orphaned operations.** The idempotency pattern handles retries from the same client request. But if the client request dies and is never retried, a background sweeper must scan for stuck operations in incomplete checkpoints and either complete or roll them back by querying provider status.

### PCI Scope Isolation

**What PCI is:** PCI stands for Payment Card Industry. The credit card networks (Visa, Mastercard, Amex) require anyone who handles credit card numbers to follow a set of security rules called **PCI DSS** (Data Security Standard). The rules are extensive and expensive to comply with: regular audits, background checks on engineers, detailed access logging, encrypted storage, network isolation, penetration testing, and more.

**What "scope" means:** any system that touches a credit card number is "in PCI scope" and has to meet all these rules. A big application with thousands of engineers cannot realistically be in PCI scope -- every code change becomes a risk, every log line could accidentally capture card data, every engineer needs clearance.

**The trick: keep card numbers out of the main application in the first place.**

**How it works:**

```
Shopper's browser loads the checkout page from shop.myshopify.com
  ├── The main page (from the Rails monolith, OUT of PCI scope)
  └── A small iframe embedded in the page, loaded from a different domain
      (e.g., vault.shopifycs.com -- a tiny PCI-scoped service)

The shopper types their card into the iframe:
  - Card number goes directly from the iframe to the tokenization service
  - The main page NEVER sees the card number
  - Browser same-origin policy physically prevents the main page's JavaScript
    from reading inside the iframe

The tokenization service returns a meaningless token like "tok_abc_xyz_123":
  - The token is a reference, not the card number
  - Only the payment provider can use it to actually charge

The iframe hands the token to the main page:
  - Main page submits the token with the checkout form
  - The monolith sends the token to Stripe / Adyen to charge
  - The monolith never saw, logged, or stored the card number
```

**The result:** only the tiny tokenization service is in PCI scope -- one small service to audit instead of the whole application. The monolith is exempt.

**Why the iframe is a real security boundary:** browsers enforce "same-origin policy" -- JavaScript on one domain cannot read the contents of an iframe from a different domain. Even if the main page were compromised by an attacker's code, that code cannot see inside the iframe. So the boundary is enforced by the browser, not by developer discipline.

**Industry-standard pattern.** Every serious payment provider offers this:
- Stripe Elements (Stripe's iframe components)
- Braintree Hosted Fields
- Adyen Web Components
- Shopify's internal name for the iframe + tokenization service is CardSink / CardServer

**In an interview:** "PCI scope is the set of systems that touch card data and are subject to the PCI DSS rules. To keep the main application out of scope, card entry lives in an iframe loaded from a separate PCI-scoped domain. The iframe sends the card directly to a small tokenization service, which returns a meaningless token. The main application only ever handles the token. Browser same-origin policy enforces the boundary physically, so compliance surface shrinks from the whole monolith to one small service."

### Dual-Path Architecture (Fast Cache + Durable Store)

**How to describe this problem:** "The hot path needs sub-ms latency, but the authoritative data lives in a durable store with higher latency. The industry pattern here is cache-aside with periodic reconciliation -- reads hit the cache first, writes go to the durable store and update the cache as a side effect, and a background sweeper corrects drift."

**A note on cache taxonomy (since this matters for which pattern applies):**
- **Cache-aside (lazy loading):** Application reads from cache, falls back to DB on miss. Writes go to DB, then update/invalidate cache. Cache is reactive. **Use for authoritative data (money, inventory).**
- **Write-through:** Application writes to cache; cache synchronously writes to DB before returning. Strong consistency, slower writes.
- **Write-behind (write-back):** Application writes to cache; cache asynchronously flushes to DB. Fast writes but risk losing data if cache dies before flush. **Tolerable for approximate state (analytics counters, rate limits) where a lost update is a minor accuracy hit.**
- **Read-through:** Reads go to the cache; on miss, the cache itself loads from DB (not the app).

**The right question is not "is this a counter?" but "what's the blast radius of losing one update?"**

| Data | Lost update consequence | Pattern |
|---|---|---|
| Inventory decrement | Overselling, real money, broken merchant trust | Authoritative (ACID) |
| Payment amount | Wrong charge, refund, escalation | Authoritative (ACID) |
| Rate limit counter | Few extra API requests get through | Approximate (write-behind OK) |
| Page view / analytics | Dashboard slightly off | Approximate |
| "Likes" / vanity metric | Display off by a few | Approximate |
| Login attempt counter | Attacker gets a few extra attempts | Mostly approximate, security-adjacent |

For Shopify:
- **Inventory / money / reservations / orders:** cache-aside. MySQL is the source of truth; Redis is an optimization layer. A Redis failure must fall back to MySQL, not lose a reservation. Inventory is a counter but is absolutely not loss-tolerant.
- **Rate limits / analytics / approximate counts:** write-behind or local approximation is acceptable.

Periodic reconciliation (a scheduled background job) catches drift by scanning recent records, comparing cache vs. DB, and correcting.

### Event-Driven Architecture

**How to describe this problem:** "Services that need to react to state changes in other services shouldn't do it via synchronous calls -- that creates tight coupling and cascading failure risk. The pattern is an event-driven architecture with a durable event log like Kafka. Services publish state changes as events; other services subscribe."

**Transactional outbox pattern** (the correct way to publish events after a DB write):

```
Application transaction:
  BEGIN
    INSERT INTO orders (...)
    INSERT INTO outbox (event_type, payload, ...)
  COMMIT

Relay process (separate, running independently):
  SELECT * FROM outbox WHERE sent_at IS NULL
  → publish to Kafka
  → UPDATE outbox SET sent_at = NOW()
```

Why: if you publish to Kafka directly after the DB commit, a crash between "commit" and "publish" loses the event. The outbox is atomic with the business data, so it cannot be lost. The relay publishes at-least-once (a crash during relay can cause a duplicate publish), so consumers must be idempotent.

**Change Data Capture (CDC)**

CDC is a technique for turning every row-level change in a database into an event stream, without application code doing anything. Databases write every change to a transaction log before committing (binlog in MySQL, WAL in PostgreSQL). A CDC tool like Debezium reads that log and publishes each change as a Kafka event. Downstream consumers (search indexers, analytics, cache invalidators) subscribe.

**Why CDC matters:** without it, every code path that mutates data has to remember to also publish an event. That's dual-writing -- brittle, easy to forget, and the DB write can succeed while the event publish fails. CDC captures at the database level, so it's impossible to skip.

**What Kafka questions to expect from an interviewer:**
- "What if your service commits to the database but crashes before publishing to Kafka?" → transactional outbox
- "What if the relay publishes but crashes before marking the outbox row as sent?" → at-least-once, consumers must be idempotent
- "How do consumers deduplicate?" → idempotency keys on messages, consumers track processed IDs
- "What's the ordering guarantee?" → per-partition (usually per-shop_id); cross-shop ordering is not guaranteed
- "Why not dual-write?" → can't atomically commit to two systems; you will lose events or publish events that never committed

### TTL-Based Self-Healing

**How to describe this problem:** "For any temporary state (reservations, locks, tokens), we use a Time-To-Live (TTL) so the state self-cleans. Abandoned state doesn't require explicit cleanup; it expires."

Inventory reservations expire after 10-15 minutes (configurable per merchant), releasing stock back to the available pool. Admission tokens for waiting rooms expire. Rate-limit buckets refill continuously. Webhook retries have a time budget (typically 48 hours total).

Without TTLs, abandoned state accumulates. During a flash sale, abandoned carts can permanently lock inventory within minutes, showing "out of stock" while no one is actually buying.

### Fail-Open over Fail-Closed

**How to describe this problem:** "Revenue-critical systems default to allowing traffic when infrastructure degrades. Fail-closed turns an infrastructure hiccup into a platform outage; fail-open accepts brief accuracy loss in exchange for availability."

| Component Down | Response |
|---|---|
| Redis (rate limiting) | Allow traffic with local in-memory approximate limiting |
| Tax service | Use estimated tax, complete the checkout |
| Recommendation engine | Skip recommendations, show default products |
| Search cluster degraded | Serve stale cached results, drop facets |
| Rate limit Redis unavailable | Allow requests, brief over-admission beats total outage |

The calculus: a few seconds of over-admission or imprecise data is cheaper than blocking all revenue.

### Adaptive Concurrency Control

**How to describe this problem:** "Not all rows see the same contention. Optimistic locking is great for the common case of low contention -- low overhead, no waiting. But for hot rows (a limited-edition drop with 10,000 concurrent buyers), optimistic locking causes retry storms. The system should adapt."

**Optimistic locking (default, 99% of traffic):** read the row with a version number; update with `WHERE version = :expected`. If another transaction beat you to it, retry. Low overhead when contention is low.

**Pessimistic locking (hot rows):** `SELECT FOR UPDATE NOWAIT` to acquire an exclusive lock before modifying. Prevents retry storms by serializing updates at the database level.

**Detecting hot rows:** a Redis counter tracks requests per SKU. If >100 concurrent requests hit one SKU within a 1-second window, escalate that SKU to pessimistic locking.

Using only optimistic causes retry storms on limited drops. Using only pessimistic wastes throughput on the 99% of rows with low contention. The system needs both.

### Storefront Extraction (CQRS at the Service Level)

**How to describe this problem:** "The storefront rendering path (product pages, collection pages, search) is read-heavy and completely different in shape from the write path (checkout, admin). The industry pattern is CQRS -- Command Query Responsibility Segregation -- at the service level. Extract a dedicated read service that serves renders from read replicas and aggressive caching, independently scaled from the write path."

The storefront service:
- Runs as its own deployment, scales independently from the monolith.
- Reads from MySQL read replicas and Memcached -- never the primary.
- Never writes. Pure read service.
- Uses stale-while-revalidate: serves cached pages even if the TTL has expired. Slightly stale product data is acceptable because the checkout path re-validates inventory before committing.
- Result: 4-6x performance improvement, 500ms TTFB (Time To First Byte) reduction during peak.

The main application still handles writes: checkout, admin, order processing, API. Reads and writes scale independently.

### Zero-Downtime Migration (Ghostferry)

**How to describe this problem:** "Moving a shop between pods means physically moving tens of GB to multiple TB of its data between database instances with no downtime. The pattern is **online database migration**: snapshot + binlog replay + cutover + verify. Shopify's tool is Ghostferry; generic equivalents are gh-ost, pt-online-schema-change, and Vitess resharding."

**Phases:**

1. **Bulk copy (snapshot):** scan rows for the target shop on the source pod (`WHERE shop_id = X`), write them to the destination pod. Takes minutes to hours depending on size. The source keeps serving live traffic -- shoppers and merchants see nothing.

2. **Binlog streaming (delta catch-up):** while the bulk copy runs, writes are still happening on the source. Tail the source's binlog and continuously replay any changes to the target shop's data on the destination. Runs until source and destination are in sync.

3. **Throttling:** the migration tool monitors its own impact on the source (replica lag, query latency, disk IO) and slows down if it's hurting live traffic. You cannot hammer a production database with unbounded migration.

4. **Cutover:** when binlog positions match (source and destination in sync), brief write pause (<1 second), flip the routing table entry in the control plane, unpause. New requests go to the destination pod.

5. **Verification:** checksum comparison between source and destination rows before and after cutover. Mismatch → abort and rollback.

6. **Cleanup:** background job eventually deletes the shop's data from the source pod.

**Ancillary systems that need handling:**
- **Redis state** is treated as cache -- doesn't migrate. Destination warms its cache after cutover.
- **Background jobs** (Sidekiq queues) tied to the shop need routing updates. Usually flushed before cutover.
- **Object storage** (S3 product images) doesn't move -- shared across pods, references keep working.
- **External integrations** (webhooks, OAuth tokens) keep working because the shop's identity and public domain don't change.

**How it's orchestrated:** not via general-purpose message queues. A dedicated **migration orchestrator service** tracks state per migration (pending → snapshotting → streaming → verifying → cutover → complete → cleanup). Triggered by capacity signals (pod resource pressure, bin-packing decisions) or ops requests (enterprise merchant needs dedicated pod). At Shopify scale, hundreds of migrations run continuously across the fleet -- routine, not rare.

Rebalancing triggers: pod CPU > 70%, disk > 80%, query latency p99 above threshold, or a merchant growing from SMB to enterprise tier and needing a dedicated pod.

---

## Patterns for Specific Problem Domains

### Payment Systems

**How to frame it:** "A payment system is fundamentally an exactly-once distributed transaction problem with hard compliance requirements. The three hardest subproblems are PCI scope isolation, exactly-once semantics across retries and failover, and multi-gateway resilience."

- Iframe + tokenization service for PCI scope isolation
- Idempotency keys with checkpointing (Resumption pattern), namespaced per provider
- Payment state machine: pending → authorized → captured → settled (with void and refund branches)
- Multi-gateway waterfall failover: try preferred provider, fall back on timeout or circuit break
- Circuit breakers per (provider, region)
- Retry safety classification: 5xx errors are usually safe to retry; hard declines are not; timeouts require a status check before retry
- Authorization hold expiry tracking (7 days for credit, 1 day for debit)

### Inventory and Stock

**How to frame it:** "Inventory is a high-contention distributed write problem. The key insight is that display and allocation are separate problems with separate consistency requirements -- display tolerates staleness, allocation does not. The consistency requirement on allocation is strict (no oversell), but the contention shape is bimodal: most SKUs have low contention, a few have extreme contention (limited drops). The pattern is reservation-based allocation with adaptive locking."

**Display vs. allocation -- the core framing for OOS / race condition questions:**
- **Display** (stock badge on product page, "only 3 left!") can be stale. Worst case: shopper sees "in stock," gets a clean "just sold out" error at checkout. Read from Redis with TTL or event-invalidated cache.
- **Allocation** (the actual decrement when the reservation is created) must be strictly consistent. Worst case of getting this wrong is overselling -- merchant-breaking, requires manual refunds and apology emails.
- **The asymmetry matters:** underselling is a lost sale (mildly bad). Overselling is a broken promise (catastrophic). Design around preventing overselling; accept some underselling.

**The reservation pattern (the centerpiece):**
- Reserve on checkout start, confirm on payment success, release on abandonment or via TTL expiry.
- The reservation creation is where locking and correctness guarantees are applied.
- Available stock for new shoppers = `on_hand - reserved`.
- TTL self-heals abandoned carts (no background cleanup needed for correctness, though a reaper is a belt-and-suspenders addition).

**Patterns:**
- Reservation-based allocation with TTL (not decrement-on-purchase)
- Dual-path: Redis for availability checks (display), MySQL for ACID decrements (allocation)
- Adaptive locking: optimistic default, pessimistic for hot SKUs
- CHECK constraint as database-level guard (`quantity_on_hand >= quantity_reserved`) -- last line of defense even if app code has a bug
- Cross-channel sync via Kafka (accept eventual consistency with external marketplaces)
- Buffer stock: withhold a percentage from external channels to absorb sync lag
- Background reaper for expired reservations (belt-and-suspenders)

**"Make it fast for BFCM" lever stack (apply in order, stop when latency budget is met):**

1. **Shard by pod** -- already done. BFCM load spreads across ~100 pods; a pod handles thousands of shops independently.
2. **Separate display from allocation** -- 95%+ of inventory reads are display, which never hits MySQL.
3. **Single conditional UPDATE, no SELECT first:**
   ```sql
   UPDATE inventory_levels
      SET reserved = reserved + :qty, version = version + 1
    WHERE sku_id = :sku_id
      AND on_hand - reserved >= :qty
   ```
   Zero affected rows = failed (out of stock or version conflict). One round-trip.
4. **Keep the transaction short.** UPDATE + outbox INSERT + COMMIT. No external calls inside the transaction. Single-digit milliseconds.
5. **Adaptive locking:** optimistic by default, pessimistic (`SELECT FOR UPDATE NOWAIT`) for hot SKUs detected via a Redis concurrency counter.
6. **Redis-first reservation for extreme hot paths.** Atomic Lua script does check-and-decrement in Redis; async persistence to MySQL via outbox. MySQL is source of truth for recovery but not on the hot path. Sub-millisecond reservation latency.
7. **Fast rejection for sold-out SKUs.** Once Redis shows 0, short-circuit with "sold out" without touching MySQL. During a flash sale, >99% of requests may be doomed -- don't spend DB capacity on them.
8. **Virtual SKU sharding for limited drops.** Split a single SKU across N sub-rows (10,000 units → 10 rows of 1,000). Reservations hash across sub-rows. Contention spreads from 1 row to N.
9. **Hardware and config:** NVMe SSDs, InnoDB buffer pool sized to keep inventory in memory, tuned `innodb_flush_log_at_trx_commit`, connection pooling via ProxySQL.
10. **Pre-warm and load test.** Spin up capacity before the event; run synthetic traffic at 2x expected peak; chaos-test failover scenarios in Game Days.

**How to answer "how do you handle OOS and race conditions":** "I separate display from allocation. Display reads from cache -- staleness is tolerable because a clean 'just sold out' error at checkout is recoverable. Allocation goes through a reservation system in MySQL: optimistic locking by default, pessimistic for hot SKUs, with a CHECK constraint as a last-line guard. The reservation pattern -- reserve on checkout, confirm on payment, release on abandon -- is what lets me hold stock during checkout without overselling."

### High-Traffic Events (Flash Sales, BFCM)

**How to frame it:** "Flash sales turn normal commerce into a capacity-planning problem. The system must handle 100x normal load, prioritize the revenue path, and fail gracefully when capacity is exceeded. The patterns: edge-layer shedding, admission control, tiered degradation, pre-warming."

- Edge routing layer for load shedding
- Queue-based admission control (virtual waiting room with FIFO fairness)
- Pre-warming: scale infrastructure before the event, not reactively
- Load testing (Shopify calls their tool Genghis; generically, think synthetic traffic at BFCM scale) + chaos engineering (network fault injection via Toxiproxy or similar) in Game Days
- Tiered degradation: shed analytics → recommendations → dynamic content → stale cache → static fallback; checkout last
- Pod-based horizontal scaling: pods auto-scale independently

### Multi-Tenant Isolation

**How to frame it:** "At this scale, multi-tenancy is a cellular architecture problem. Tenants are grouped into isolated cells (pods), routed explicitly, and rebalanced as needed. Noisy neighbor prevention happens at multiple layers -- edge, pod, and application."

- Pod architecture with database-per-pod
- Edge routing layer for sub-ms tenant-to-pod routing
- Per-tenant rate limiting at both edge and application layers (defense in depth)
- Noisy neighbor prevention: per-shop query budgets, connection limits, per-tenant cache quotas
- `shop_id` / `tenant_id` on every table row, enforced by automatic application-level query scopes
- Module boundary enforcement (Shopify uses Packwerk in Rails; generic equivalents are ArchUnit in Java, or custom lint rules in any language) to prevent code from bypassing tenant scopes

### Webhook and Event Delivery

**How to frame it:** "Reliable webhook delivery is an at-least-once async fan-out problem. Events come in from many producers; each event fans out to many subscribers; each subscriber has different reliability. The patterns: durable event log, per-subscriber queues, retries with backoff, circuit breakers per endpoint."

- Kafka for event ingestion; fan-out in a separate service (never synchronous in the producer)
- Per-endpoint delivery workers with queue isolation (so one slow consumer doesn't block others -- head-of-line blocking)
- HMAC-SHA256 signing per app secret (HMAC = Hash-based Message Authentication Code, a way to prove the message came from you and wasn't tampered with)
- At-least-once delivery with deterministic idempotency keys (derived from `event_id + subscription_id`)
- Exponential backoff with jitter, capped retry budget (48 hours), then dead letter queue
- Auto-disable endpoints with sustained failure rates

### Search and Discovery

**How to frame it:** "Search is a two-stage problem: retrieval (get top-K candidates cheaply via an inverted index) and ranking (carefully order the top-K). Multi-tenant search adds a shard-routing problem: shared indices with tenant routing keys for the long tail, dedicated indices for whales. The indexing pipeline is a classic derived-view problem with the database as source of truth and ES kept in sync via CDC."

**Core patterns:**
- Elasticsearch with hybrid tenant isolation (shared indices with routing for most merchants; dedicated indices for merchants over ~10K products)
- Variant-aware indexing: one document per product, variant attributes as flattened arrays
- CDC pipeline (Debezium → Kafka → index workers → Elasticsearch) for near-real-time updates
- Merchant-customizable relevance via `function_score`
- Separate autocomplete subsystem (completion suggesters, prefix tries, sub-100ms latency)
- Dynamic facets from product attributes, not hardcoded categories

**Common follow-up search questions (be ready for any of these):**

*Relevance:*
- BM25 as the default scoring algorithm (evolution of TF-IDF). Field boosts (`title^3, description^1`). Decay functions for recency.
- Measurement: CTR per query, conversion rate, NDCG if you have relevance judgments. A/B test changes.
- Learning to Rank (LTR): two-stage pipeline. ES retrieves top 1000 via BM25; an ML re-ranker (LambdaMART, XGBoost) reorders top 1000 → top 50 using click data.

*Query understanding:*
- Typos: fuzzy matching (Levenshtein), "did you mean" from query log analysis, phonetic matching (Soundex) for names.
- Synonyms: synonym files, index-time (bloats index, faster queries) vs. query-time (smaller index, slower queries). Per-language sets.
- Structured queries ("red nike running shoes under $80"): entity extraction routes to filters vs. full-text. Called query understanding / semantic parsing.

*Autocomplete:*
- Sub-100ms requires a dedicated path, not full ES queries per keystroke.
- Completion suggester (FST -- Finite State Transducer, in-memory) for sub-10ms responses. Edge n-grams as an alternative.
- Popularity weighting from query logs. Client-side debounce (150ms). CDN cache for common prefixes.

*Semantic and vector search:*
- Embeddings via text embedding model (Sentence-BERT, OpenAI embeddings). Stored as `dense_vector` in ES or a dedicated vector DB (Pinecone, Weaviate, pgvector).
- k-NN search with HNSW (Hierarchical Navigable Small World) indexing.
- Hybrid: combine BM25 and vector similarity via Reciprocal Rank Fusion (RRF).
- Worth it for intent-based queries ("gift for dad who likes cooking"). Keyword wins for exact-match.

*Personalization:*
- Re-rank top-K based on user signals (browsing history, purchase history, category affinity). Don't personalize retrieval -- keep that consistent for debugging.
- Cold start: popularity fallback.
- Collaborative filtering ("users who bought X also bought Y") needs interaction data. Content-based similarity works for cold start.

*Index management:*
- Zero-downtime reindex: blue-green with aliases. Create `products_v2`, bulk populate, atomically swap the alias from v1, delete v1.
- Bulk imports: throttle via back-pressure to stay within cluster write capacity.

*Failure modes:*
- ES cluster down: fall back to DB search (slower, less relevant but functional), drop facets, serve cached results for popular queries, static "browse by category" fallback.
- Partial shard failure: queries return partial results with `_shards.failed` count. Decide per query: fail closed or fail open with a warning.
- Indexing pipeline: Kafka buffers during ES outages; on recovery the indexer replays from last offset. Monitor Kafka consumer lag.

### API Rate Limiting

**How to frame it:** "Multi-tenant API rate limiting has to be fair across tenants, predictable for clients, and cheap on the hot path. For GraphQL specifically, you can do better than request counting -- you can cost queries statically and budget by complexity."

- Cost-based rate limiting for GraphQL: static query complexity analysis before execution
- Leaky bucket: 50 points/sec restore rate, 1,000 point max capacity per `(app_id, shop_id)`
- Nested connection multipliers: `products(first:50) { variants(first:100) }` costs ~5,050 points
- Distributed enforcement via Redis Lua scripts (atomic check-and-decrement)
- Local in-memory approximation for sub-ms hot-path latency; background sync to Redis
- Fail-open on Redis failure (brief over-admission > blocking all API traffic)

---

## Common Mistakes That Fail Candidates

1. **Single shared database for millions of merchants.** Propose cellular / pod-based isolation. Database-per-tenant is equally wrong at this scale (millions of databases is operationally impossible).

2. **Global circuit breakers.** Always specify (provider, region) or (service, pod) granularity. Interviewers actively probe for this.

3. **Shedding checkout before shedding everything else.** Checkout is the revenue path. Shed analytics, recommendations, and personalization first. Even within checkout, degrade non-critical features (tax estimation, flat-rate shipping) before touching the payment path.

4. **No TTL on reservations.** Reservations without expiration create zombie locks that exhaust inventory during flash sales.

5. **Application-layer load shedding only.** If the request reached your Rails process, you already consumed resources. Shed at the edge.

6. **Synchronous fan-out in event producers.** Order creation should publish one event to Kafka. A separate service handles fan-out to subscribers. Synchronous fan-out makes order latency proportional to subscriber count.

7. **Same idempotency key across payment providers during failover.** Namespace per provider to prevent double-charging across gateways. And before failover, query the original provider for the transaction status.

8. **One locking strategy for all contention levels.** Optimistic for the common case, pessimistic for hot rows. The system must adapt.

9. **Storing volatile data in the wrong system.** Real-time inventory counts do not belong in Elasticsearch. Rate limit counters do not belong in the primary database. Match data volatility to system write throughput.

10. **Fail-closed on cache/infrastructure failure.** Redis down should not mean "block all traffic." Revenue-critical systems fail open with degraded accuracy, not total unavailability.

11. **Dual-writing to two systems without an outbox.** Writing to the database and Kafka separately will eventually lose events. Use transactional outbox or CDC.

12. **Index-per-tenant at Shopify scale.** Millions of Elasticsearch indices will collapse the cluster. Use shared indices with a routing key.

---

## Shopify-Specific Vocabulary

Name-drop once to signal you've done your homework, then describe the underlying pattern:

| Term | Generic Category | What It Is |
|---|---|---|
| **Pod** | Cellular architecture / tenant shard | Self-contained infrastructure unit (app servers + DB + cache) hosting a group of shops |
| **Sorting Hat** | Edge routing / L7 proxy with scripting | OpenResty/Lua layer for tenant-aware routing and load shedding |
| **Ghostferry** | Zero-downtime DB migration | MySQL-to-MySQL data migration tool with binlog replay and cutover |
| **Semian** | Circuit breaker library | Ruby library providing per-resource circuit breakers |
| **CardSink / CardServer** | PCI scope isolation | Iframe captures card data; separate service tokenizes; main app only sees tokens |
| **Resumption** | Durable idempotency | Checkpoint-based idempotency framework for exactly-once payment semantics |
| **Packwerk** | Module boundary enforcement | Rails-specific tool for enforcing package/module boundaries in a monolith |
| **Genghis** | Load testing at scale | Internal tool for generating BFCM-level synthetic traffic |
| **Toxiproxy** | Chaos engineering / fault injection | Open-source tool for simulating network failures in Game Days |
| **BFCM** | (concept, not a tool) | Black Friday / Cyber Monday -- the peak traffic event that drives all scalability decisions |
| **Storefront extraction** | CQRS / read-write separation | Splitting read-heavy rendering from the monolith into a dedicated read service |
| **Adyen** | Payment gateway (like Stripe) | Dutch payment provider; Shopify uses multiple gateways and fails over between them |

---

## The 60-Second Mental Model

When you sit down for a Shopify system design round, run every design decision through these filters:

1. **What happens during BFCM?** If your design handles normal load but collapses at 100x, redesign.
2. **What is the blast radius?** If one component failing takes down the whole platform, add isolation (pods, circuit breakers, bulkheads).
3. **What is the degradation path?** Not "does it work or not" but "what do we shed first, and what do we protect?"
4. **Where does consistency matter?** Strong consistency for money and inventory decrements. Eventual consistency for everything else (stock display, search results, storefront pages).
5. **Can this fail open?** If yes, it should. Revenue > precision for non-financial paths.

Frame everything in merchant impact: "a merchant running a flash sale with 50,000 concurrent shoppers experiences sub-200ms checkout latency" is better than "the system handles 100K RPS."
