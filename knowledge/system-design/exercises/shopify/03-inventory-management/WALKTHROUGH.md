# Walkthrough: Design a Real-Time Inventory Management System (Shopify)

## Step 1: Clarify Requirements and Scope

Before drawing anything, confirm the scope with the interviewer:
- How many merchants and SKUs? (Millions of merchants, some with 100K+ SKUs)
- What does "real-time" mean here? (Sub-100ms reservation, not sub-second display)
- Are all SKUs high-contention? (No -- 99% are low-contention; limited drops are the hard problem)
- Is multi-warehouse required? (Yes -- stock is distributed, fulfillment routing matters)
- What sales channels need sync? (Online store, POS, marketplace integrations like Amazon/eBay)

This scoping is critical because it separates two fundamentally different write patterns: the common case (low-contention SKUs where optimistic locking works fine) from the hard case (limited drops with thousands of concurrent buyers fighting for single-digit stock). The entire architecture bends around this distinction.

**Primary design constraint:** Oversell prevention. Selling one unit more than you have is worse than failing to sell one unit you do have. Every architectural choice filters through this lens.

---

## Step 2: High-Level Architecture

```
Sales Channels (Online Store, POS, Amazon, eBay)
    |
    | HTTPS / WebSocket
    v
+-------------------------+
|     API Gateway         |  (rate limiting, auth, tenant routing)
|  (pod-based routing)    |
+-----------+-------------+
            |
  +---------+---------+
  |                   |
  v                   v
+------------+   +---------------+
| Reservation|   | Inventory     |
| Service    |   | Query Service |  (read-side, eventual consistency)
| (write)    |   | (read)        |
+-----+------+   +-------+-------+
      |                   |
      v                   v
+------------+   +---------------+
| Inventory  |   | Read Replica  |
| Store      |   | / Cache       |
| (Postgres) |   | (Redis)       |
+-----+------+   +---------------+
      |
      v
+-----+------+     +------------------+
| Event Bus  | --> | Channel Sync     |
| (Kafka)    |     | Service          |
+-----+------+     +------------------+
      |
      v
+--------------+
| Audit Log    |
| (append-only)|
+--------------+
```

### Core Components

