# Walkthrough: Design a Flash Sale / BFCM Traffic Handling System (Shopify)

## Step 1: Clarify Requirements and Scope

Before drawing anything, confirm the scope with the interviewer:
- How large are the traffic spikes? (100x normal within minutes -- BFCM 2024 peaked at 284M req/min at edge)
- Is this a single-tenant or multi-tenant platform? (Multi-tenant -- millions of merchants, some running flash sales simultaneously)
- Do we need to handle both planned and unplanned spikes? (Yes -- BFCM is planned months ahead; a celebrity Instagram post is not)
- What is the oversell tolerance? (Zero -- limited-inventory items must never oversell)
- What is the checkout availability target? (99.9% during peak events)

This scoping matters because "handle 100x traffic" on a multi-tenant platform is fundamentally different from scaling a single-merchant store. The challenge is protecting shared infrastructure while giving each merchant fair access to resources.

**Out of scope** (confirm with interviewer): CDN/edge caching strategy (assume it exists), bot detection, fraud detection, post-purchase fulfillment.

---

## Step 2: High-Level Architecture

```
                         Internet
                            |
                    +-------v--------+
                    |   CDN / Edge   |  (Cloudflare / Fastly -- 284M req/min absorbed here)
                    +-------+--------+
                            |
                    +-------v--------+
                    |  Sorting Hat   |  (OpenResty/Lua -- request routing + load shedding)
                    +-------+--------+
                            |
              +-------------+---------------+
              |                             |
     +--------v---------+        +---------v-----------+
     | Storefront Pods  |        |  Checkout Pods      |
     | (read-heavy,     |        |  (write-heavy,      |
     |  extracted from   |        |   highest priority)  |
     |  monolith)        |        +----------+----------+
     +------------------+                    |
                                   +---------v-----------+
                                   |  Queue-Based        |
                                   |  Admission Control  |
                                   +----------+----------+
                                              |
                               +--------------+--------------+
                               |                             |
                      +--------v--------+          +--------v--------+
                      | Inventory       |          | Payment         |
                      | Service         |          | Service         |
                      | (reservation    |          |                 |
                      |  with TTL)      |          |                 |
                      +--------+--------+          +-----------------+
                               |
                      +--------v--------+
                      | Pod Datastores  |  (MySQL shards, Redis, per-pod isolation)
                      +-----------------+
```

### Core Components

1. **CDN / Edge Layer** -- absorbs the majority of read traffic. Static assets, cached storefront pages, and edge-computed responses never hit origin servers.
2. **Sorting Hat** -- Shopify's OpenResty/Lua routing layer. Determines which pod handles a request, enforces load shedding policies, and routes around unhealthy pods.
3. **Storefront Pods** -- extracted read path for product pages, collections, and search. Separated from the monolith to scale reads independently (4-6x faster, 500ms TTFB reduction).
4. **Checkout Pods** -- write-heavy path for cart, inventory reservation, and payment. Protected by admission control during traffic spikes.
5. **Queue-Based Admission Control** -- virtual waiting room that throttles checkout throughput to a rate the backend can sustain.
6. **Inventory Service** -- manages per-SKU reservation with TTL. The single source of truth for available inventory during a flash sale.
7. **Pod Datastores** -- isolated MySQL shards and Redis clusters per pod. A failing pod does not impact other pods' databases.

---

## Step 3: Pod-Based Architecture and Tenant Isolation

This is the foundation that makes everything else work. Shopify's pod architecture is a bulkhead pattern applied to the entire platform.

### What Is a Pod?

A pod is an isolated group of shops sharing a dedicated set of datastores (MySQL primary + replicas, Redis, Memcached). Each pod holds thousands of shops. Critical infrastructure (load balancers, app servers, job workers) is per-pod.

```
Pod 1                          Pod 2
+------------------------+     +------------------------+
| Shops: A, B, C, ...   |     | Shops: X, Y, Z, ...   |
| MySQL Primary          |     | MySQL Primary          |
| MySQL Replicas (3)     |     | MySQL Replicas (3)     |
| Redis Cluster          |     | Redis Cluster          |
| Memcached              |     | Memcached              |
| Job Workers            |     | Job Workers            |
+------------------------+     +------------------------+
```

