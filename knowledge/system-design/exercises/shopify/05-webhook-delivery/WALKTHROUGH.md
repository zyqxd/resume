# Walkthrough: Design a Webhook Delivery System (Shopify)

## Step 1: Clarify Requirements and Scope

Before drawing anything, confirm the scope with the interviewer:
- How many third-party apps subscribe to webhooks? (Thousands -- Shopify has 10K+ public apps)
- What is the fan-out ratio? (A single merchant event may need delivery to 50+ apps)
- What delivery guarantee? (At-least-once -- exactly-once is impractical across network boundaries)
- What happens when an endpoint is persistently down? (Dead letter queue, then auto-disable)
- What is peak load? (BFCM spikes: 100x normal, billions of deliveries per day)
- Do we need to support payload transformation or filtering? (Out of scope -- deliver raw event payloads)

This scoping eliminates "design a generic pub/sub system" and focuses on the hard parts: reliable fan-out delivery to unreliable third-party endpoints at extreme scale.

**Back-of-envelope math:**
- Normal load: ~50K events/second, each fanning out to ~5 apps = 250K deliveries/second
- BFCM peak: 100x = 25M deliveries/second
- Payload size: up to 64KB per webhook
- Bandwidth at peak: 25M * 64KB = ~1.6 TB/second (worst case; average payloads are much smaller)
- Delivery SLA: p95 < 1 second under normal load

---

## Step 2: High-Level Architecture

```
Merchant Action (order created, product updated, ...)
    |
    v
+-----------------+
| Event Ingestion |  (internal services emit domain events)
| (Kafka)         |
+--------+--------+
         |
    +----v-----------+
    | Fan-out Service |  (looks up subscriptions, creates delivery jobs)
    +----+-----------+
         |
    +----v-----------------+
    | Delivery Queue       |  (partitioned by destination endpoint)
    | (Redis / SQS / Kafka)|
    +----+-----------------+
         |
    +----v-----------------+
    | Delivery Workers     |  (HTTP POST to consumer endpoints)
    | (horizontally scaled)|
    +----+-----------------+
         |                \
    +----v----+     +------v---------+
    | Delivery|     | Retry Queue    |
    | Log DB  |     | (exp. backoff) |
    +---------+     +-------+--------+
                            |
                    +-------v----------+
                    | Dead Letter Queue|
                    | (after N fails)  |
                    +------------------+
```

### Core Components

1. **Event Ingestion (Kafka)** -- internal services publish domain events (order/created, product/updated, etc.) to a Kafka topic. This is the single source of truth for "what happened."
2. **Fan-out Service** -- consumes events from Kafka, queries the subscription registry to determine which apps care about this event for this merchant, and enqueues one delivery job per (event, destination) pair.
3. **Delivery Queue** -- holds pending webhook deliveries. Partitioned by destination endpoint to enable per-endpoint rate limiting and head-of-line blocking isolation.
4. **Delivery Workers** -- stateless HTTP clients that pull jobs from the queue, sign the payload with HMAC, POST to the consumer endpoint, and record the result.
5. **Retry Queue** -- failed deliveries are re-enqueued with exponential backoff delay.
6. **Dead Letter Queue (DLQ)** -- after N consecutive failures, deliveries land here. The endpoint is flagged as unhealthy.
7. **Delivery Log** -- persistent record of every delivery attempt (status, latency, response code) queryable by merchants for debugging.

---

## Step 3: Event Ingestion and Fan-out

### Event Bus (Kafka)

Internal services emit domain events onto Kafka topics. A single topic like `merchant_events` is partitioned by `merchant_id`, preserving per-merchant ordering.

```
order-service     ---> Kafka topic: merchant_events
product-service   --->   partition key: merchant_id
inventory-service --->
```

**Why Kafka here:** Durability (events survive service crashes), replay (reprocess if fan-out has a bug), and ordering (per-merchant event ordering simplifies reasoning).

### Subscription Registry

The subscription registry stores which apps want which events for which merchants:

```
subscriptions table:
  id | app_id | merchant_id | event_type       | endpoint_url              | secret
  1  | 42     | 1001        | order/created    | https://app42.com/hooks   | sk_abc...
  2  | 42     | 1001        | product/updated  | https://app42.com/hooks   | sk_abc...
  3  | 99     | 1001        | order/created    | https://app99.io/webhook  | sk_xyz...
```

**Indexing:** Composite index on `(merchant_id, event_type)` for fast fan-out lookups. This table is read-heavy; cache it aggressively in Redis with invalidation on subscription changes.

### Fan-out Process

```
1. Fan-out service consumes event: {merchant_id: 1001, type: "order/created", payload: {...}}
2. Query subscriptions: SELECT * WHERE merchant_id=1001 AND event_type='order/created'
3. Returns: [app_42_subscription, app_99_subscription, ...]
4. For each subscription, enqueue a delivery job:
   {
     delivery_id: "evt_abc-app_42"     # idempotency key
     event_id: "evt_abc"
     endpoint_url: "https://app42.com/hooks"
     payload: {...}
     hmac_secret: "sk_abc..."
     attempt: 0
   }
```

**Fan-out challenge at BFCM:** A single "order/created" event for a popular merchant could fan out to 50-100 apps. During BFCM, a merchant processing 1000 orders/minute generates 50K-100K delivery jobs per minute just from that one merchant. The fan-out service must be horizontally scalable.

**Key design choice:** The fan-out service writes delivery jobs, not the originating service. This decouples event producers from webhook plumbing -- the order service does not need to know about webhooks.

---

## Step 4: Delivery Queue Design

This is one of the most important decisions in the system. The delivery queue sits between "we know what to deliver" and "we actually deliver it," and its design determines how well you handle slow endpoints, rate limits, and head-of-line blocking.

### Option A: Redis-Backed Job Queue (Sidekiq/Resque Pattern)

Shopify historically uses Ruby on Rails with Sidekiq. This pattern uses Redis sorted sets for delayed/retry scheduling and Redis lists for ready-to-process jobs.

```
Redis queues:
  webhook:delivery:ready       # list -- jobs ready to process
  webhook:delivery:scheduled   # sorted set -- delayed retries, scored by execute-at timestamp
  webhook:delivery:dead        # list -- dead letter queue
```

**Advantages:** Battle-tested at Shopify's scale, low latency (~1ms enqueue), workers pull jobs via BRPOP (blocking pop). Sidekiq processes thousands of jobs/second per worker process.

**Disadvantage:** Redis is in-memory. At BFCM scale (millions of pending jobs), memory pressure becomes real. Mitigate with queue depth limits and backpressure.

### Option B: Per-Endpoint Virtual Queues

The naive approach (one big FIFO queue) suffers from head-of-line blocking: a slow endpoint (30s timeout, 429s) holds up a worker that could be delivering to fast endpoints. Instead, partition the queue logically by destination endpoint.

```
Conceptual model:
  endpoint:app42.com/hooks  -> [job_1, job_2, job_3]
  endpoint:app99.io/webhook -> [job_4, job_5]
  endpoint:slow-app.com     -> [job_6]  (this endpoint is slow -- only 1 in-flight)
```

In practice, implement this by tagging jobs with a destination key and having workers respect per-destination concurrency limits. This can be done with:
- Kafka topics partitioned by endpoint hostname hash
- Redis-backed semaphores per endpoint
- Separate SQS queues per endpoint (expensive at 10K+ endpoints)

**Decision: Redis-backed queue with per-endpoint concurrency semaphores.** This matches Shopify's actual stack and handles the head-of-line blocking problem without the overhead of thousands of physical queues.

---

## Step 5: HMAC Signing and Payload Construction

Every webhook must be signed so the consumer can verify it came from Shopify and was not tampered with.

### Signing Flow

