# Fault Tolerance & Reliability

In distributed systems, failures are not exceptional -- they are the norm. Network partitions, hardware failures, software bugs, and human errors will happen. The goal is not to prevent all failures but to build systems that **degrade gracefully** and **recover automatically**. The core patterns are **retries with backoff**, **idempotency**, **circuit breakers**, **bulkheads**, **health checks**, **self-healing**, **chaos engineering**, and **graceful degradation**. A Staff-level answer demonstrates layered defense and understanding that reliability is a system property, not a feature of any single component.

---

## Retries

Retries are the simplest fault tolerance mechanism: if a request fails, try again. But naive retries can amplify failures and create cascading problems.

### Exponential Backoff

Instead of retrying immediately, wait an exponentially increasing amount of time between attempts. This gives the failing service time to recover and avoids overwhelming it with retry storms.

```
Attempt 1: wait 1s
Attempt 2: wait 2s
Attempt 3: wait 4s
Attempt 4: wait 8s
(cap at max_delay)
```

### Jitter

If many clients fail simultaneously and all use the same backoff schedule, they will all retry at the same time -- creating a "thundering herd." Adding random jitter spreads retries over time.

```ruby
class RetryWithBackoff
  MAX_RETRIES = 5
  BASE_DELAY = 1.0  # seconds
  MAX_DELAY = 30.0

  def call(operation)
    retries = 0
    begin
      operation.call
    rescue RetryableError => e
      retries += 1
      raise if retries > MAX_RETRIES

      delay = [BASE_DELAY * (2 ** (retries - 1)), MAX_DELAY].min
      jittered_delay = delay * (0.5 + rand * 0.5)  # full jitter
      sleep(jittered_delay)
      retry
    end
  end
end
```

### Which Errors to Retry

Not all errors are retryable. Retrying a `400 Bad Request` (client error) will never succeed. Retrying a `429 Too Many Requests` or `503 Service Unavailable` likely will.

| Error Type | Retryable? | Example |
|---|---|---|
| Network timeout | Yes | Connection timeout, read timeout |
| 5xx server error | Yes (with caution) | 500, 502, 503, 504 |
| 429 rate limited | Yes (with backoff) | Too Many Requests |
| 4xx client error | No | 400, 401, 403, 404 |
| Connection refused | Maybe | Server might be restarting |

### Retry Budgets

Instead of a per-request retry limit, set a system-wide retry budget: "no more than 10% of total requests should be retries." This prevents retry amplification under widespread failures.

**Interview tip:** Always discuss retry budgets in system design. A naive retry policy with 3 retries can triple your traffic during a partial outage -- exactly when the downstream service can least handle it.

---

## Idempotency

An idempotent operation produces the same result whether executed once or multiple times. This is essential for systems that use at-least-once delivery (retries, message queues) because a message may be processed more than once.

### Idempotency Keys

The client generates a unique key for each logical operation and sends it with every request (including retries). The server checks whether it has already processed that key.

```ruby
class PaymentService
  def charge(idempotency_key:, amount:, account_id:)
    # Check if we already processed this request
    existing = IdempotencyRecord.find_by(key: idempotency_key)
    return existing.response if existing

    # Process the payment
    result = process_payment(amount: amount, account_id: account_id)

    # Store the result keyed by idempotency key
    IdempotencyRecord.create!(
      key: idempotency_key,
      response: result,
      expires_at: 24.hours.from_now
    )

    result
  end
end
```

### Implementation Strategies

**Database unique constraint:** Insert the idempotency key into a table with a unique constraint. If the insert fails (duplicate), the operation was already processed.

**Token-based:** The server issues a one-time-use token. The client submits the token with the request. The server atomically checks and invalidates the token.

**Natural idempotency:** Some operations are naturally idempotent: `SET balance = 100` is idempotent, `SET balance = balance + 10` is not. Design operations to be naturally idempotent when possible.

### Idempotency Window

Idempotency records should have a TTL. Storing them forever wastes space, and the likelihood of a duplicate request decreases rapidly after the initial operation.

---

## Circuit Breakers

A circuit breaker prevents a service from repeatedly calling a failing downstream dependency. It "trips" after a threshold of failures, short-circuiting calls for a cooling period before tentatively allowing traffic through again.

### State Machine

```
        failure threshold exceeded
CLOSED ─────────────────────────────> OPEN
  ^                                     |
  |                                     | timeout expires
  |     success threshold met           v
  └───────────────────────────── HALF-OPEN
                                    (allow limited traffic)
```

