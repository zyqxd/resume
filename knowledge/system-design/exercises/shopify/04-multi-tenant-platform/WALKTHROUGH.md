# Walkthrough: Design a Multi-Tenant E-Commerce Platform (Shopify)

## Step 1: Clarify Requirements and Scope

Before drawing anything, confirm the scope with the interviewer:
- How many tenants (shops)? (Millions -- this rules out database-per-tenant)
- What's the tenant size distribution? (Power law -- a few whales, long tail of small shops)
- Is zero-downtime migration a hard requirement? (Yes -- shops cannot go offline for rebalancing)
- Do enterprise merchants need dedicated infrastructure? (Yes -- this affects isolation strategy)
- Are we designing the storefront rendering layer? (No -- focus on the multi-tenancy platform itself)

This scoping is critical. "Multi-tenant e-commerce platform" can mean anything from a simple SaaS app to a full cloud platform. The interesting part here is the pod architecture, tenant routing, and live migration -- not the e-commerce domain logic.

---

## Step 2: High-Level Architecture

```
                    Internet
                       |
              +--------v--------+
              |   Edge / CDN    |  (custom domain TLS termination, static assets)
              +--------+--------+
                       |
              +--------v--------+
              |   Sorting Hat   |  (Lua/OpenResty -- shop-to-pod routing)
              +--------+--------+
                       |
       +---------------+---------------+
       |               |               |
  +----v----+     +----v----+     +----v----+
  |  Pod 1  |     |  Pod 2  |     |  Pod N  |
  |---------|     |---------|     |---------|
  | App     |     | App     |     | App     |
  | Servers |     | Servers |     | Servers |
  | (Rails) |     | (Rails) |     | (Rails) |
  |---------|     |---------|     |---------|
  | Redis / |     | Redis / |     | Redis / |
  | Memcache|     | Memcache|     | Memcache|
  |---------|     |---------|     |---------|
  | MySQL   |     | MySQL   |     | MySQL   |
  | Primary |     | Primary |     | Primary |
  | + Repli |     | + Repli |     | + Repli |
  +---------+     +---------+     +---------+
       |               |               |
       +-------+-------+-------+-------+
               |               |
      +--------v------+ +-----v----------+
      | Control Plane | | Monitoring &   |
      | (provisioning,| | Rebalancing    |
      | migration)    | | Service        |
      +---------------+ +----------------+
```

### Core Components

1. **Edge / CDN Layer** -- terminates TLS for custom domains, serves static assets, provides DDoS protection. Maps custom domains to shop identifiers.
2. **Sorting Hat** -- the routing brain. An OpenResty/Lua layer that maps every incoming request to the correct pod. Runs at the edge, before traffic hits any application server.
3. **Pods** -- self-contained infrastructure units. Each pod contains its own Rails app servers, MySQL primary + replicas, and Redis/Memcached. A pod hosts thousands of shops.
4. **Control Plane** -- manages shop provisioning, pod-to-shop mapping, and orchestrates migrations (Ghostferry).
5. **Monitoring & Rebalancing Service** -- watches per-pod and per-shop resource consumption, triggers shop migrations to maintain balance.

---

## Step 3: Pod Architecture -- The Unit of Scale

The pod is the central abstraction. Instead of sharding by table or by row, Shopify shards by pod. Each pod is a fully independent stack.

### What's Inside a Pod

```
Pod N
+-- App Servers (Rails, behind an internal load balancer)
|   +-- Packwerk-enforced module boundaries
|   +-- Shared monolith codebase, pod-scoped data access
+-- MySQL Primary
|   +-- All shops in this pod share this database
|   +-- Rows are tenant-scoped (shop_id foreign key everywhere)
|   +-- Row-level tenant isolation, NOT schema-level
+-- MySQL Read Replicas (2-3)
|   +-- Serve read-heavy traffic (storefront product listings, analytics)
+-- Redis
|   +-- Session storage
|   +-- Job queues (Sidekiq)
|   +-- Caching hot paths (shop configs, product catalogs)
+-- Memcached
    +-- Fragment caching, rate limit counters
```

### Why Database-per-Pod, Not Database-per-Tenant

With millions of shops, database-per-tenant would mean millions of MySQL instances. That is operationally insane -- connection management, schema migrations, backups, monitoring. Database-per-pod gives you O(100) databases to manage while still isolating failure domains.