```
1. Construct canonical payload (JSON, deterministic key ordering)
2. Compute HMAC-SHA256:
   signature = HMAC-SHA256(app_shared_secret, raw_payload_body)
3. Include in HTTP headers:
   POST /hooks HTTP/1.1
   Host: app42.com
   Content-Type: application/json
   X-Shopify-Topic: order/created
   X-Shopify-Hmac-SHA256: base64(signature)
   X-Shopify-Shop-Domain: cool-store.myshopify.com
   X-Shopify-Webhook-Id: evt_abc            # idempotency key
   X-Shopify-API-Version: 2025-01
   
   {"id": 12345, "email": "customer@example.com", ...}
```

### Consumer Verification

The consumer recomputes the HMAC using their copy of the shared secret and compares it to the header value. If they do not match, the consumer rejects the webhook. This prevents spoofing -- an attacker cannot forge a valid signature without the secret.

**Rotation concern:** When an app rotates its shared secret, there is a window where in-flight webhooks signed with the old secret will fail verification. Solution: support dual-secret validation (accept either old or new secret during a rotation window) or re-sign pending deliveries on secret rotation.

### Idempotency Key

The `X-Shopify-Webhook-Id` header serves as an idempotency key. Since the system guarantees at-least-once delivery (not exactly-once), the same webhook may be delivered more than once. Consumers must deduplicate using this ID.

**What goes in the ID:** A deterministic identifier derived from (event_id, subscription_id). Using a UUID per delivery attempt would defeat the purpose -- the ID must be stable across retries.

---

## Step 6: Delivery Workers and HTTP Semantics

### Worker Architecture

Delivery workers are stateless processes that:
1. Pull a job from the ready queue
2. Make an HTTP POST to the endpoint
3. Record the result (success or failure)
4. On failure, schedule a retry or move to the DLQ

```
Worker pseudocode:

loop:
  job = queue.dequeue()
  
  # Check per-endpoint rate limit / concurrency
  if endpoint_semaphore(job.endpoint).full?
    queue.requeue_with_delay(job, 1s)
    continue
  
  endpoint_semaphore(job.endpoint).acquire()
  
  payload = serialize(job.event_data)
  signature = hmac_sha256(job.secret, payload)
  
  response = http_post(
    url: job.endpoint_url,
    body: payload,
    headers: webhook_headers(signature, job),
    timeout: 5s,         # connect timeout
    read_timeout: 10s    # response timeout
  )
  
  endpoint_semaphore(job.endpoint).release()
  
  if response.status in 200..299
    record_success(job, response)
  else
    handle_failure(job, response)
```

### Timeout Strategy

Consumer endpoints have wildly different response times. Aggressive timeouts are essential:
- **Connect timeout: 5 seconds.** If the endpoint is not reachable in 5s, it is down.
- **Read timeout: 10 seconds.** The consumer should acknowledge quickly; processing can happen asynchronously on their side.

**Why not 30 seconds?** A worker blocked for 30s on one slow endpoint cannot serve other deliveries. With 1000 workers and 30s timeouts, a single slow endpoint can consume all capacity. Short timeouts protect the overall system.

### HTTP Response Semantics

- **2xx** -- Success. Record and move on.
- **410 Gone** -- Endpoint permanently removed. Auto-unsubscribe this webhook.
- **429 Too Many Requests** -- Consumer is rate limiting us. Respect `Retry-After` header, reduce sending rate to this endpoint.
- **5xx** -- Server error. Retry with backoff.
- **Timeout / Connection refused** -- Retry with backoff.
- **3xx** -- Follow redirects (limited depth), but log a warning for the merchant.

---

## Step 7: Retry Strategy and Dead Letter Queue

### Exponential Backoff with Jitter

Failed deliveries are retried on an exponential schedule with jitter to prevent thundering herd:

```
Attempt 1: immediate (first delivery)
Attempt 2: ~30 seconds
Attempt 3: ~2 minutes
Attempt 4: ~8 minutes
Attempt 5: ~30 minutes
Attempt 6: ~2 hours
Attempt 7: ~8 hours
Attempt 8: ~24 hours
(total window: ~48 hours from first attempt)

delay = min(base_delay * 2^attempt, max_delay)
jittered_delay = delay * (0.5 + random() * 0.5)
```

