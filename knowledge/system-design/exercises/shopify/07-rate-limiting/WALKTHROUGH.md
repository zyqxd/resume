# Walkthrough: Design a Rate Limiting System for APIs (Shopify)

## Step 1: Clarify Requirements and Scope

Before drawing anything, confirm the scope with the interviewer:
- Are we designing for GraphQL, REST, or both? (Both -- GraphQL uses cost-based limiting, REST uses request-count limiting)
- What is the tenant model? (Per-app, per-merchant -- App X on Shop Y has its own bucket)
- Is strict global consistency required? (No -- small windows of over-admission are acceptable, large bursts are not)
- What happens when the rate limiting infrastructure is down? (Fail-open -- allow traffic rather than block everything)
- Do we need tiered limits? (Yes -- partner apps get higher quotas)

This scoping is critical. A system that needs strict global consistency at sub-millisecond latency across regions is a fundamentally different design than one that tolerates a few percent over-admission. Shopify explicitly chose the latter -- and that decision flows through every layer.

---

## Step 2: High-Level Architecture

```
Third-Party App
    |
    | HTTPS request (GraphQL or REST)
    v
+---------------------+
| API Gateway / Edge   |  (TLS termination, auth, routing)
+----------+----------+
           |
    +------v-------+
    | Rate Limit   |  (middleware -- runs BEFORE request execution)
    | Middleware    |
    +------+-------+
           |
    +------v-------+       +-------------------+
    | Query Cost   |       | Redis Cluster     |
    | Analyzer     |       | (bucket state)    |
    | (GraphQL)    |       +-------------------+
    +------+-------+              ^
           |                      |
           v                      |
    +------+-------+       +------+-------+
    | Bucket       +------>| Local Cache  |
    | Manager      |<------| (in-process) |
    +--------------+       +--------------+
           |
    +------v--------+
    | API Handler   |  (executes query only if rate limit passes)
    | (GraphQL/REST)|
    +---------------+
```

### Core Components

1. **API Gateway** -- TLS termination, authentication, extracts (app_id, shop_id) from the OAuth token. Every request passes through here.
2. **Rate Limit Middleware** -- the decision point. Runs before query execution. Checks the bucket, deducts cost, returns 429 if over limit.
3. **Query Cost Analyzer** -- static analysis of the GraphQL query AST to compute cost before execution. Not needed for REST (fixed cost of 1).
4. **Bucket Manager** -- implements the leaky bucket algorithm. Manages local in-memory state and syncs with Redis.
5. **Redis Cluster** -- distributed state store for bucket counters. The source of truth for cross-pod enforcement.
6. **Local Cache** -- in-process bucket state to avoid hitting Redis on every request. Syncs periodically.

---

## Step 3: Query Cost Analysis (GraphQL)

This is the key differentiator from simple request-count rate limiting. Shopify's GraphQL Admin API computes a cost for every query before executing it.

### Static Analysis (Pre-Execution)

Parse the GraphQL query into an AST, then walk it to compute cost:

```
query {
  products(first: 50) {       # 50 nodes
    title                      # 0 (scalar on already-fetched node)
    variants(first: 100) {     # 50 * 100 = 5,000 nodes
      price                    # 0 (scalar)
      inventoryQuantity        # 0 (scalar)
    }
  }
}

Cost = 50 (products) + 50 * 100 (variants) = 5,050 points
```

### Cost Rules

- **Root connection fields**: cost = `first` or `last` argument value
- **Nested connections**: cost = parent count * child's `first`/`last` value (multiplicative)
- **Scalar fields on fetched nodes**: 0 (already paying for the node)
- **Mutations**: fixed cost per mutation type (e.g., productCreate = 10)

### Why Static, Not Actual?

Static analysis computes cost from the query structure, not from actual database rows returned. A query for `products(first: 50)` costs 50 even if the shop only has 3 products.

**Trade-off:** Static analysis overcharges merchants with small catalogs but is predictable and cheap to compute. Actual cost analysis requires executing the query first, which defeats the purpose of rate limiting (you already did the work). Shopify chose predictability over precision -- clients can reason about their quota usage without guessing.