The trade-off: shops within a pod share database resources. A noisy neighbor within a pod can still affect other shops on that pod. This is why per-tenant rate limiting and monitoring are essential (covered in Step 7).

### Why Not Pure Consistent Hashing

A naive consistent-hash approach (hash(shop_id) -> pod) sounds elegant but breaks down:
- You cannot control which shops land on which pod (enterprise merchants need dedicated pods)
- Rebalancing requires rehashing, which moves too many shops at once
- Shop sizes vary by orders of magnitude -- hashing gives you no way to bin-pack

Instead, use an explicit mapping table: a lookup from shop_id to pod_id, stored in a fast, globally replicated datastore. This gives full control over placement.

---

## Step 4: Sorting Hat -- Request Routing

Every HTTP request to any Shopify storefront or admin panel must be routed to the correct pod. This happens at the Sorting Hat layer, before any application logic runs.

### Routing Flow

```
1. Request arrives: GET https://cool-store.myshopify.com/products

2. Edge layer resolves custom domain -> shop identifier
   (DNS CNAME points to Shopify edge; edge maps Host header to shop_id)

3. Sorting Hat receives request with shop_id
   a. Check local Lua cache (shared_dict): shop_id -> pod_id
   b. Cache miss? Query the routing service (backed by a fast store -- Redis cluster or etcd)
   c. Forward request to the correct pod's load balancer

4. Pod's app server handles the request with full tenant context
```

### Routing Data Store

```
+-------------------+
| Routing Table     |
|-------------------|
| shop_id | pod_id  |
|---------|---------|
| 12345   | pod-17  |
| 12346   | pod-03  |
| 99999   | pod-52  |  (enterprise, dedicated)
+-------------------+

Replicated to:
  - Sorting Hat local Lua cache (per-worker shared_dict)
  - Redis cluster (source of truth for cache misses)
  - Control plane database (for management UI)
```

### Custom Domain Routing

Custom domains add a layer: `mybrand.com` needs to resolve to `shop_id=12345` before the pod routing can happen.

```
mybrand.com
  -> DNS CNAME -> edge.shopify.com
  -> Edge terminates TLS (wildcard cert or per-domain cert via Let's Encrypt)
  -> Edge looks up domain-to-shop mapping
  -> Sorting Hat looks up shop-to-pod mapping
  -> Forward to pod
```

The domain-to-shop mapping is a separate table, also cached aggressively at the edge. Certificate provisioning happens asynchronously when a merchant configures a custom domain.

### Performance Requirements

Sorting Hat adds latency to every request. It must be sub-millisecond for cache hits. The local Lua shared_dict (in-memory, per Nginx worker) provides this. Cache miss path (Redis lookup) should be under 5ms. With millions of shops, the cache hit rate is high because active shops are a small fraction of total shops (hot working set fits in memory).

---

## Step 5: Tenant Data Model and Isolation

### Schema Design

Every table in the database includes a `shop_id` column. There is no row in the database that does not belong to a shop.

```sql
-- Every table follows this pattern
CREATE TABLE orders (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  shop_id BIGINT NOT NULL,
  customer_id BIGINT NOT NULL,
  total_cents BIGINT NOT NULL,
  status ENUM('pending', 'paid', 'shipped', 'delivered'),
  created_at DATETIME NOT NULL,
  -- ...
  INDEX idx_shop_orders (shop_id, created_at),
  INDEX idx_shop_status (shop_id, status)
);

CREATE TABLE products (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  shop_id BIGINT NOT NULL,
  title VARCHAR(255) NOT NULL,
  -- ...
  INDEX idx_shop_products (shop_id)
);
```

### Enforcing Tenant Isolation in the Application

Every database query must be scoped to a `shop_id`. This is enforced at the framework level, not left to individual developers:

```ruby
# Rails concern applied to all models
module ShopScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :shop
    default_scope { where(shop_id: Current.shop.id) }
  end
end

# Middleware sets Current.shop on every request
class ShopContext
  def call(env)
    Current.shop = Shop.find_by!(identifier: env['X-Shop-Id'])
    @app.call(env)
  ensure
    Current.shop = nil
  end
end
```

**Packwerk** enforces module boundaries within the Rails monolith. Different domain modules (orders, products, inventory, shipping) cannot reach into each other's internals. This prevents cross-cutting queries that could bypass tenant scoping.

### Failure Mode: Missing shop_id Scope