**CLOSED:** Normal operation. Requests flow through. Failures are counted.

**OPEN:** Requests fail immediately without calling the downstream service. This protects both the caller (fast failure, no hanging requests) and the downstream (no load during recovery).

**HALF-OPEN:** After a timeout, allow a limited number of requests through. If they succeed, transition back to CLOSED. If they fail, return to OPEN.

```ruby
class CircuitBreaker
  FAILURE_THRESHOLD = 5
  RESET_TIMEOUT = 30  # seconds
  SUCCESS_THRESHOLD = 3

  def initialize
    @state = :closed
    @failure_count = 0
    @success_count = 0
    @last_failure_time = nil
  end

  def call(&block)
    case @state
    when :open
      if Time.now - @last_failure_time > RESET_TIMEOUT
        @state = :half_open
        @success_count = 0
        try_call(&block)
      else
        raise CircuitOpenError, "Circuit is open, failing fast"
      end
    when :half_open
      try_call(&block).tap do
        @success_count += 1
        if @success_count >= SUCCESS_THRESHOLD
          @state = :closed
          @failure_count = 0
        end
      end
    when :closed
      try_call(&block)
    end
  end

  private

  def try_call(&block)
    block.call
  rescue StandardError => e
    record_failure
    raise
  end

  def record_failure
    @failure_count += 1
    @last_failure_time = Time.now
    @state = :open if @failure_count >= FAILURE_THRESHOLD
  end
end
```

### Circuit Breaker vs Retry

These patterns complement each other. Retries handle transient failures (a single blip). Circuit breakers handle sustained failures (the service is down). A typical pattern: retry 2-3 times with backoff, and if still failing, let the circuit breaker trip.

---

## Bulkheads

The bulkhead pattern isolates failures by partitioning resources so that a failure in one part does not cascade to others. Named after ship bulkheads that contain flooding to one compartment.

### Thread Pool Isolation

Assign separate thread pools to different downstream dependencies. If Service A is slow and exhausts its thread pool, Service B's threads are unaffected.

```
Application
  |
  +--> Thread Pool A (10 threads) --> Service A (slow/failing)
  |    (exhausted, but contained)
  |
  +--> Thread Pool B (10 threads) --> Service B (healthy)
       (still serving normally)
```

### Connection Pool Isolation

Similarly, separate database connection pools for different workloads (transactional vs analytics) prevent a slow query from exhausting connections needed for critical operations.

### Service Isolation

At the infrastructure level, deploy critical services on dedicated hosts/pods so they are not affected by noisy neighbors. Use Kubernetes resource limits and pod anti-affinity rules.

---

## Health Checks

Health checks allow infrastructure (load balancers, orchestrators, service meshes) to detect unhealthy instances and route traffic away from them.

### Types

**Liveness probe:** "Is the process alive?" -- checks that the process has not crashed or deadlocked. Failure triggers a restart.

**Readiness probe:** "Can the process serve traffic?" -- checks that dependencies (DB, cache) are accessible. Failure removes the instance from the load balancer but does not restart it.

**Startup probe:** "Has the process finished initialization?" -- prevents liveness/readiness checks from running before the app is ready (useful for slow-starting apps).

### Deep Health Checks

A shallow health check returns 200 if the process is running. A deep health check verifies connectivity to all critical dependencies (database, cache, downstream services). Deep checks are more accurate but can cascade failures if a dependency check blocks.

**Best practice:** Use shallow checks for liveness (restart quickly) and deep checks for readiness (stop sending traffic until dependencies recover).

---

## Self-Healing

Self-healing systems automatically detect and recover from failures without human intervention.

### Mechanisms

- **Process restarts** -- Kubernetes restarts crashed containers automatically based on liveness probes
- **Auto-scaling** -- replace failed instances with new ones; scale up when load increases
- **Automatic failover** -- database primary fails, promote a replica automatically (Patroni, RDS Multi-AZ)
- **Configuration drift detection** -- tools like Puppet/Chef detect when configuration diverges from desired state and correct it
- **Queue replay** -- failed messages go to DLQ; after fixing the bug, replay them automatically

### Kubernetes Self-Healing Example

```
Pod crashes -> kubelet detects via liveness probe
  -> kubelet restarts container (up to restart backoff limit)
  -> if node fails, scheduler reschedules pod to healthy node
  -> readiness probe fails -> pod removed from service endpoints
  -> HPA detects CPU/memory pressure -> scales up replica count
```

---

## Chaos Engineering