**Why 48 hours total?** Long enough that transient outages (deploys, cloud incidents) resolve, short enough that webhook data is still relevant. A webhook about an order created 3 days ago is less useful.

### Dead Letter Queue

After all retry attempts are exhausted (typically 8 attempts over 48 hours):

1. Move the delivery job to the DLQ
2. Increment the endpoint's failure counter
3. If the endpoint has been failing consistently (e.g., >95% failure rate over 24 hours), **disable the webhook subscription**
4. Notify the app developer via email that their endpoint has been disabled
5. Provide a re-enable mechanism in the Shopify admin UI

```
Endpoint health tracking:

endpoint_health:app42.com/hooks = {
  total_attempts_24h: 1500,
  failures_24h: 1485,
  failure_rate: 0.99,       # -> disable
  last_success: "2025-11-28T02:00:00Z",
  status: "disabled",
  disabled_at: "2025-11-29T06:00:00Z"
}
```

**Automatic disabling is critical at scale.** A dead endpoint that keeps receiving retry attempts wastes worker capacity, queue space, and network bandwidth. During BFCM, one badly-behaved app could consume disproportionate retry resources. Disabling early protects the system.

### Re-enable Flow

When an app developer fixes their endpoint and re-enables the subscription:
1. Clear the failure counter
2. Send a test webhook to verify the endpoint works
3. If the test succeeds, re-enable and deliver any DLQ'd webhooks that are still within the relevance window

---

## Step 8: Rate Limiting and Backpressure

### Per-Endpoint Rate Limiting

Third-party apps have varying capacity. Some can handle 1000 webhooks/second, others fall over at 10/second. The system must respect consumer capacity.

**Approach: Token bucket per endpoint** (stored in Redis):

```
rate_limit:app42.com/hooks = {
  tokens: 50,          # current available
  max_tokens: 50,      # bucket size
  refill_rate: 50/s,   # tokens per second
  last_refill: timestamp
}
```

Default rate limit: 50 requests/second per endpoint. Apps can request higher limits through the partner API.

When a delivery job is dequeued but the endpoint's bucket is empty, re-enqueue with a short delay (1-2 seconds). Do not count this as a failure.

### Backpressure During BFCM

At 100x normal load, the system must shed load gracefully rather than collapse:

1. **Queue depth monitoring** -- if the delivery queue exceeds a threshold (e.g., 10M pending jobs), activate backpressure:
   - Slow down the fan-out service (reduce Kafka consumer throughput)
   - This causes Kafka consumer lag, which is fine -- Kafka is designed to buffer
2. **Worker autoscaling** -- scale delivery workers based on queue depth. Kubernetes HPA or AWS auto-scaling groups watching the queue length metric.
3. **Priority queues** -- during BFCM, prioritize first-delivery attempts over retries. A fresh webhook is more time-sensitive than a retry of a 2-hour-old failure.
4. **Shed low-priority events** -- if necessary, delay low-priority event types (e.g., product/updated) in favor of high-priority ones (order/created, payment/confirmed). This is a last resort.

```
Queue priority (highest to lowest):
  1. Payment/financial events (order/paid, refund/created)
  2. Order lifecycle events (order/created, order/fulfilled)
  3. Inventory events (inventory/levels_changed)
  4. Catalog events (product/updated, collection/updated)
  5. Customer events (customer/created)
```

---

## Step 9: Delivery Logging and Merchant Visibility

Merchants need visibility into webhook delivery for debugging integration issues. This is a table-stakes feature that differentiates a production system from a toy.

### Delivery Log Schema