### Why Pods Matter for Flash Sales

1. **Blast radius containment.** If Kylie Jenner launches a product on Shop A (pod 1), the resulting traffic spike is isolated to pod 1. Shops on pod 2 are completely unaffected.
2. **Independent scaling.** A pod hosting a known flash sale can be pre-scaled (more replicas, bigger instances) without scaling the entire platform.
3. **Independent failure.** A pod datastore failure only affects shops on that pod, not the entire platform.

### Sorting Hat: The Routing Brain

The Sorting Hat is an OpenResty/Lua layer sitting in front of all pods. For every request, it:
1. Looks up the shop domain -> pod mapping (cached in memory, sourced from a central registry)
2. Routes the request to the correct pod
3. Applies per-pod and per-shop load shedding policies
4. Returns a 503 with a retry-after header if the pod is overloaded

```
Request: GET fancy-cosmetics.myshopify.com/products/limited-edition
  -> Sorting Hat lookup: fancy-cosmetics -> Pod 7
  -> Check: is Pod 7 healthy and under capacity?
    -> Yes: forward to Pod 7 app servers
    -> No: return 503 or route to static fallback
```

**Key insight:** The Sorting Hat makes load shedding decisions at the edge of the platform, before requests consume backend resources. This is far more efficient than letting requests reach the application layer and failing there.

---

## Step 4: Storefront Extraction (Scaling Reads)

During BFCM 2024, Shopify served 57.3 PB of data. The vast majority of requests are reads: product pages, collection pages, search results. Storefront extraction is the single biggest lever for handling flash sale traffic.

### The Problem with the Monolith

Shopify's Rails monolith historically served both reads (product pages) and writes (checkout, admin). During a flash sale:
- 95%+ of traffic is browsing (reads)
- 5% is buying (writes)
- Browsing traffic competes with checkout for the same application servers, database connections, and memory

### Extracted Storefront

The storefront rendering path was extracted into a separate service optimized purely for reads:

```
Before extraction:
  Browser -> Rails Monolith -> MySQL Primary (reads + writes)
  TTFB: ~800ms during peak

After extraction:
  Browser -> Storefront Service -> MySQL Replicas + Cache
  TTFB: ~300ms during peak (500ms reduction)

  Browser -> Monolith (checkout only) -> MySQL Primary
```

### How It Scales

1. **Read replicas** -- storefront reads hit MySQL replicas, not the primary. Adding replicas scales reads linearly.
2. **Aggressive caching** -- Liquid templates, product data, and collection pages are cached in Memcached and at the CDN edge. Cache hit rates during BFCM exceed 90%.
3. **Independent scaling** -- storefront pods can auto-scale separately from the monolith. During BFCM, storefront capacity is 10-20x normal.
4. **Static fallback** -- if the storefront service is overwhelmed, the CDN serves stale cached pages. Buyers see a slightly outdated page instead of an error.

**Trade-off:** Eventual consistency. A product that sells out might still appear "in stock" on the storefront for a few seconds until the cache invalidates. This is acceptable because the checkout path validates inventory before completing the purchase.

---

## Step 5: Load Shedding and Graceful Degradation

Load shedding is the most critical runtime mechanism during a flash sale. The system must decide which requests to serve and which to drop, and it must make these decisions in microseconds.

### Degradation Tiers

Not all requests are equally important. Shopify uses a priority-based shedding strategy:

```
Priority (highest to lowest):     Shed order (first to last):

1. Checkout completion             5. Static assets (CDN handles)
2. Cart operations                 4. Product page dynamic features
3. Product page (core)                (reviews, recommendations)
4. Product page (enrichments)      3. Product page (core)
5. Static assets / marketing       2. Cart operations
                                   1. Checkout completion (LAST to shed)
```

**Tier 1 -- Degrade non-critical features:** Disable product reviews, recommendations, and analytics tracking. The storefront serves a simplified page with product info + add-to-cart button.

**Tier 2 -- Serve stale cache:** Storefront returns cached pages even if the cache TTL has expired. Product availability might be slightly stale, but the page loads.

**Tier 3 -- Static HTML fallback:** If the storefront service is completely overwhelmed, serve a pre-rendered static HTML page from the CDN. No dynamic content, but the page still works.