**Implementation detail:** The cost analyzer is a pure function of the query AST and schema metadata. It has zero I/O, runs in microseconds, and can be unit-tested exhaustively. This keeps it off the critical path.

---

## Step 4: The Leaky Bucket Algorithm

Shopify uses a leaky bucket (equivalent to token bucket with continuous refill). Each (app_id, shop_id) pair has its own bucket.

### Bucket State

```
Bucket {
  key:           "ratelimit:{app_id}:{shop_id}"
  current_level: Float      # current points consumed (0 = empty, 1000 = full)
  max_capacity:  Integer    # 1,000 points (default)
  restore_rate:  Float      # 50 points/second (drains from bucket)
  last_updated:  Timestamp  # for computing drain since last check
}
```

### Algorithm (Check + Deduct)

```
function check_rate_limit(bucket_key, query_cost):
  bucket = load_bucket(bucket_key)

  # Drain: compute how many points leaked since last check
  elapsed = now() - bucket.last_updated
  drained = elapsed * bucket.restore_rate
  bucket.current_level = max(0, bucket.current_level - drained)
  bucket.last_updated = now()

  # Check: would this request overflow?
  if bucket.current_level + query_cost > bucket.max_capacity:
    retry_after = (bucket.current_level + query_cost - bucket.max_capacity) / bucket.restore_rate
    return THROTTLED(retry_after)

  # Deduct
  bucket.current_level += query_cost
  remaining = bucket.max_capacity - bucket.current_level
  return ALLOWED(remaining)
```

### Why Leaky Bucket Over Sliding Window?

- **Smooth traffic shaping:** leaky bucket naturally spreads load. A sliding window allows a burst at window boundaries.
- **Simple mental model for clients:** "You have X points remaining, restoring at Y/second." Clients can predict exactly when they will have enough quota.
- **Single state value:** just `current_level` and `last_updated`. A sliding window log requires storing individual request timestamps.

**Trade-off:** Leaky bucket is less precise about burst patterns -- it does not distinguish between "50 requests in 1 second" and "1 request per 20ms for 1 second." For API rate limiting this is fine. For DDoS protection it is not (out of scope).

---

## Step 5: Distributed Enforcement with Redis

The core challenge: multiple API pods serve the same (app_id, shop_id). The bucket state must be shared.

### Redis Lua Script (Atomic Check-and-Deduct)

```lua
-- KEYS[1] = bucket key
-- ARGV[1] = query_cost, ARGV[2] = max_capacity, ARGV[3] = restore_rate, ARGV[4] = now_ms

local key = KEYS[1]
local cost = tonumber(ARGV[1])
local max_cap = tonumber(ARGV[2])
local restore = tonumber(ARGV[3])
local now = tonumber(ARGV[4])

local data = redis.call('HMGET', key, 'level', 'updated')
local level = tonumber(data[1]) or 0
local updated = tonumber(data[2]) or now

-- Drain
local elapsed = (now - updated) / 1000.0
local drained = elapsed * restore
level = math.max(0, level - drained)

-- Check
if level + cost > max_cap then
  local retry_after = (level + cost - max_cap) / restore
  return {0, level, retry_after * 1000}
end

-- Deduct
level = level + cost
redis.call('HMSET', key, 'level', level, 'updated', now)
redis.call('EXPIRE', key, 30)  -- TTL: auto-cleanup for inactive buckets

return {1, level, 0}
```

**Why a Lua script?** The check-and-deduct must be atomic. Without it, two pods could both read `current_level = 900`, both add 200, and both succeed -- allowing 1,100 points in a 1,000-point bucket. The Lua script runs atomically on the Redis server.

### Redis Cluster Topology

```
+------------------+     +------------------+     +------------------+
| Redis Primary 1  |     | Redis Primary 2  |     | Redis Primary 3  |
| (slots 0-5460)   |     | (slots 5461-10922)|    | (slots 10923-16383)|
+--------+---------+     +--------+---------+     +--------+---------+
         |                        |                        |
+--------+---------+     +--------+---------+     +--------+---------+
| Redis Replica 1  |     | Redis Replica 2  |     | Redis Replica 3  |
+------------------+     +------------------+     +------------------+
```