This is the scariest bug in a multi-tenant system -- a query without tenant scoping returns another merchant's data. Defenses:
- Default scopes on all models (as shown above)
- Database-level row security policies as a safety net
- Automated tests that assert every query includes `shop_id` in its WHERE clause
- Query logging and anomaly detection for cross-tenant access patterns

---

## Step 6: Zero-Downtime Shop Migration (Ghostferry)

Shops need to move between pods. Reasons: pod is overloaded, merchant upgraded to enterprise tier, regional compliance, hardware decommission. Downtime during migration is unacceptable for a merchant generating revenue.

### Ghostferry: How It Works

Ghostferry is Shopify's open-source tool for zero-downtime MySQL-to-MySQL data migration. It moves a shop's data from a source pod's database to a target pod's database while the shop continues serving traffic.

```
Phase 1: Full Data Copy
+------------+                        +------------+
| Source Pod  |  --- bulk copy rows -> | Target Pod |
| (MySQL)    |     WHERE shop_id=X    | (MySQL)    |
+------------+                        +------------+
  Shop X still serving reads/writes from source

Phase 2: Binlog Streaming (catch-up)
+------------+                        +------------+
| Source Pod  |  --- stream binlog --> | Target Pod |
| (MySQL)    |     filter shop_id=X   | (MySQL)    |
+------------+                        +------------+
  Ongoing writes to source are replicated to target in near-real-time

Phase 3: Cutover (atomic switch)
  1. Pause writes for shop X (brief -- seconds)
  2. Drain remaining binlog events
  3. Verify data integrity (row counts, checksums)
  4. Update Sorting Hat: shop X -> target pod
  5. Resume writes -- now hitting target pod
  6. Clean up source data (async)
```

### Data Integrity Verification

The most critical part of migration is ensuring zero data loss. Ghostferry uses:
- **Inline verification:** checksums of copied rows during the bulk copy phase
- **Binlog verification:** every binlog event for the shop is accounted for
- **Post-cutover verification:** row-count comparison and sampled row checksums

If verification fails at any point, the migration aborts and the shop stays on the source pod. No data corruption, no partial state.

### Cutover Window

The cutover (Phase 3) is the only moment where the shop experiences any impact. Writes are paused for a few seconds while the routing table is updated. Reads can continue to be served from the source until the switch completes. In practice, the cutover window is 1-5 seconds -- imperceptible for most merchants.

### Migration at Scale