**Tier 4 -- Queue-based admission control:** Too many users trying to check out simultaneously. Route excess checkout requests to a virtual waiting room (more in Step 6).

**Tier 5 -- Shed browsing traffic:** If backend capacity is critical, return 503 to browsing requests to protect checkout. This is the last resort.

### Implementation: Sorting Hat Load Shedding

The Sorting Hat tracks per-pod request rates and response latencies in real time. When a pod crosses a threshold:

```
Pod 7 metrics:
  p99 latency: 2.1s (threshold: 1.5s)
  active connections: 4800 (threshold: 5000)
  error rate: 3.2% (threshold: 5%)

Decision: Tier 1 shedding activated
  -> Strip enrichment requests (reviews, recs)
  -> Allow core storefront + checkout through
```

The thresholds are configured per pod and tuned during load testing (Genghis). They are not static -- Shopify adjusts them before each BFCM based on load test results.

### Circuit Breakers with Semian

Shopify uses Semian (their open-source circuit breaker library) to protect internal service calls. Every outbound call from the monolith or storefront goes through a Semian-protected client:

```
Storefront -> [Semian circuit breaker] -> Recommendation Service
                                            |
                                            v
                                    Circuit OPEN: return []
                                    Circuit CLOSED: call service
```

If the recommendation service starts timing out, Semian trips the circuit and the storefront immediately returns an empty recommendations section. No cascading timeout, no thread pool exhaustion.

---

## Step 6: Queue-Based Admission Control (Virtual Waiting Room)

During a flash sale with limited inventory, thousands of users hit "checkout" within seconds. Without admission control, the backend is overwhelmed and everyone gets errors. A virtual waiting room converts a thundering herd into a controlled stream.

### Architecture

```
User clicks "Checkout"
       |
+------v-------+
| Admission    |    "You're #3,847 in line"
| Controller   |    (WebSocket for position updates)
| (edge layer) |
+------+-------+
       |
       | Token issued when it's your turn
       v
+------+-------+
| Checkout     |    Processes at sustainable rate
| Service      |    (e.g., 5000 checkouts/min per pod)
+--------------+
```

### How It Works

1. **Enqueue:** When checkout rate exceeds the sustainable threshold, new checkout attempts are placed in a FIFO queue. The user sees a waiting room page.
2. **Drain:** The queue drains at a fixed rate matching backend capacity. When a user reaches the front, they receive a short-lived token (JWT, 5-minute TTL).
3. **Checkout:** The user presents the token to the checkout service. The token is validated and consumed (one-time use). The user completes checkout normally.
4. **Fairness:** Strict FIFO ordering ensures first-come-first-served. No retries or refreshes can improve your position.

### Key Design Decisions

**Where does the queue live?** Redis sorted set keyed by enqueue timestamp. Fast O(log N) insertion and O(1) dequeue from the head. Replicated for durability.

**How to communicate position?** WebSocket connection from the waiting room page. Server pushes position updates every few seconds. This avoids clients polling and adding more load.

**What if the user closes the tab?** Their position is held for a grace period (30 seconds). If they reconnect, they resume their position. After the grace period, they lose their spot and the slot is released to the next person.

**Token security:** The checkout token is a signed JWT containing (user_session_id, shop_id, issued_at, expires_at). The checkout service validates the signature and expiry. Tokens cannot be forged or reused.

---

## Step 7: Inventory Reservation with TTL

The most critical correctness requirement: zero overselling. With thousands of concurrent buyers, inventory management must be both fast and strongly consistent.

### Reservation Flow

```
1. User adds to cart      -> No reservation (soft hold only, informational)
2. User enters checkout   -> Reserve inventory (hard hold, TTL = 10 min)
3. User completes payment -> Commit reservation (decrement available)
4. User abandons checkout -> TTL expires, reservation released
5. Payment fails          -> Explicit release of reservation
```

### Data Model

```
Inventory per SKU (Redis + MySQL):
  sku_id: "PROD-12345-SIZE-M"
  total_quantity: 100
  committed: 72           # sold and paid for
  reserved: 15            # in active checkouts (TTL-based)
  available: 13           # total - committed - reserved

Reservation record:
  reservation_id: UUID
  sku_id: "PROD-12345-SIZE-M"
  session_id: "sess-abc"
  quantity: 1
  created_at: 2024-11-29T14:32:00Z
  expires_at: 2024-11-29T14:42:00Z   # 10 min TTL
  status: "active"                     # active | committed | expired | released
```