Bucket keys are distributed across slots by hash. Each (app_id, shop_id) pair maps to exactly one primary. This gives us horizontal scalability -- add more shards to handle more buckets.

**Key insight:** Use hash tags `{app_id:shop_id}` so all operations for a bucket hit the same shard. No cross-slot transactions needed.

---

## Step 6: Local Approximation for Sub-Millisecond Latency

Even with Redis, a network round trip per request adds 0.5-2ms. For a hot path that must be sub-millisecond, this is too slow.

### Two-Tier Architecture

```
                   +-------------------+
                   | Redis Cluster     |
                   | (global truth)    |
                   +--------+----------+
                       ^    |
            sync every |    | sync every
            ~100ms     |    | ~100ms
                       |    v
+-----------+    +-----+--------+    +-----------+
| API Pod 1 |--->| Local Bucket |--->| API Pod 2 |
|           |<---| Cache        |<---|           |
+-----------+    +--------------+    +-----------+
```

### How It Works

1. **Hot path (every request):** Check and deduct against the local in-memory bucket. This is a HashMap lookup -- sub-microsecond.
2. **Background sync (every 50-100ms):** A background goroutine/thread syncs local state with Redis:
   - Sends accumulated local deductions to Redis (batch)
   - Receives the current global bucket level
   - Adjusts local state to match global truth
3. **Cold start:** If a bucket is not in local cache, do a synchronous Redis fetch (one-time cost per bucket per pod).

### Accuracy Trade-off

With 10 pods and 100ms sync intervals, the worst case over-admission is:
- Each pod independently admits up to `restore_rate * sync_interval` extra points
- 10 pods * 50 points/sec * 0.1 sec = 50 points over-admission per sync cycle
- On a 1,000-point bucket, that is 5% over-admission -- acceptable per requirements

**Production tuning:** Adjust sync interval based on bucket size. High-traffic buckets (partner apps doing thousands of requests/second) get shorter sync intervals (10-20ms). Low-traffic buckets use longer intervals or synchronous Redis checks (latency matters less when traffic is low).

---

## Step 7: Fail-Open Policy and Degraded Modes

This is a Staff-level concern that junior candidates miss entirely. What happens when Redis is unreachable?

### Failure Scenarios

| Scenario | Behavior | Rationale |
|---|---|---|
| Redis primary down, replica promoted | Brief inconsistency (~1s), self-heals | Redis Sentinel/Cluster handles this |
| Redis cluster fully unreachable | Fail-open: allow all requests | Blocking all API traffic is worse than temporary over-admission |
| Single Redis shard down | Fail-open for affected buckets only | Other shards unaffected |
| Local cache memory pressure | Evict least-recently-used buckets, fall back to Redis | Graceful degradation |
| Pod crash | Other pods unaffected; bucket state is in Redis | Stateless recovery |

### Fail-Open Implementation

```
function check_rate_limit(bucket_key, query_cost):
  try:
    result = redis_lua_script(bucket_key, query_cost, ...)
    return result
  catch RedisConnectionError:
    metrics.increment("rate_limit.redis_unavailable")
    # Fall back to local-only enforcement
    local_result = local_bucket_check(bucket_key, query_cost)
    if local_result == UNKNOWN:
      # No local state either -- fail open
      return ALLOWED(remaining=UNKNOWN)
    return local_result
```

**Why fail-open?** Shopify's revenue depends on API traffic. Third-party apps power storefronts, inventory sync, order management. If rate limiting blocks all traffic because Redis is down, merchants lose sales. A few minutes of unlimited API access is far less costly than a few minutes of zero API access.

**Guardrail:** Even in fail-open mode, local per-pod limits still apply. A single pod's in-memory bucket prevents one app from consuming all of that pod's resources. You lose cross-pod coordination, but not all protection.

### Circuit Breaker on Redis

Wrap Redis calls in a circuit breaker. After N consecutive failures in M seconds, open the circuit and skip Redis calls entirely for a cooldown period. This prevents cascading latency from Redis timeouts stacking up on the request path.

---

## Step 8: Per-App, Per-Merchant Buckets and Tier Overrides