```sql
CREATE TABLE webhook_delivery_logs (
  id              BIGINT PRIMARY KEY,
  webhook_id      VARCHAR(64) NOT NULL,    -- idempotency key
  subscription_id BIGINT NOT NULL,
  merchant_id     BIGINT NOT NULL,
  app_id          BIGINT NOT NULL,
  event_type      VARCHAR(64) NOT NULL,
  endpoint_url    TEXT NOT NULL,
  
  -- Delivery details
  attempt_number  SMALLINT NOT NULL,
  status          VARCHAR(16) NOT NULL,    -- 'success', 'failed', 'pending'
  http_status     SMALLINT,
  response_body   TEXT,                    -- first 1KB of response (for debugging)
  error_message   TEXT,
  
  -- Timing
  created_at      TIMESTAMP NOT NULL,
  delivered_at    TIMESTAMP,
  duration_ms     INTEGER,
  
  INDEX idx_merchant_event (merchant_id, created_at DESC),
  INDEX idx_subscription_status (subscription_id, status, created_at DESC)
);
```

### Storage Considerations

At billions of deliveries per day, this table grows fast. Strategies:
- **TTL / partition by date:** Keep 30 days of logs, drop older partitions. Merchants rarely debug deliveries older than a week.
- **Separate hot/cold storage:** Recent logs in PostgreSQL (fast queries), older logs archived to S3 + queryable via Athena.
- **Write optimization:** Batch inserts from workers rather than one INSERT per delivery. Buffer in-memory and flush every 100ms.

### Merchant Dashboard

Expose via API and Shopify admin UI:
- List recent deliveries by status (success/failed/pending)
- Filter by event type, app, date range
- Show request/response details for failed deliveries
- "Retry" button for individual failed deliveries
- Endpoint health status and auto-disable notifications

---

## Step 10: Scaling for BFCM (100x Spikes)

BFCM is the defining constraint. The system must handle 100x normal volume without degrading delivery latency for healthy endpoints.

### Pre-BFCM Preparation

1. **Capacity planning:** Analyze last year's BFCM traffic, project growth, pre-provision 2x the expected peak.
2. **Load testing:** Replay last year's BFCM event stream through the system at 1.5x actual volume.
3. **Endpoint health audit:** Identify apps with historically poor endpoint reliability. Proactively notify their developers.
4. **Queue headroom:** Ensure Redis/Kafka have sufficient memory and partition capacity.

### Runtime Scaling Architecture

```
                          Event Ingestion
                               |
                    Kafka (100+ partitions)
                               |
              +----------------+----------------+
              |                |                |
        Fan-out Pod 1    Fan-out Pod 2    Fan-out Pod N
              |                |                |
              +--------+-------+--------+-------+
                       |                |
                  Redis Cluster    Redis Cluster
                  (delivery queue)  (rate limits)
                       |
         +-------------+-------------+
         |             |             |
    Worker Pool 1  Worker Pool 2  Worker Pool N
    (autoscaled)   (autoscaled)   (autoscaled)
         |
    +----+----+
    |         |
  Success   Failure --> Retry Queue --> DLQ
    |
  Delivery Log DB
  (sharded by merchant_id)
```

### Horizontal Scaling Levers

| Component | Scaling Strategy | BFCM Target |
|---|---|---|
| Kafka partitions | Pre-configured, add partitions before BFCM | 200+ partitions |
| Fan-out service | Stateless pods, scale by Kafka consumer lag | 50+ pods |
| Redis cluster | Shard by endpoint hash, add nodes | 20+ nodes |
| Delivery workers | Autoscale by queue depth | 500+ pods |
| Delivery log DB | Sharded by merchant_id, buffered writes | 10+ shards |

### Isolation Between Tenants

A misbehaving app endpoint must not affect delivery to other apps. Isolation mechanisms:
- **Per-endpoint concurrency limits** prevent one slow endpoint from consuming all workers
- **Separate retry budgets** per endpoint -- one app's retries do not starve another's first-delivery attempts
- **Circuit breaker per endpoint** -- if an endpoint fails 10 consecutive times, stop attempting delivery for a cooldown period before probing again