### Why TTL Matters

Without TTL, a buyer who adds items to cart and walks away permanently reduces available inventory. During a flash sale with 100 units, if 60 users enter checkout and 40 abandon, those 40 units are locked forever. TTL ensures abandoned reservations automatically release.

### Atomic Reservation with Redis

The reservation check-and-decrement must be atomic. A Lua script in Redis ensures no race condition:

```lua
-- KEYS[1] = inventory key for the SKU
-- ARGV[1] = requested quantity
-- ARGV[2] = reservation ID
-- ARGV[3] = TTL in seconds

local available = tonumber(redis.call('HGET', KEYS[1], 'available'))
local requested = tonumber(ARGV[1])

if available >= requested then
  redis.call('HINCRBY', KEYS[1], 'available', -requested)
  redis.call('HINCRBY', KEYS[1], 'reserved', requested)
  redis.call('SETEX', 'reservation:' .. ARGV[2], ARGV[3], requested)
  return 1  -- success
else
  return 0  -- insufficient inventory
end
```

### Consistency Between Redis and MySQL

Redis is the fast path for reservation checks. MySQL is the durable source of truth. The reconciliation strategy:

1. **Write path:** Reservation created in Redis (fast) and enqueued to MySQL via async write (durable).
2. **Commit path:** Payment succeeds -> update both Redis and MySQL atomically (Redis for speed, MySQL for durability).
3. **Recovery:** If Redis fails, rebuild inventory state from MySQL. This takes seconds and is part of the pod failover procedure.
4. **Periodic reconciliation:** A background job compares Redis inventory counts against MySQL every 30 seconds and alerts on drift.

**Trade-off:** This is dual-write, which risks inconsistency. The TTL mechanism provides self-healing -- even if a reservation is stuck in Redis but missing from MySQL (or vice versa), it expires and the system converges. For the commit path (actual sale), MySQL is the source of truth and Redis is updated only after MySQL confirms.

---

## Step 8: Pre-Warming and Genghis Load Testing

Planned events like BFCM are Shopify's superpower over unplanned viral spikes. Months of preparation go into infrastructure readiness.

### Pre-Warming Strategy

Weeks before BFCM:
1. **Capacity planning** -- analyze prior year traffic + merchant growth projections. Allocate pod capacity per merchant tier.
2. **Infrastructure scaling** -- spin up additional MySQL replicas, Redis shards, and app servers per pod. Pre-warm connection pools.
3. **Cache warming** -- pre-populate CDN caches and Memcached with product pages for known high-traffic shops. A cold cache during a traffic spike is catastrophic.
4. **DNS and load balancer pre-scaling** -- ensure DNS TTLs are low enough for failover, and load balancers are pre-configured for peak capacity.

Hours before BFCM:
5. **Feature flag configuration** -- pre-set degradation tiers. Non-critical features may be proactively disabled to increase headroom.
6. **On-call staffing** -- war room with engineers from every team. Runbooks reviewed and updated.

### Genghis Load Testing

Genghis is Shopify's internal load testing tool. It replays production traffic patterns at scaled-up volumes against staging pods.

```
Genghis test plan for BFCM:
  Phase 1: Ramp from 1x to 10x traffic over 30 minutes
  Phase 2: Hold 10x for 2 hours (sustained peak)
  Phase 3: Spike to 50x for 5 minutes (flash sale burst)
  Phase 4: Ramp to 100x for 1 minute (worst case)
  Phase 5: Ramp down to 1x over 15 minutes

Metrics captured:
  - p50/p99 latency per request type
  - Error rate by pod
  - Database query volume and replication lag
  - Cache hit rates
  - Load shedding activation points
  - Inventory reservation throughput
```

Key findings from load tests feed directly into configuration changes: adjusting shedding thresholds, resizing connection pools, adding replicas where bottlenecks appear.

### Toxiproxy and Game Days