### Bucket Key Design

```
Standard:  ratelimit:graphql:{app_id}:{shop_id}
REST:      ratelimit:rest:{app_id}:{shop_id}
```

Every (app, shop) pair is isolated. App X hammering Shop A does not affect App Y on Shop A, or App X on Shop B. This is essential for a multi-tenant platform where thousands of third-party apps operate independently.

### Tier Configuration

```
TierConfig {
  standard: {
    graphql: { max_capacity: 1000, restore_rate: 50 },
    rest:    { max_capacity: 40,   restore_rate: 2 }   # 40 req/s burst, 2/s restore
  },
  plus_partner: {
    graphql: { max_capacity: 2000, restore_rate: 100 },
    rest:    { max_capacity: 80,   restore_rate: 4 }
  },
  certified_partner: {
    graphql: { max_capacity: 4000, restore_rate: 200 },
    rest:    { max_capacity: 160,  restore_rate: 8 }
  }
}
```

### Tier Resolution

```
function get_bucket_config(app_id, shop_id):
  # Check for per-app override first (e.g., emergency throttle or special deal)
  override = config_store.get_override(app_id, shop_id)
  if override:
    return override

  # Fall back to app's partner tier
  app_tier = app_registry.get_tier(app_id)
  return tier_configs[app_tier]
```

**Caching:** Tier configs change rarely (when an app gets certified or a manual override is applied). Cache them aggressively -- in-memory with a 5-minute TTL, invalidated by a config change event.

**Production scenario:** A flash sale app is hammering the API at 10x normal rate. Ops can push a per-app override to reduce their limits in real time, without redeploying. This is a critical operational lever.

---

## Step 9: Response Headers and Client Experience

A well-designed rate limiting system is transparent. Clients should never have to guess their quota state.

### GraphQL Response Headers

```
HTTP/1.1 200 OK
X-Shopify-Shop-Api-Call-Limit: 342/1000
X-Shopify-Shop-Api-Call-Limit-Restore-Rate: 50

{
  "data": { ... },
  "extensions": {
    "cost": {
      "requestedQueryCost": 342,
      "actualQueryCost": 210,
      "throttleStatus": {
        "maximumAvailable": 1000.0,
        "currentlyAvailable": 658.0,
        "restoreRate": 50.0
      }
    }
  }
}
```

### Throttled Response (429)

```
HTTP/1.1 429 Too Many Requests
Retry-After: 2.5
X-Shopify-Shop-Api-Call-Limit: 1000/1000

{
  "errors": [{
    "message": "Throttled. Available quota: 0/1000. Retry after 2.5s.",
    "extensions": {
      "code": "THROTTLED",
      "retryAfter": 2.5,
      "cost": {
        "requestedQueryCost": 502,
        "maximumAvailable": 1000.0,
        "currentlyAvailable": 12.0,
        "restoreRate": 50.0
      }
    }
  }]
}
```

### Why Both Headers and Body?

- **Headers** are easy to parse in middleware/retry logic without deserializing the response body
- **Body/extensions** provide detailed cost breakdown for debugging and optimization
- `requestedQueryCost` vs `actualQueryCost` lets clients see how much they were charged (static estimate) vs how much work was actually done

### Client Retry Strategy

Well-behaved clients implement exponential backoff with the `Retry-After` hint:

```
1. Send request
2. If 429, read Retry-After header
3. Sleep for Retry-After seconds (plus small jitter)
4. Retry
5. If still 429, double the wait (exponential backoff)
6. After N retries, surface error to the user
```

**Key insight:** The `Retry-After` header is computed from actual bucket state -- it tells the client exactly when they will have enough quota. This is more efficient than blind exponential backoff.

---

## Step 10: Observability and Operational Controls

At Shopify scale (100K+ requests/second), you cannot operate a rate limiting system without deep observability.

### Metrics to Emit