Chaos engineering is the practice of intentionally injecting failures into production (or staging) systems to verify that fault tolerance mechanisms work as expected.

### Principles

1. **Start with a hypothesis** -- "If we kill 30% of pods, latency stays under 200ms"
2. **Minimize blast radius** -- start small (single instance), expand gradually
3. **Run in production** -- staging environments often do not reflect real failure modes
4. **Automate** -- chaos experiments should be repeatable and scheduled

### Common Experiments

| Experiment | What It Tests |
|---|---|
| Kill a pod/instance | Process restart, load balancer failover |
| Inject network latency | Timeout handling, circuit breakers |
| Partition a network | Replica failover, split-brain handling |
| Fill disk | Alerting, log rotation, graceful degradation |
| CPU stress | Auto-scaling, priority scheduling |
| Kill a database primary | Automatic failover, read replica promotion |

### Tools

- **Chaos Monkey** (Netflix) -- randomly kills instances in production
- **Litmus Chaos** -- Kubernetes-native chaos engineering
- **Gremlin** -- managed chaos engineering platform
- **Toxiproxy** -- Shopify's proxy for simulating network conditions

---

## Graceful Degradation

When a non-critical dependency fails, the system should continue to serve its core function with reduced capability rather than failing entirely.

### Strategies

**Feature flags:** Disable non-critical features when their dependencies are unhealthy.

**Fallback responses:** Return cached data, default values, or reduced-quality results instead of errors.

**Priority-based shedding:** Under extreme load, shed low-priority requests to protect high-priority ones.

```ruby
class ProductService
  def get_product(id)
    product = fetch_from_db(id)

    # Non-critical: recommendations
    product.recommendations = begin
      recommendation_service.get(id)
    rescue CircuitOpenError, Timeout::Error
      []  # Degrade: show product without recommendations
    end

    # Non-critical: reviews
    product.reviews = begin
      review_service.get(id)
    rescue CircuitOpenError, Timeout::Error
      cached_reviews(id) || []  # Degrade: show cached or no reviews
    end

    product
  end
end
```

**Interview tip:** Always identify which parts of the system are *critical* (must work) vs *nice-to-have* (can degrade). A product page without recommendations is acceptable; a product page that fails entirely is not. Design each dependency call with a fallback.

---

## Timeouts

Timeouts are a fundamental reliability mechanism that prevent a slow or unresponsive dependency from consuming resources indefinitely.

### Types

- **Connection timeout** -- how long to wait to establish a connection (typically 1-5s)
- **Read/request timeout** -- how long to wait for a response after connecting (varies by operation)
- **Idle timeout** -- how long to keep an unused connection open

### Setting Timeouts

Timeouts should be based on the p99 latency of the downstream service plus a margin. Too short: false timeouts under normal load. Too long: resources are held too long during failures.

**Cascading timeouts:** If Service A calls B calls C, A's timeout must be greater than B's timeout plus overhead. Otherwise A times out before B gets a response from C, and the work is wasted.

```
Service A (timeout: 5s) -> Service B (timeout: 3s) -> Service C (timeout: 1s)
```

---

## Putting It Together: Defense in Depth

A reliable system uses multiple layers of fault tolerance:

```
Layer 1: API Gateway
  - Rate limiting (prevent overload)
  - Timeout enforcement

Layer 2: Service Level
  - Circuit breakers (protect against failing dependencies)
  - Bulkheads (isolate failures)
  - Retries with backoff and jitter (handle transient failures)
  - Timeouts (prevent resource exhaustion)

Layer 3: Data Level
  - Idempotency (safe retries)
  - WAL / durable queues (prevent data loss)
  - Dead letter queues (handle poison messages)

Layer 4: Infrastructure
  - Health checks (detect unhealthy instances)
  - Auto-scaling (replace failed instances)
  - Self-healing (automatic recovery)
  - Chaos engineering (verify all of the above works)

Layer 5: Organizational
  - Runbooks (human response for novel failures)
  - On-call rotation
  - Post-incident reviews (learn and improve)
```

---

## Related Topics

- [[../async-processing/index|Async Processing]] -- DLQs, retry policies for queue consumers
- [[../distributed-systems-fundamentals/index|Distributed Systems]] -- partition tolerance, consensus under failure
- [[../api-gateway-and-service-mesh/index|API Gateway & Service Mesh]] -- rate limiting, health checks at the edge
- [[../databases-and-storage/index|Databases & Storage]] -- replication, failover, consistency under failure
- [[../scaling-reads/index|Scaling Reads]] -- cache failure handling, replica failover