```
Circuit breaker states:
  CLOSED   --> delivering normally
  OPEN     --> endpoint is down, skip delivery, queue for later
  HALF_OPEN --> probe with one request to test if recovered
```

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Event bus | Kafka | RabbitMQ | Durability, replay, ordering, BFCM-scale throughput |
| Delivery queue | Redis (Sidekiq pattern) | SQS / Kafka | Low latency, battle-tested at Shopify, supports delayed jobs natively |
| Queue partitioning | Per-endpoint virtual queues | Single FIFO | Eliminates head-of-line blocking from slow endpoints |
| Delivery guarantee | At-least-once | Exactly-once | Exactly-once across network boundaries is impractical; push dedup to consumers via idempotency keys |
| Retry schedule | Exponential backoff + jitter (48h window) | Fixed interval | Prevents thundering herd, gives endpoints time to recover |
| Endpoint failure policy | Auto-disable after sustained failures | Retry indefinitely | Protects system resources; infinite retries waste capacity and queue space |
| Payload signing | HMAC-SHA256 per app secret | mTLS | Simpler for third-party developers; mTLS has certificate management burden |
| Delivery log storage | PostgreSQL (30-day TTL) + S3 archive | Elasticsearch | SQL is sufficient for merchant-scoped queries; ES adds operational complexity |
| BFCM scaling | Pre-provision + autoscale | Purely reactive autoscaling | Autoscaling has lag; pre-provisioning ensures capacity is ready for the spike |
| Rate limiting | Token bucket per endpoint in Redis | Leaky bucket | Token bucket allows small bursts, which is friendlier for bursty webhook patterns |

---

## Common Mistakes to Avoid

1. **Single delivery queue without endpoint isolation.** One slow endpoint (30s timeout, 429s) blocks workers from delivering to healthy endpoints. Always partition or tag by destination to prevent head-of-line blocking.

2. **Retrying indefinitely.** Unbounded retries for a dead endpoint consume queue space, worker capacity, and network bandwidth. During BFCM, this can cascade into system-wide delays. Set a retry budget and auto-disable.

3. **Using delivery attempt UUIDs as idempotency keys.** If the idempotency key changes on each retry, the consumer cannot deduplicate. The key must be deterministic: derived from (event_id, subscription_id), not from the delivery attempt.

4. **Synchronous fan-out in the event producer.** If the order service synchronously enqueues 50 webhook jobs before returning, order creation latency suffers. Fan-out must be fully async -- the order service publishes one event to Kafka, and a separate service handles fan-out.

5. **Ignoring HMAC secret rotation.** When an app rotates its shared secret, in-flight webhooks signed with the old secret will fail consumer verification. Support a dual-secret grace period or re-sign pending deliveries.

6. **Storing full response bodies in the delivery log.** A consumer returning a 5MB error page in their 500 response will bloat the log table. Truncate response bodies to 1KB and store only relevant debugging information.

7. **Flat priority during BFCM.** Treating order/created and product/updated with equal priority during a 100x spike means financial webhooks compete with catalog updates for worker capacity. Implement priority lanes for critical event types.

8. **No circuit breaker on failing endpoints.** Without circuit breakers, the system keeps hammering a dead endpoint, wasting timeout budget on every attempt. A circuit breaker skips delivery attempts during a cooldown, freeing workers for healthy endpoints.

9. **Coupling webhook schema to internal domain models.** If the webhook payload is a direct serialization of the internal Order model, any internal schema change breaks consumer integrations. Version webhook payloads independently with a stable API contract.

---

## Related Topics

- [[../../../05-async-processing/index|Async Processing]] -- job queues, retry strategies, dead letter queues, backpressure
- [[../../../03-scaling-writes/index|Scaling Writes]] -- high fan-out event delivery, Kafka partitioning
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- circuit breakers, exponential backoff, endpoint health tracking
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- at-least-once delivery, idempotency keys
- [[../../../08-api-gateway-and-service-mesh/index|API Gateway & Service Mesh]] -- rate limiting, authentication, request routing
- [[../../../07-real-time-systems/index|Real-Time Systems]] -- event-driven architecture, pub/sub patterns
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- delivery log partitioning, hot/cold storage tiering