Shopify runs hundreds of migrations per week for rebalancing. This requires:
- A migration scheduler that respects rate limits (don't migrate too many shops from one pod simultaneously)
- Priority queues (emergency migrations for overloaded pods jump the line)
- Rollback capability (re-route back to source if target pod has issues)
- Observability: dashboards tracking active migrations, success rates, cutover durations

---

## Step 7: Noisy Neighbor Prevention

In a shared-infrastructure model, one shop's flash sale can degrade service for thousands of other shops on the same pod. This is the defining challenge of multi-tenancy.

### Defense in Depth

```
Layer 1: Edge Rate Limiting (Sorting Hat)
  - Per-shop request rate limits (e.g., 40 req/sec for basic plan)
  - Per-IP rate limits within a shop (bot protection)
  - 429 responses before traffic hits the pod

Layer 2: Pod-Level Resource Quotas
  - Per-shop MySQL query budget (max concurrent queries, max query time)
  - Per-shop Redis memory limits
  - Per-shop Sidekiq job queue limits
  - Per-shop cache eviction policies

Layer 3: Application-Level Throttling
  - Per-shop API rate limits (REST and GraphQL)
  - Adaptive throttling: if pod CPU > 80%, tighten limits for top consumers
  - Circuit breakers on expensive operations (bulk imports, report generation)

Layer 4: Pod Isolation for Whales
  - Enterprise merchants on dedicated pods (single-tenant pod)
  - Flash sale merchants temporarily migrated to high-capacity pods
  - Automatic detection of shops that exceed thresholds -> flag for migration
```

### Monitoring Per-Tenant Resource Consumption

You cannot enforce limits you do not measure. Every request is tagged with `shop_id`, and metrics are aggregated per shop:

- Request rate and latency (p50, p95, p99)
- MySQL query count and total query time
- Redis operations and memory usage
- Background job count and execution time
- Error rate

These per-shop metrics feed the rebalancing service (Step 8) and alert on anomalies.

### The Flash Sale Problem

A merchant announces a flash sale. Traffic spikes 100x in seconds. Without protection:
- MySQL connections saturate
- Redis CPU spikes from cache stampede
- Other shops on the pod experience elevated latency

Mitigations:
- **Pre-scaling:** Merchants can notify the platform of upcoming sales; ops pre-migrates them to a high-capacity or dedicated pod
- **Automatic detection:** If a shop's traffic exceeds 5x its rolling average, the edge begins progressive rate limiting
- **Queue-based admission:** For checkout, use a virtual waiting room that throttles concurrent sessions per shop

---

## Step 8: Rebalancing and Pod Lifecycle

### Rebalancing Strategy

The rebalancing service continuously monitors pod utilization and decides when to move shops.

```
Rebalancing Loop (runs every 10 minutes):
  1. Collect per-pod metrics: CPU, memory, disk I/O, MySQL connections, query latency
  2. Collect per-shop metrics on overloaded pods: identify top resource consumers
  3. Score each pod: utilization_score = weighted(cpu, memory, disk, connections)
  4. If any pod exceeds threshold (e.g., 75% sustained utilization):
     a. Identify candidate shops to migrate (largest resource consumers)
     b. Identify target pods with lowest utilization scores
     c. Verify target pod has capacity for the candidate shop
     d. Schedule migration via Ghostferry
  5. If adding a new merchant: place on the pod with lowest utilization score
     (bin-packing heuristic, respecting pod capacity limits)
```

### Pod Provisioning

New pods are added when overall platform utilization exceeds a threshold (e.g., average pod utilization > 60%). Pod provisioning is automated:

1. Infrastructure as code spins up new MySQL cluster, Redis, app servers
2. Schema migrations run on the new empty database
3. Pod registers itself with the control plane
4. New shops are provisioned onto the new pod; existing shops may be migrated over
5. Sorting Hat is updated with the new pod's endpoints

### Pod Decommissioning

To remove a pod (hardware refresh, region retirement):
1. Mark pod as draining -- no new shops assigned
2. Migrate all shops off the pod using Ghostferry (this can take days for a large pod)
3. Once empty, verify zero traffic reaching the pod
4. Tear down infrastructure

---

## Step 9: Tenant Configuration and the Control Plane

### Per-Tenant Configuration

Each shop has extensive configuration that is tenant-specific:

```
ShopConfiguration
+-- Domain settings (custom domain, SSL certificate)
+-- Theme (Liquid templates, assets)
+-- Payment providers (Stripe, PayPal, Shopify Payments)
+-- Shipping rules (rates, zones, carriers)
+-- Tax settings (per-region tax rules)
+-- API credentials (third-party apps)
+-- Plan tier (determines rate limits, features, pod eligibility)
+-- Feature flags (per-shop rollouts)
```

This configuration lives in the pod's MySQL database alongside the shop's transactional data. When a shop is migrated, Ghostferry moves the config rows too -- no separate sync needed.

### Control Plane Architecture

The control plane is a separate service (not inside a pod) that manages global state:

```
+-------------------+
| Control Plane     |
|-------------------|
| - Shop registry   |  (shop_id, plan, creation date, owner)
| - Pod registry    |  (pod_id, endpoints, capacity, status)
| - Routing table   |  (shop_id -> pod_id, replicated to Sorting Hat)
| - Domain registry |  (custom_domain -> shop_id)
| - Migration state |  (active migrations, history, rollback info)
| - Audit log       |  (who changed what, when)
+-------------------+
    |
    v
Global PostgreSQL cluster (not MySQL -- this is platform metadata, not tenant data)
```

The control plane must be highly available -- if it goes down, new shops cannot be provisioned and migrations cannot run. But existing routing continues to work because Sorting Hat caches the routing table. This is a key resilience property: the data plane (serving requests) is decoupled from the control plane (managing configuration).

---

## Step 10: Failure Modes and Operational Concerns

### Pod Database Failure

If a pod's MySQL primary fails:
1. Automated failover promotes a replica to primary (orchestrated by a tool like Orchestrator or Vitess)
2. App servers reconnect to the new primary
3. Brief write unavailability (seconds) during failover
4. All shops on the pod are affected equally -- this is the blast radius of a pod-level failure

Blast radius is O(thousands of shops), not O(millions). This is the entire point of the pod architecture: failures are contained.

### Sorting Hat Cache Inconsistency

If the Sorting Hat's local cache is stale (still pointing shop X to old pod after migration):
- Requests go to the old pod, which no longer has shop X's data
- The app server returns a 404 or error
- Sorting Hat detects the error and falls back to the routing service for a fresh lookup
- Cache is invalidated and refreshed

To prevent this: during Ghostferry cutover, the routing update is pushed to all Sorting Hat instances before writes resume on the target pod. Use a pub/sub mechanism (Redis pub/sub or a gossip protocol) for fast cache invalidation.

### Runaway Migration

A Ghostferry migration stalls or takes too long (source pod is under heavy write load, binlog streaming cannot keep up):
- Timeout thresholds trigger an alert
- The migration can be paused and retried during a lower-traffic window
- If the situation is urgent (source pod is dying), you can force a faster cutover with a slightly longer write pause

### Cascading Pod Overload

If rebalancing migrates shops off an overloaded pod, the target pods must have headroom. Migrating a whale shop to an already-busy pod just moves the problem. The rebalancing algorithm must account for the shop's resource profile, not just the target pod's current utilization.

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Sharding strategy | Pod-based (explicit mapping) | Consistent hashing | Control over placement, enterprise isolation, bin-packing |
| Database isolation | Database-per-pod (shared rows) | Database-per-tenant | Operational sanity at millions of tenants; O(100) databases vs O(millions) |
| Tenant scoping | Application-level default scopes | Database-level row security | Performance (no per-row policy check), flexibility, Packwerk enforcement |
| Request routing | Sorting Hat (Lua/OpenResty) | Application-level routing | Sub-ms routing, no app server resources consumed on misrouted requests |
| Live migration | Ghostferry (binlog streaming) | Logical replication, dump/restore | Zero-downtime, row-level filtering by shop_id, inline verification |
| Noisy neighbor defense | Multi-layer (edge + pod + app) | Single-layer rate limiting | Defense in depth; no single layer catches everything |
| Control plane DB | PostgreSQL (separate from pods) | Same MySQL as pods | Decouples platform metadata from tenant data; different failure domain |
| Monolith structure | Packwerk module boundaries | Microservices | Avoids distributed system complexity; enforces boundaries without network hops |

---

## Common Mistakes to Avoid

1. **Proposing database-per-tenant at Shopify's scale.** At millions of tenants, this means millions of databases. Connection pooling, schema migrations, backups, and monitoring become impossible. Database-per-pod (O(100) databases) is the right granularity.

2. **Forgetting that pod routing must happen before the application layer.** If routing happens inside Rails, you have already consumed app server resources on the wrong pod. Sorting Hat at the Nginx/OpenResty layer catches this before any Ruby code runs.

3. **Treating all tenants as equal.** A shop doing $1M/day and a hobby shop doing $10/month have vastly different resource profiles. The architecture must handle enterprise isolation (dedicated pods) and small merchant density (thousands per pod).

4. **Handwaving the migration cutover.** "Just switch the routing" ignores the hard part: ensuring every write that hit the source pod before the switch has been replicated to the target. Ghostferry's binlog streaming and verification are the answer -- do not skip this.

5. **Ignoring cache invalidation during migration.** If Sorting Hat's cache still points to the old pod after migration, requests will fail. You need an active push mechanism to invalidate the routing cache at cutover time, not just TTL-based expiry.

6. **Single-layer rate limiting.** Applying rate limits only at the edge misses database-level abuse (expensive queries, bulk imports). Applying limits only at the application misses volumetric attacks. You need both.

7. **Neglecting the control plane's availability characteristics.** The control plane manages migrations and provisioning, but existing traffic routing must work even if the control plane is down. Decouple the data plane from the control plane.

8. **Over-rotating on microservices.** Shopify runs a massive Rails monolith with Packwerk for boundaries. In an interview, proposing 50 microservices for this problem misses the point. The pod architecture provides isolation at the infrastructure level; the monolith provides developer velocity at the code level.

---

## Related Topics

- [[../../../01-databases-and-storage/index|Databases & Storage]] -- data partitioning, sharding strategies, MySQL replication
- [[../../../02-scaling-reads/index|Scaling Reads]] -- read replicas, per-tenant caching, cache invalidation
- [[../../../03-scaling-writes/index|Scaling Writes]] -- write isolation, pod-based horizontal scaling
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- consistency, data migration, routing
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- blast radius containment, failover, migration rollback
- [[../../../08-api-gateway-and-service-mesh/index|API Gateway & Service Mesh]] -- edge routing, rate limiting, TLS termination
