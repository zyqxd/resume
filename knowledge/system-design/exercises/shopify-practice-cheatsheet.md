# Shopify Practice Interview: Cheat Sheet

Post-practice distillation of everything covered in the mock interview. Each subsection is one sentence.

---

## Scale & Setup

- **Merchants:** 5M total, 500K active, 50K enterprise (Plus tier)
- **Shoppers:** 700M known, 100M daily active
- **Read/write ratio:** ~95:5 normal, ~98:2 during BFCM
- **BFCM peak:** 280M req/min at the edge (~4.7M req/sec), 100M+ orders over the weekend
- **Per-pod math (target):** ~100 pods → 1,500 writes/sec, ~100GB storage, ~5K reads/sec per pod — all inside comfortable MySQL territory

## High-Level Architecture

- **Multi-tenant isolation:** pod-based cellular architecture — each pod is a self-contained unit (app servers + MySQL primary/replicas + Redis + Memcached) hosting thousands of shops, bin-packed by resource usage
- **Sharding key:** explicit `shop_id → pod_id` mapping in a control-plane Postgres (not hash-based), because it lets you move individual shops without rehashing the fleet
- **Edge routing:** Nginx + Lua (OpenResty) looks up shop → pod in a Redis cache fronting the control-plane DB, sub-millisecond, and handles load shedding at the edge before requests consume app resources
- **Service topology:** monolith for ACID-critical transactional work (checkout, payments, inventory) plus carved-out services (search, webhooks, reporting, notifications) each with different scaling shapes
- **Storefront extraction:** separate read-only service reading from replicas + aggressive caching, scaled independently — classic CQRS pattern separating reads from writes
- **Global platform services:** auth, billing, app marketplace live outside the pod structure as separate services, each with their own appropriately-chosen data store (not one shared control-plane DB)
- **Async communication:** Kafka as the event backbone, partitioned by shop_id, with topic-per-event-type and independent consumer groups for each downstream service
- **Transactional outbox:** monolith writes events to an `outbox` table in the same DB transaction as the business data, and a relay process publishes to Kafka — prevents dual-write data loss
- **Consumer dedup:** at-least-once delivery means consumers must dedupe on producer-assigned idempotency keys, with the dedup state stored in Redis with a TTL longer than Kafka redelivery windows

## Checkout & Payments

- **Resumption pattern:** durable idempotency key + checkpointed progress so a crashed payment operation can resume from its last checkpoint rather than restart
- **Per-provider key namespacing:** each payment provider gets its own key namespace (`stripe:abc-123`, `adyen:abc-123`) for correct bookkeeping in your idempotency ledger
- **Multi-gateway failover:** before failing over from Stripe to Adyen, query Stripe for transaction status — only fail over if you can confirm the original didn't charge (keys alone don't prevent cross-provider double-charges)
- **Circuit breakers:** wrap payment gateway calls with Semian-style breakers scoped per `(provider, region)` never globally, so a US outage doesn't kill EU traffic
- **PCI isolation:** card data is captured in an iframe loaded from a separate PCI-scoped domain, tokenized by a small service, and only the opaque token flows through the monolith — browser same-origin policy is the physical security boundary
- **Reservation timing:** reserve inventory at **checkout-start**, not add-to-cart — checkout intent is commit-grade, cart intent is browsing, and BFCM abandoned-cart rates would create zombie reservations otherwise
- **Hot SKU admission:** for extreme-demand items (sneaker drops), layer a queue-based virtual waiting room on top of the normal flow to admit shoppers at the rate the inventory system can handle
- **Tax degradation:** never block checkout — fall back to a cached previous-lookup tax rate (rates change slowly so cache hit rate is high) with a merchant-configured override for edge cases
- **Shipping degradation:** never block checkout — fall back to the merchant's configured flat-rate shipping table when live carrier API is slow or down
- **Fraud degradation:** fail open with a review queue — accept the transaction and flag it for manual review, because lost-sale cost exceeds occasional-fraud cost
- **Sync vs async boundary:** the payment path is synchronous (monolith → gateway via HTTPS, monolith → MySQL transaction, monolith → shopper HTTP response); Kafka is only for post-commit event propagation (notifications, webhooks, analytics)
- **Slow gateway handling:** 30s timeout, write "payment pending" state via Resumption pattern, return "processing" to shopper, background worker polls gateway for resolution and notifies shopper when resolved

## Inventory

- **Data model:** `items` (core product), `item_variants` (FK to items; size/color combos), `locations` (warehouses/stores), `inventory_levels` (join of variant × location with `on_hand` and `reserved` counts), and `reservations` as its own table (variant, cart, qty, status, `expires_at`)
- **Authoritative storage choice:** either MySQL-authoritative (simpler — single source of truth with a background reaper handling TTL expiry) or Redis-fast-path-plus-MySQL-durable (more complex — sub-ms latency for hot paths with async persistence) — both defensible, pick one
- **Redis failure behavior:** fall back to MySQL (slower but correct) — never block all traffic because the cache is unavailable, and inventory is NOT loss-tolerant so Redis can never be the sole source of truth
- **Hot SKU concurrency:** virtual sharding splits a single hot row across N sub-rows/keys that logically represent the same SKU, distributing contention — works in both Redis and MySQL
- **MySQL hot-row math:** pessimistic locking serializes 10,000 concurrent reservations into ~50 seconds of serial work (broken), so use optimistic locking with virtual sharding, or Redis Lua atomic check-and-decrement for lower latency
- **Last-unit problem:** as virtually sharded stock drains, some shards empty before others, causing shoppers to see "sold out" while stock exists on other shards — mitigated by fallback probing, periodic rebalancing, or single-shard mode at low stock
- **Static vs dynamic sharding:** pre-shard known high-demand SKUs (BFCM items, planned drops); dynamically shard on detecting unexpected hot SKUs via Redis concurrency counter crossing a threshold — most systems do both
- **Multi-warehouse fulfillment:** a fulfillment service (separate from inventory) routes orders based on a scoring function (proximity, stock, cost, capacity) asynchronously after order creation, and can split a single order across locations
- **Cross-channel sync:** Shopify is the authoritative source; external channels (Amazon, eBay, POS) sync via Kafka events with eventual consistency, and POS tolerates offline mode with local cache + reconciliation on reconnection
- **Buffer stock:** withhold a merchant-configurable percentage of each SKU from external channels to absorb their sync lag, trading sales velocity for reduced oversell risk

## Cross-Cutting Principles (surfaced repeatedly)

- **Checkout is the revenue path:** every degradation decision points toward protecting the payment path first — shed analytics, recommendations, personalization before touching checkout
- **Fail open for revenue-critical systems:** Redis down, tax service down, fraud service degraded — accept brief accuracy loss rather than block all traffic
- **ACID for money and inventory; approximate for counters:** blast-radius-of-a-lost-update is the test, not "is it a counter"
- **Regional scoping for circuit breakers:** always `(provider, region)` or `(service, pod)`, never global
- **Transactional outbox over dual-write:** never `COMMIT` + `kafka.publish()` separately — use outbox or CDC
- **Virtual sharding is the universal pattern for hot-row contention:** applies to Redis, MySQL, or any system — changes throughput ceiling, not fundamental design

## Still on the Table (not covered in this practice run)

- Search (variant-aware indexing, multi-tenant ES routing, CDC pipeline)
- Webhook delivery (at-least-once, per-endpoint isolation, HMAC signing)
- Notifications (transactional email fan-out, templating, provider failover)
- Custom domains and themes (Liquid rendering, theme versioning, domain routing at edge)
- Analytics and reporting (data warehouse ingest, merchant dashboards)