Toxiproxy simulates failure conditions (latency injection, connection drops, bandwidth limits) during pre-BFCM game days. Engineers intentionally break parts of the system to verify graceful degradation:

- Kill a MySQL primary mid-flash-sale: does failover complete under load?
- Inject 500ms latency on the payment provider: does checkout still work?
- Drop 30% of packets between pods: do circuit breakers trip correctly?

**Production war story insight:** Game days routinely uncover issues that staging alone misses. A Semian circuit breaker threshold that works at 1x load may be too aggressive at 50x load, tripping on normal latency variance and shedding healthy traffic. These thresholds must be tuned under realistic conditions.

---

## Step 9: Real-Time Merchant Dashboard

Merchants need to see what is happening during their flash sale. A real-time dashboard showing sales velocity, inventory levels, and traffic is both a product feature and an operational tool.

### Architecture

```
Checkout events                        Dashboard clients
      |                                      ^
      v                                      |
+-----+------+     +----------+     +-------+--------+
| Event Bus  | --> | Stream   | --> | WebSocket      |
| (Kafka)    |     | Processor|     | Gateway        |
+------------+     | (Flink)  |     | (per-merchant) |
                   +----+-----+     +----------------+
                        |
                   +----v-----+
                   | Time-    |
                   | Series DB|
                   | (pre-    |
                   |  aggregated)|
                   +----------+
```

### Data Flow

1. Every checkout completion, cart addition, and page view emits an event to Kafka, partitioned by shop_id.
2. A stream processor (Flink or Kafka Streams) aggregates events into windowed metrics: sales per minute, units sold per SKU, revenue running total.
3. Pre-aggregated metrics are written to a time-series store (ClickHouse or Redis TimeSeries) for historical queries.
4. Dashboard clients connect via WebSocket. The gateway subscribes to the relevant Kafka topic partition for that merchant and pushes updates every 1-2 seconds.

### Scaling Consideration

During BFCM, millions of merchants may have dashboards open. The WebSocket gateway must scale independently. Since each merchant only needs data for their own shop, the fan-out is bounded -- one WebSocket per merchant, not per checkout event.

**Protection:** The dashboard is read-only and non-critical. If the stream processor lags, dashboards show slightly delayed data. This is acceptable and must never compete with checkout for resources. The dashboard runs on separate infrastructure from the transaction path.

---

## Step 10: Failure Modes and Operational Playbook

A Staff-level answer must address what happens when things go wrong, not just the happy path.

### Failure: Pod Datastore Overload

**Symptoms:** MySQL replication lag > 10s, connection pool exhaustion, p99 latency > 5s.
**Mitigation:** Sorting Hat activates load shedding for the affected pod. Read traffic falls back to stale cache. Write traffic (checkout) is queued. If the pod cannot recover, shops can be live-migrated to a healthier pod (though this is a heavyweight operation reserved for extreme cases).

### Failure: Redis Inventory Service Down

**Symptoms:** Reservation requests fail, checkout errors spike.
**Mitigation:** Fall back to MySQL-based reservation (slower but correct). The checkout path adds ~200ms latency but remains functional. Redis is rebuilt from MySQL state when it recovers.

### Failure: Unplanned Viral Spike

**Symptoms:** A single shop receives 1000x traffic with no pre-warming. The pod hosting it is overwhelmed.
**Mitigation:** Sorting Hat detects the spike within seconds and activates per-shop rate limiting. The shop enters a virtual waiting room. Other shops on the same pod are protected by the per-shop limit. If the spike is sustained, operations may move the shop to a dedicated pod.

### Failure: Payment Provider Degradation