1. **API Gateway** -- routes requests to the correct pod (Shopify's multi-tenant isolation unit). Handles rate limiting per merchant.
2. **Reservation Service** -- the write path. Handles reserve, confirm, and release operations with strong consistency.
3. **Inventory Query Service** -- the read path. Serves stock levels from cache/read replicas with eventual consistency.
4. **Inventory Store (PostgreSQL)** -- source of truth for stock levels and reservations. Partitioned by merchant/shop.
5. **Event Bus (Kafka)** -- publishes inventory change events for cross-channel sync, alerting, and analytics.
6. **Channel Sync Service** -- consumes events and pushes updates to external channels (Amazon, eBay, POS devices).
7. **Audit Log** -- append-only record of every inventory mutation for compliance and debugging.

---

## Step 3: Data Model

### Core Tables

```sql
-- Per-location stock record. One row per (SKU, warehouse).
inventory_items (
  id              BIGINT PRIMARY KEY,
  shop_id         BIGINT NOT NULL,        -- tenant isolation
  sku             VARCHAR(255) NOT NULL,
  location_id     BIGINT NOT NULL,        -- warehouse / fulfillment center
  quantity_on_hand INT NOT NULL DEFAULT 0, -- physical stock
  quantity_reserved INT NOT NULL DEFAULT 0,-- held by active carts/checkouts
  version         INT NOT NULL DEFAULT 0, -- optimistic lock counter
  updated_at      TIMESTAMP NOT NULL,
  UNIQUE (shop_id, sku, location_id),
  CHECK (quantity_on_hand >= quantity_reserved),
  CHECK (quantity_on_hand >= 0)
);

-- Individual reservations with TTL for self-healing.
reservations (
  id              BIGINT PRIMARY KEY,
  inventory_item_id BIGINT NOT NULL REFERENCES inventory_items(id),
  cart_id         VARCHAR(255) NOT NULL,
  quantity        INT NOT NULL,
  status          VARCHAR(20) NOT NULL,   -- 'active', 'confirmed', 'released', 'expired'
  expires_at      TIMESTAMP NOT NULL,     -- TTL for abandoned cart recovery
  created_at      TIMESTAMP NOT NULL,
  version         INT NOT NULL DEFAULT 0
);

-- Append-only audit trail.
inventory_events (
  id              BIGINT PRIMARY KEY,
  shop_id         BIGINT NOT NULL,
  inventory_item_id BIGINT NOT NULL,
  event_type      VARCHAR(50) NOT NULL,   -- 'reserved', 'confirmed', 'released', 'adjusted', 'received'
  quantity_delta   INT NOT NULL,
  actor_id        VARCHAR(255),           -- user, system, or channel
  metadata        JSONB,
  created_at      TIMESTAMP NOT NULL
);
```

### Key Design Decisions in the Schema

**`quantity_on_hand` vs `quantity_reserved` as separate columns:** Available stock = `quantity_on_hand - quantity_reserved`. Keeping them separate avoids the need to scan the reservations table to compute available stock. The CHECK constraint `quantity_on_hand >= quantity_reserved` is the database-level oversell guard.

**`version` column:** Enables optimistic concurrency control. Every write increments the version and includes `WHERE version = :expected_version` in the UPDATE. If the version changed between read and write, the transaction retries.

**`expires_at` on reservations:** This is the self-healing mechanism. Abandoned carts do not require explicit cleanup -- a background reaper or lazy expiration reclaims reserved stock when the TTL passes.

---

## Step 4: Reservation Flow -- The Core Write Path

The reservation lifecycle has three phases: reserve, confirm, release/expire. This is the most latency-sensitive and consistency-critical path in the system.

### Reserve (Add-to-Cart or Checkout Start)

```
Client: POST /inventory/reserve {sku, location_id, qty}
  1. Read inventory_item row (quantity_on_hand, quantity_reserved, version)
  2. Check: (quantity_on_hand - quantity_reserved) >= requested_qty
  3. UPDATE inventory_items
     SET quantity_reserved = quantity_reserved + :qty,
         version = version + 1
     WHERE id = :id AND version = :current_version
  4. If UPDATE affected 0 rows -> version conflict, retry from step 1
  5. INSERT reservation row with expires_at = now() + TTL
  6. Publish 'inventory.reserved' event to Kafka
  7. Return reservation_id to client
```

### Confirm (Checkout Complete / Payment Captured)

```
Client: POST /inventory/confirm {reservation_id}
  1. Load reservation (must be status = 'active', not expired)
  2. BEGIN TRANSACTION
     UPDATE reservations SET status = 'confirmed'
     UPDATE inventory_items
       SET quantity_on_hand = quantity_on_hand - :qty,
           quantity_reserved = quantity_reserved - :qty,
           version = version + 1
       WHERE id = :id
  3. COMMIT
  4. Publish 'inventory.decremented' event
```

### Release (Cart Cleared or TTL Expired)

```
Reaper job or explicit release: POST /inventory/release {reservation_id}
  1. Load reservation (must be status = 'active')
  2. BEGIN TRANSACTION
     UPDATE reservations SET status = 'released' (or 'expired')
     UPDATE inventory_items
       SET quantity_reserved = quantity_reserved - :qty,
           version = version + 1
       WHERE id = :id
  3. COMMIT
  4. Publish 'inventory.released' event
```

### TTL Self-Healing

A background reaper process runs on a schedule (every 30-60 seconds) and queries:

```sql
SELECT id FROM reservations
WHERE status = 'active' AND expires_at < now()
LIMIT 1000;
```

For each expired reservation, it executes the release flow. This ensures abandoned carts do not permanently lock stock.

**TTL trade-off:** Too short (2 minutes) and legitimate slow checkouts lose their reservation. Too long (30 minutes) and stock is locked while carts rot. Shopify uses ~10 minutes as a default, configurable per merchant. During flash sales, a shorter TTL (5 minutes) frees stock faster.

---

## Step 5: Concurrency Control -- Optimistic vs Pessimistic

This is the central architectural decision. The answer is not one or the other -- it is both, selected dynamically based on contention level.

### Optimistic Locking (Low-Contention SKUs -- 99% of Traffic)

Most SKUs have plenty of stock relative to demand. Concurrent writes are rare.

```sql
UPDATE inventory_items
SET quantity_reserved = quantity_reserved + 1,
    version = version + 1
WHERE id = :id
  AND version = :expected_version
  AND (quantity_on_hand - quantity_reserved) >= 1;
```

If the version has changed, retry. With low contention, retries are rare (< 1%). This avoids holding row-level locks and gives high throughput.

### Pessimistic Locking (High-Contention SKUs -- Limited Drops, BFCM)

When a SKU has single-digit stock and thousands of concurrent buyers, optimistic locking falls apart. Every concurrent reader gets the same version, and all but one will fail and retry -- creating a retry storm.

```sql
BEGIN;
SELECT * FROM inventory_items
WHERE id = :id
FOR UPDATE;  -- exclusive row lock, all other transactions block here

-- Check available stock
-- If available, update quantity_reserved
UPDATE inventory_items
SET quantity_reserved = quantity_reserved + 1,
    version = version + 1
WHERE id = :id
  AND (quantity_on_hand - quantity_reserved) >= 1;

COMMIT;  -- lock released
```

Transactions serialize through the lock. Latency per transaction increases (lock wait time), but there are zero wasted retries.

### Switching Between Modes

How does the system know which mode to use? Two approaches:

1. **Merchant flag:** Merchants mark products as "limited drop" when creating them. The system uses pessimistic locking for those SKUs.
2. **Adaptive switching:** Monitor retry rate per SKU. If retries exceed a threshold (e.g., > 20% of attempts), switch to pessimistic locking. This handles the case where a merchant does not know their product will go viral.

In practice, Shopify uses a combination: merchants can opt in, and the platform detects contention spikes.

### Why Not Just Always Use Pessimistic Locking?

Lock contention serializes all writes. For a SKU with 10,000 units and 50 concurrent buyers, there is no meaningful contention -- optimistic locking gives 10x better throughput because transactions do not block each other. Pessimistic locking adds unnecessary latency in the common case.

---

## Step 6: Multi-Warehouse Stock and Fulfillment Routing

Stock is distributed across multiple warehouses. When a customer places an order, the system must decide which warehouse(s) to fulfill from.

### Aggregated Available Stock

The storefront displays a single "available" count per SKU, aggregated across all locations:

```sql
SELECT sku,
       SUM(quantity_on_hand - quantity_reserved) AS available
FROM inventory_items
WHERE shop_id = :shop_id AND sku = :sku
GROUP BY sku;
```

This query hits the read path (cache or read replica), not the write path.

### Reservation Routing

When reserving stock, the system must pick a specific warehouse. The routing decision considers:

1. **Proximity to customer** -- minimize shipping cost and delivery time
2. **Stock availability** -- prefer warehouses with more stock (avoid fragmenting last units)
3. **Warehouse capacity** -- avoid overloading a single fulfillment center

```
Fulfillment Routing Logic:
  1. Fetch all locations with available stock for this SKU
  2. Score each location:
     score = w1 * proximity_score
           + w2 * stock_depth_score
           + w3 * capacity_score
  3. Reserve from the highest-scoring location
  4. If reservation fails (concurrent depletion), try next location
```

### Split Shipments

When no single warehouse has enough stock, the order can be split:
- Reserve 2 units from Warehouse A, 1 unit from Warehouse B
- Each reservation is independent with its own TTL
- The order service aggregates the reservations

**Trade-off:** Split shipments increase shipping cost but prevent artificial out-of-stock when total network inventory is sufficient.

---

## Step 7: Cross-Channel Sync

Inventory must stay consistent across online store, POS terminals, Amazon, eBay, and other marketplace integrations. This is an eventually consistent system by necessity.

### Event-Driven Architecture

Every inventory mutation publishes an event to Kafka:

```
Topic: inventory.changes
Key: {shop_id}:{sku}  (ensures ordering per SKU per merchant)

Event payload:
{
  "shop_id": 12345,
  "sku": "SHOE-RED-42",
  "location_id": 67,
  "event_type": "reserved",
  "quantity_delta": -1,
  "available_after": 23,
  "timestamp": "2026-04-17T10:30:00Z"
}
```

### Channel Sync Service

```
Kafka Consumer Group (per channel)
  |
  +-- Online Store Sync  --> Update storefront cache (Redis)
  |
  +-- POS Sync           --> Push to POS devices (WebSocket or polling)
  |
  +-- Amazon Sync        --> Amazon Inventory API (rate-limited, batched)
  |
  +-- eBay Sync          --> eBay Inventory API (rate-limited, batched)
  |
  +-- Alert Service      --> Low-stock / OOS notifications to merchants
```

### Marketplace Sync Challenges

External marketplaces have their own latency characteristics:
- **Amazon:** Inventory feed processing can take 15-30 minutes. You cannot guarantee real-time sync. Buffer stock (withhold a percentage) to prevent oversells during the sync gap.
- **POS offline:** A POS terminal may sell the last unit while offline. On reconnect, it pushes a sale that conflicts with an online sale. Resolution: accept the oversell and flag it for the merchant (this is a business policy decision, not a technical one).

### Conflict Resolution for Cross-Channel

When two channels sell the last unit concurrently:
1. The write to the inventory store is the arbiter (strong consistency).
2. The first write wins. The second gets a "stock unavailable" error.
3. If the second channel already committed (POS offline case), the system records a negative adjustment and alerts the merchant.

**Key insight:** You cannot prevent all oversells when channels have autonomous operation (offline POS). The system minimizes them and provides tools for merchants to resolve conflicts.

---

## Step 8: Read Path -- Stock Display and Caching

The read path serves stock levels to storefronts. It prioritizes speed and availability over perfect accuracy.

### Caching Strategy

```
Request: GET /inventory/available?sku=SHOE-RED-42

  1. Check Redis cache (key: shop:{id}:sku:{sku}:available)
  2. If HIT and TTL not expired -> return cached value
  3. If MISS -> query read replica of PostgreSQL
  4. Write result to Redis with short TTL (5-10 seconds)
  5. Return to client
```

### Why Eventual Consistency Is Acceptable for Reads

The storefront showing "23 in stock" when the true count is 22 is harmless. The reservation path (write) enforces the real constraint. The worst case: a customer adds to cart, attempts to reserve, and gets "out of stock" -- a minor UX friction, not a correctness violation.

### Cache Invalidation

Two strategies working together:
1. **TTL-based:** Short TTLs (5-10 seconds) bound staleness. Simple, no coordination needed.
2. **Event-driven:** Kafka consumer updates Redis on every inventory event. Reduces average staleness to sub-second.

For most SKUs, TTL-based is sufficient. For high-contention SKUs during flash sales, event-driven invalidation prevents the storefront from showing stale "in stock" after sellout.

### Stock Display Optimization

For storefronts, avoid showing exact counts for most products. Display:
- "In Stock" (available > threshold)
- "Low Stock" (available <= threshold)
- "Out of Stock" (available == 0)

This reduces the impact of stale reads and avoids customer anxiety about exact counts.

---

## Step 9: Multi-Tenant Architecture and BFCM Scaling

Shopify serves millions of merchants on shared infrastructure. Tenant isolation and burst capacity are existential requirements.

### Pod-Based Architecture

Shopify uses a pod-based multi-tenant architecture:
- Each pod is a self-contained unit: its own database, cache, and application servers
- Merchants are assigned to pods based on size and activity
- Large merchants (e.g., Kylie Cosmetics during a drop) get dedicated pods
- Small merchants share pods

```
Pod 1 (Shared)         Pod 2 (Shared)         Pod 3 (Dedicated)
+----------------+     +----------------+     +------------------+
| Merchants A-M  |     | Merchants N-Z  |     | Mega-Merchant X  |
| Shared PG      |     | Shared PG      |     | Dedicated PG     |
| Shared Redis   |     | Shared Redis   |     | Dedicated Redis  |
+----------------+     +----------------+     +------------------+
```

### BFCM Scaling Strategy

Black Friday/Cyber Monday generates 3-10x normal traffic. The system prepares:

1. **Pre-scaled infrastructure:** Pods are scaled up days before. Database read replicas added. Redis clusters expanded.
2. **Connection pooling:** PgBouncer in front of PostgreSQL to handle connection spikes without exhausting database connections.
3. **Queue-based backpressure:** If reservation throughput exceeds database capacity, requests queue with a bounded wait time. Better to have customers wait 2 seconds than to drop requests.
4. **Shedding non-critical work:** During peak, disable or throttle non-critical background jobs (analytics, marketplace sync batches) to free database capacity for the reservation path.

### Noisy Neighbor Prevention

A single merchant's flash sale should not degrade other merchants on the same pod:
- Per-merchant rate limits on the reservation API
- Database query timeouts to prevent long-running queries from blocking the connection pool
- Circuit breakers: if a merchant's error rate spikes, shed their traffic to protect the pod

---

## Step 10: Failure Modes and Operational Resilience

### Failure: Database Goes Down

The inventory store is a single point of failure for the write path. Mitigation:
- **Primary-replica failover:** Automated failover (e.g., Patroni for PostgreSQL) with sub-30-second recovery.
- **During failover:** Reservation requests fail. The API returns 503. Clients retry with exponential backoff. No data loss because the replica has all committed transactions.
- **What about accepting writes during failover?** Do not. Accepting writes to a secondary store and reconciling later risks oversells. The correct behavior is to fail closed: deny reservations during the outage. A few seconds of unavailability is better than overselling.

### Failure: Reservation Service Crashes Mid-Transaction

If the service crashes after updating the database but before publishing to Kafka:
- The database state is correct (transaction committed).
- The Kafka event is missing.
- Solution: **Transactional outbox pattern.** Write the event to an `outbox` table in the same database transaction. A separate process tails the outbox and publishes to Kafka. This guarantees at-least-once delivery.

```sql
BEGIN;
  UPDATE inventory_items SET ...;
  INSERT INTO reservations ...;
  INSERT INTO outbox (topic, key, payload) VALUES (...);  -- same transaction
COMMIT;
```

### Failure: Reaper Crashes (Expired Reservations Not Released)

If the TTL reaper stops running, reservations accumulate and stock appears locked. Mitigation:
- Run the reaper as a replicated service with leader election. If the leader dies, another instance takes over.
- **Lazy expiration fallback:** On every reservation attempt, check if any expired reservations exist for this SKU and release them inline. This adds latency but prevents indefinite stock lockup even if the reaper is completely down.

### Failure: Kafka Consumer Lag (Channel Sync Delayed)

If the channel sync consumer falls behind:
- Marketplace listings show stale stock (risk of oversell on external channels).
- Mitigation: Monitor consumer lag. If lag exceeds a threshold, reduce buffer stock on external channels to create a safety margin.

### Monitoring and Alerting

Critical metrics to track:
- **Reservation success rate** -- drop indicates stock depletion or system failure
- **Optimistic lock retry rate** -- spike indicates unexpected contention, may need to switch to pessimistic locking
- **Reaper backlog** -- growing expired-but-not-released reservation count
- **Kafka consumer lag** -- growing lag means channel sync is falling behind
- **Available stock accuracy** -- periodic reconciliation between cache and source of truth

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Concurrency control | Optimistic + pessimistic (adaptive) | Always pessimistic | Optimistic gives better throughput for 99% of SKUs; pessimistic prevents retry storms for limited drops |
| Reservation model | Explicit reserve with TTL | Decrement on purchase only | TTL self-heals abandoned carts; prevents phantom stock locks |
| Write consistency | Strong (single-leader PostgreSQL) | Distributed consensus (Raft) | PostgreSQL ACID is battle-tested; Raft adds complexity without clear benefit at this scale |
| Read consistency | Eventual (cache + read replicas) | Strong (read from primary) | Storefront reads do not need exactness; reservation path enforces truth |
| Cross-channel sync | Event-driven (Kafka) | Polling / direct writes | Decouples channels; handles backpressure; survives channel outages |
| Multi-tenancy | Pod-based isolation | Shared-everything | Pod isolation prevents noisy neighbors; large merchants get dedicated resources |
| Oversell on external channels | Buffer stock (withhold %) | Real-time sync | Marketplace APIs are too slow for real-time; buffer stock is the pragmatic guard |
| Database for inventory | PostgreSQL | Redis (atomic counters) | Need ACID transactions for multi-row updates (inventory + reservation); Redis lacks this |

---

## Common Mistakes to Avoid

1. **Using Redis DECR as the primary inventory store.** Atomic decrements in Redis are fast but lack ACID transactions. When you need to atomically update both the inventory count and create a reservation record, Redis cannot do this in a single transaction. Use Redis for the read cache, PostgreSQL for the write path.

2. **Single locking strategy for all SKUs.** Optimistic locking alone causes retry storms under high contention. Pessimistic locking alone wastes throughput for low-contention SKUs. The system needs both, with a mechanism to switch between them.

3. **No TTL on reservations.** Without TTLs, abandoned carts permanently lock stock. This is a slow-motion outage -- merchants see "0 available" while stock sits in zombie carts. Self-healing via TTL expiration is non-negotiable.

4. **Treating cross-channel sync as strongly consistent.** External marketplaces have inherent latency. Designing for real-time sync with Amazon is a fiction. Accept eventual consistency and use buffer stock to mitigate oversell risk during the sync gap.

5. **Ignoring the hot-SKU problem.** Designing for average concurrency and ignoring limited drops. The system must handle the case where 10,000 buyers hit a single row simultaneously. This is the scenario that breaks naive designs.

6. **Aggregating stock in real-time from the write path.** Summing across warehouses on every storefront page load hammers the primary database. Pre-compute aggregated stock in the cache layer, updated by events.

7. **No backpressure during traffic spikes.** Without queue-based backpressure or rate limiting, a BFCM spike can exhaust database connections and cascade-fail the entire pod. Controlled degradation (queuing, shedding) is better than uncontrolled failure.

8. **Skipping the transactional outbox.** Publishing to Kafka after the database commit creates a window where the event can be lost (crash between commit and publish). The outbox pattern closes this gap with at-least-once delivery.

---

## Related Topics

- [[../../../03-scaling-writes/index|Scaling Writes]] -- optimistic vs pessimistic locking, high-contention write patterns
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- PostgreSQL consistency, ACID guarantees, transactional outbox
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- eventual consistency, event-driven architecture, conflict resolution
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- TTL-based self-healing, circuit breakers, failover strategies
- [[../../../07-real-time-systems/index|Real-Time Systems]] -- event streaming, Kafka consumer patterns
- [[../../../05-async-processing/index|Async Processing]] -- background reapers, outbox pattern, marketplace sync jobs