- `rate_limit.check.latency` -- P50/P99 of the rate limit check (should be <1ms)
- `rate_limit.allowed` / `rate_limit.throttled` -- by app_id, shop_id, endpoint
- `rate_limit.redis.latency` -- Redis round-trip time
- `rate_limit.redis.errors` -- Redis failures (triggers circuit breaker alerting)
- `rate_limit.bucket.utilization` -- histogram of how full buckets are (detect apps consistently at capacity)
- `rate_limit.fail_open.count` -- how often we are running without Redis enforcement
- `rate_limit.cost.requested` vs `rate_limit.cost.actual` -- detect queries where static cost wildly overestimates

### Operational Levers

1. **Global kill switch:** Disable rate limiting entirely (useful during incident response when rate limiting itself is causing issues)
2. **Per-app override:** Increase or decrease limits for a specific app in real time
3. **Dynamic sync interval:** Adjust local-to-Redis sync frequency under load
4. **Cost multiplier:** Temporarily increase the cost of expensive operations (e.g., 2x multiplier during peak traffic)
5. **Shadow mode:** Log what would be throttled without actually throttling -- essential for rolling out new limits

### Dashboards

A dedicated rate limiting dashboard showing:
- Top 20 apps by throttle rate (which apps are hitting limits most)
- Top 20 apps by total cost consumed (which apps are consuming the most resources)
- Redis cluster health and latency
- Fail-open event timeline
- Bucket utilization distribution (are most apps well under limits, or is the system under-provisioned?)

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Cost model | Static query analysis | Actual execution cost | Predictable, zero I/O, clients can reason about usage upfront |
| Algorithm | Leaky bucket | Sliding window log | Simple state (one counter), smooth traffic shaping, easy client mental model |
| Distributed state | Redis Lua script | Database, distributed lock | Atomic check-and-deduct, sub-ms latency, proven at scale |
| Consistency | Local approx + periodic sync | Synchronous Redis on every request | Sub-ms hot path; 5% over-admission acceptable |
| Failure mode | Fail-open | Fail-closed | API downtime costs more than temporary over-admission |
| Bucket isolation | Per-app, per-shop | Per-shop only | Prevents noisy-neighbor across apps on the same shop |
| Tier config | Centralized config store | Hardcoded per-app | Operational flexibility -- change limits without deploy |

---

## Common Mistakes to Avoid

1. **Executing the GraphQL query before checking cost.** The entire point of static cost analysis is to reject expensive queries without doing the work. If you compute actual cost, you have already paid the database cost.

2. **Using a single global counter instead of per-app, per-shop buckets.** This creates a noisy-neighbor problem where one misbehaving app can exhaust the limit for all apps on a shop. Isolation is non-negotiable in multi-tenant systems.

3. **Synchronous Redis on every request.** At 100K+ req/s, this means 100K+ Redis round trips per second with tail latency in the milliseconds. Use local approximation with background sync for the hot path.

4. **Fail-closed when Redis is down.** This turns a Redis outage into a full API outage. Shopify's API powers millions of storefronts -- fail-open with local-only enforcement is the correct choice.

5. **Forgetting about the REST API.** The question mentions GraphQL, but Shopify also has a REST API with traditional request-count limiting (40 req/s). Your design must handle both cost-based and count-based limiting through the same pipeline.

6. **Not providing actionable response headers.** A 429 response without `Retry-After` forces clients to guess. Provide the exact retry delay computed from bucket state. Include remaining quota in every successful response so clients can self-throttle.

7. **Ignoring tier overrides in the design.** A system that only supports one set of limits will need a redesign the moment a partner app needs higher throughput. Build the tier/override system from day one.

8. **Treating the cost analyzer as trivial.** Nested GraphQL connections multiply cost. `products(first:250) { variants(first:100) }` = 25,000 points -- more than 25x the bucket capacity. The cost analyzer must handle nested multiplication, aliases, fragments, and inline fragments correctly.

---

## Related Topics

- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- distributed counters, consistency vs. availability trade-offs
- [[../../../02-scaling-reads/index|Scaling Reads]] -- Redis caching, in-memory state, read-heavy workloads
- [[../../../08-api-gateway-and-service-mesh/index|API Gateway]] -- request routing, middleware chains, throttling as a cross-cutting concern
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- fail-open vs fail-closed, circuit breakers, degraded mode
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- Redis internals, Lua scripting, cluster topology