**Symptoms:** Payment processing latency increases from 200ms to 5s, partial failures.
**Mitigation:** Semian circuit breaker on the payment client trips. Checkout displays "payment processing delayed" and holds the reservation. Users are given the option to retry. Reservation TTL is extended to prevent inventory release during the payment delay. If the provider is fully down, checkout queues payment attempts and processes them when the provider recovers (with the user's consent).

### Failure: Cascading Failure Across Pods

**Symptoms:** A shared dependency (e.g., a centralized service like shipping rates) fails, causing multiple pods to degrade.
**Mitigation:** This is why Shopify's architecture minimizes shared dependencies. For the few that remain: Semian circuit breakers per pod trip independently. Each pod degrades gracefully (e.g., showing "shipping calculated at checkout" instead of real-time rates). The failing service recovers without retry storms because circuits are open.

### The BFCM Operational Posture

During BFCM, Shopify operates in a heightened state:
- **Change freeze:** No deployments except critical hotfixes
- **War room:** Engineers from every team monitoring dashboards
- **Pre-positioned capacity:** Infrastructure scaled to 3x projected peak (headroom for unplanned spikes)
- **Runbooks:** Every failure scenario above has a documented, rehearsed response
- **Rollback plans:** Feature flags allow instant rollback of any change

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Tenant isolation | Pod-based (isolated datastores) | Shared DB with row-level isolation | Blast radius containment; one shop's spike cannot take down others |
| Read scaling | Extracted storefront service | Scale the monolith horizontally | 4-6x perf gain; reads and writes scale independently |
| Load shedding layer | Sorting Hat (OpenResty/Lua at edge) | Application-level middleware | Microsecond decisions; rejects before request consumes app resources |
| Inventory reservation | Redis (fast path) + MySQL (durable) | MySQL only | Checkout latency budget requires sub-ms reservation; MySQL alone is too slow at peak |
| Admission control | Queue-based virtual waiting room | Retry-based (client hammers until successful) | Controlled throughput; fair FIFO ordering; no retry storms |
| Circuit breakers | Semian (per-resource, per-pod) | Global circuit breaker | Pod-level isolation; one pod's circuit state does not affect others |
| Cache invalidation | TTL-based with stale-while-revalidate | Strict invalidation | Accept slight staleness in exchange for availability during spikes |
| Pre-event strategy | Genghis load testing + Toxiproxy chaos | Hope-based engineering | Data-driven capacity planning; failure modes verified before event |

---

## Common Mistakes to Avoid

1. **Designing for average load instead of peak load.** The system handles 284M req/min at peak. If you design for the steady-state average, the system collapses during the event it was built for. Pre-warming and elastic scaling must be first-class concerns.

2. **Treating all requests equally.** Browsing a product page and completing a payment are not equally important. Without priority-based shedding, a traffic spike kills checkout (the revenue-generating path) to serve page views.

3. **Using a single shared database.** A multi-tenant platform with millions of merchants on a single database is a guaranteed failure during a flash sale. Pod-based isolation is essential for blast radius containment.

4. **Optimistic inventory checks without reservation.** Checking inventory at add-to-cart but not reserving it at checkout leads to overselling. Two users both see "1 in stock," both click buy, and both succeed. Atomic reservation with TTL is the correct pattern.

5. **Ignoring abandoned cart inventory locks.** Reserving inventory without a TTL means abandoned carts permanently reduce available stock. During a flash sale, this can lock up the entire inventory within minutes even though no one is buying.

6. **Load shedding at the application layer only.** If the request already reached your Rails process, you have already consumed a thread, a database connection, and memory. Shedding at the edge (Sorting Hat / OpenResty) is orders of magnitude cheaper.

7. **Assuming the payment provider is reliable.** Payment providers degrade during high-traffic events too. Without circuit breakers and fallback strategies (hold reservation, retry later), a payment provider timeout cascades into inventory release and lost sales.

8. **Skipping load testing or testing only the happy path.** Genghis + Toxiproxy test both scale and failure simultaneously. A system that handles 100x traffic is useless if it collapses when a single MySQL replica lags. Game days catch these compound failures.

---

## Related Topics

- [[../../scaling-reads/index|Scaling Reads]] -- CDN caching, read replicas, storefront extraction
- [[../../scaling-writes/index|Scaling Writes]] -- queue-based writes, backpressure, inventory reservation
- [[../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- circuit breakers (Semian), load shedding, graceful degradation, chaos engineering
- [[../../async-processing/index|Async Processing]] -- queue-based admission control, event-driven dashboard
- [[../../distributed-systems-fundamentals/index|Distributed Systems]] -- consistency models, partition tolerance
- [[../../databases-and-storage/index|Databases & Storage]] -- pod-based MySQL sharding, Redis for fast-path operations
- [[../../api-gateway-and-service-mesh/index|API Gateway & Service Mesh]] -- Sorting Hat as intelligent routing layer
