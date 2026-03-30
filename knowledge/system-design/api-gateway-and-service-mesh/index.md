# API Gateway & Service Mesh

API gateways and service meshes manage traffic flow in distributed architectures. The **API gateway** sits at the edge, handling external traffic -- authentication, rate limiting, routing, and protocol translation. The **service mesh** operates internally, managing service-to-service communication -- load balancing, mTLS, observability, and retries. Together, they provide a layered traffic management architecture. This section covers **load balancing strategies**, **rate limiting algorithms**, **service discovery**, **API gateway patterns**, **sidecar proxy**, **mTLS**, and **observability**. These are common interview topics because they reveal understanding of production system operations.

---

## Load Balancing Strategies

Load balancing distributes incoming requests across multiple instances of a service. The algorithm choice affects latency, fairness, and utilization.

### Layer 4 vs Layer 7

- **Layer 4 (Transport):** Routes based on IP and port. Cannot inspect HTTP content. Very fast (kernel-level). Used for TCP load balancing, WebSocket connections.
- **Layer 7 (Application):** Routes based on HTTP headers, URL paths, cookies. Can make content-aware routing decisions. Slightly higher overhead but much more flexible.

### Algorithms

| Algorithm | Description | Best For |
|---|---|---|
| **Round Robin** | Rotate through instances sequentially | Homogeneous instances, equal request cost |
| **Weighted Round Robin** | Assign weights based on instance capacity | Heterogeneous instances (different CPU/memory) |
| **Least Connections** | Route to instance with fewest active connections | Varying request duration |
| **Least Response Time** | Route to instance with lowest latency | Latency-sensitive workloads |
| **Random** | Pick a random instance | Simple, surprisingly effective |
| **Consistent Hashing** | Hash request key to an instance | Sticky sessions, cache affinity |
| **Power of Two Random Choices (P2C)** | Pick two random instances, route to the one with fewer connections | High throughput, good balance |

### Power of Two Random Choices

P2C is worth understanding because it provides near-optimal load distribution with minimal coordination:

1. Pick two random backend instances
2. Route the request to whichever has fewer active connections

This avoids the thundering herd problem of least-connections (where all LBs route to the same instance that just freed up) and performs significantly better than pure random. Used by Envoy, HAProxy.

### Health-Aware Load Balancing

Remove unhealthy instances from the rotation. Combine with outlier detection: if an instance has an elevated error rate or latency compared to peers, temporarily eject it.

---

## Rate Limiting Algorithms

Rate limiting protects services from overload, prevents abuse, and enforces fair usage. The choice of algorithm determines the granularity and behavior of the limit.

### Token Bucket

A bucket holds tokens (up to a maximum capacity). Each request consumes one token. Tokens are replenished at a fixed rate. If the bucket is empty, requests are rejected (or queued).

```
Capacity: 10 tokens
Refill rate: 2 tokens/second

Time 0: 10 tokens (full)
Request burst of 8: 2 tokens remaining
After 1s: 4 tokens (2 replenished)
After 5s: 10 tokens (capped at capacity)
```

**Pros:** Allows bursts up to bucket capacity. Smooth rate enforcement. Simple to implement.

```ruby
class TokenBucket
  def initialize(capacity:, refill_rate:)
    @capacity = capacity
    @refill_rate = refill_rate  # tokens per second
    @tokens = capacity.to_f
    @last_refill = Time.now
  end

  def allow?
    refill
    if @tokens >= 1
      @tokens -= 1
      true
    else
      false
    end
  end

  private

  def refill
    now = Time.now
    elapsed = now - @last_refill
    @tokens = [@tokens + elapsed * @refill_rate, @capacity].min
    @last_refill = now
  end
end
```

### Sliding Window Log

Track the timestamp of each request in a sorted set. To check the rate, count requests within the window [now - window_size, now]. If the count exceeds the limit, reject.

**Pros:** Precise, no boundary issues. **Cons:** Memory-intensive (stores every request timestamp). O(log N) per operation.

### Sliding Window Counter

Hybrid of fixed window and sliding window. Maintain counters for the current and previous fixed windows. Estimate the sliding window count using a weighted sum:

```
count = previous_window_count * overlap_ratio + current_window_count

Example: window = 60s, current window started 40s ago
overlap_ratio = (60 - 40) / 60 = 0.33
estimated_count = prev_count * 0.33 + curr_count
```

**Pros:** Memory-efficient (two counters per window). Reasonably accurate. **Cons:** Approximate.

### Fixed Window Counter

Count requests in fixed time windows (e.g., per minute). Simple but has a boundary problem: a burst at the end of one window and start of the next can exceed the intended rate.

### Comparison

| Algorithm | Accuracy | Memory | Burst Handling |
|---|---|---|---|
| Token Bucket | Good | O(1) | Allows controlled bursts |
| Sliding Window Log | Exact | O(N) per user | Precise |
| Sliding Window Counter | Approximate | O(1) | Approximate |
| Fixed Window | Approximate | O(1) | Boundary problem |

### Distributed Rate Limiting

In a multi-instance deployment, rate limits must be coordinated. Options:

- **Centralized store (Redis):** All instances check/increment a shared counter. Adds a network hop per request. Most common approach.
- **Local estimation:** Each instance tracks its share of the rate limit (total_limit / num_instances). Approximate but no coordination overhead.
- **Gossip-based:** Instances periodically share their local counts and adjust. Eventually consistent.

---

## Service Discovery

In dynamic environments (Kubernetes, cloud), service instances are created and destroyed constantly. Service discovery provides a way for clients to find available instances.

### Client-Side Discovery

The client queries a service registry to get a list of available instances and load balances across them.

```
Client -> Service Registry: "Where is Service B?"
Registry -> Client: ["10.0.1.5:8080", "10.0.1.6:8080", "10.0.1.7:8080"]
Client -> 10.0.1.6:8080 (chosen by client-side LB)
```

**Examples:** Netflix Eureka + Ribbon, Consul + client library.

### Server-Side Discovery

The client sends requests to a load balancer or API gateway, which handles discovery and routing.

```
Client -> Load Balancer: request for Service B
LB -> Service Registry: "Where is Service B?"
LB -> 10.0.1.6:8080 (chosen by LB)
```

**Examples:** Kubernetes Services (kube-proxy), AWS ELB + ECS.

### DNS-Based Discovery

Services register with DNS. Clients resolve the service name to one or more IP addresses. Simple but has TTL-based caching issues (stale entries after instance termination).

**Examples:** Kubernetes DNS (CoreDNS), Consul DNS interface.

### Kubernetes Service Discovery

Kubernetes provides built-in service discovery:
- **ClusterIP Service:** Virtual IP that load-balances across pods (kube-proxy)
- **Headless Service:** Returns pod IPs directly (for client-side LB or StatefulSets)
- **DNS resolution:** `service-name.namespace.svc.cluster.local`

---

## API Gateway Patterns

An API gateway is the single entry point for external clients. It handles cross-cutting concerns that would otherwise be duplicated across every service.

### Core Responsibilities

```
External Client
       |
       v
  +-----------+
  | API       |
  | Gateway   |  Authentication, Rate Limiting, TLS termination,
  |           |  Request routing, Protocol translation,
  |           |  Response caching, Request/response transformation
  +-----------+
       |
   +---+---+---+
   |   |   |   |
  Svc Svc Svc Svc
   A   B   C   D
```

### Backend for Frontend (BFF)

Instead of one monolithic gateway, create a gateway per client type (web, mobile, IoT). Each BFF is optimized for its client's data needs and can aggregate/transform responses accordingly.

```
Web Client    Mobile Client    IoT Devices
     |              |              |
  +--v--+      +---v---+     +---v---+
  |Web  |      |Mobile |     | IoT   |
  | BFF |      |  BFF  |     |  BFF  |
  +--+--+      +---+---+     +---+---+
     |              |              |
     +------+-------+--------------+
            |
      Microservices
```

**When to use BFF:** When different clients have significantly different data requirements. The web app might need full product details; the mobile app might need a compact summary.

### Gateway Aggregation

The gateway fetches data from multiple services and combines them into a single response, reducing the number of round trips for the client.

```
Client: GET /product/123
Gateway:
  -> Product Service: GET /products/123
  -> Review Service: GET /reviews?product=123
  -> Inventory Service: GET /inventory/123
  Aggregate results
  -> Client: { product: {...}, reviews: [...], stock: 42 }
```

**Trade-off:** The gateway becomes more complex and tightly coupled to backend services. Consider GraphQL as an alternative for flexible aggregation.

---

## Sidecar Proxy Pattern

In a service mesh, a sidecar proxy is deployed alongside each service instance. All inbound and outbound traffic flows through the proxy, which handles networking concerns transparently.

### Architecture

```
+------------------------+     +------------------------+
| Pod A                  |     | Pod B                  |
|  +-------+ +--------+ |     |  +-------+ +--------+ |
|  |Service| |Sidecar | |     |  |Sidecar| |Service | |
|  |  A    |->|Proxy A |----->|  |Proxy B|->|  B     | |
|  +-------+ +--------+ |     |  +-------+ +--------+ |
+------------------------+     +------------------------+
                    \               /
                     \             /
                   +--v-----------v--+
                   |  Control Plane  |
                   | (Istio, Linkerd)|
                   +-----------------+
```

### What the Sidecar Handles

- **mTLS:** Automatic mutual TLS encryption between services
- **Load balancing:** Client-side load balancing with health-aware routing
- **Retries and timeouts:** Configurable retry policies per route
- **Circuit breaking:** Eject unhealthy instances
- **Observability:** Emit metrics, traces, and logs for all traffic
- **Traffic shaping:** Canary deployments, A/B testing, fault injection

### Service Mesh Options

| Mesh | Proxy | Control Plane | Notable Feature |
|---|---|---|---|
| **Istio** | Envoy | istiod | Most feature-rich, complex |
| **Linkerd** | linkerd2-proxy (Rust) | Control plane | Lightweight, simpler |
| **Consul Connect** | Envoy or built-in | Consul server | Multi-platform |
| **Cilium** | eBPF (no sidecar) | Cilium agent | Kernel-level, lowest overhead |

**Trade-off:** Service meshes add latency (every request traverses two proxies) and operational complexity. Cilium's eBPF approach avoids the sidecar overhead by operating at the kernel level.

---

## mTLS (Mutual TLS)

Standard TLS: the client verifies the server's identity. Mutual TLS: both the client and server verify each other's identity using certificates. This provides authentication (who is calling) and encryption (confidentiality) for service-to-service communication.

### Certificate Management

In a service mesh, the control plane acts as a certificate authority (CA):
1. Issues short-lived certificates to each service
2. Automatically rotates certificates before expiry
3. Services never manage certificates manually

**Without a service mesh:** Use tools like cert-manager (Kubernetes), Vault PKI, or SPIFFE/SPIRE for identity and certificate issuance.

### Zero-Trust Networking

mTLS enables zero-trust networking: no implicit trust based on network location. Every service must authenticate itself, even within the same cluster. This is increasingly required for compliance (SOC2, PCI-DSS).

---

## Observability

Observability is the ability to understand the internal state of a system from its external outputs. The three pillars are **metrics**, **logs**, and **traces**.

### Metrics

Numerical measurements over time. Used for alerting, dashboards, and capacity planning.

- **RED method** (for services): Rate, Errors, Duration
- **USE method** (for resources): Utilization, Saturation, Errors
- **Golden signals** (Google SRE): Latency, Traffic, Errors, Saturation

**Tools:** Prometheus + Grafana, Datadog, CloudWatch.

### Logs

Structured event records. Used for debugging and audit trails.

**Best practices:** Use structured logging (JSON), include correlation IDs (trace IDs), centralize logs (ELK stack, Loki, Datadog Logs).

### Distributed Tracing

Follows a request across multiple services, showing the full call chain and timing. Essential for debugging latency issues in microservices.

```
Trace ID: abc-123
  ├── API Gateway (5ms)
  │   ├── Auth Service (2ms)
  │   └── Product Service (15ms)
  │       ├── Database Query (8ms)
  │       └── Cache Lookup (1ms)
  └── Total: 20ms
```

**Tools:** Jaeger, Zipkin, Datadog APM, OpenTelemetry (the emerging standard for instrumentation).

### OpenTelemetry

OpenTelemetry is the convergence of OpenTracing and OpenCensus into a single, vendor-neutral standard for metrics, logs, and traces. It provides SDKs for instrumentation and a collector for exporting telemetry to any backend.

**Interview tip:** When discussing observability, mention OpenTelemetry as the modern standard. It avoids vendor lock-in and provides consistent instrumentation across languages and frameworks.

---

## Putting It Together

```
External traffic enters the system:
  -> API Gateway: auth, rate limiting, routing, TLS termination
    -> Service Mesh (sidecar proxies): mTLS, LB, retries, circuit breaking, tracing
      -> Service: business logic
        -> Downstream services (via mesh): same mesh guarantees

Observability at every layer:
  - Gateway: request rate, error rate, latency per route
  - Mesh: per-service metrics, distributed traces
  - Service: application metrics, structured logs
```

---

## Related Topics

- [[../fault-tolerance-and-reliability/index|Fault Tolerance]] -- circuit breakers, retries, health checks
- [[../scaling-reads/index|Scaling Reads]] -- CDN as an edge caching layer
- [[../distributed-systems-fundamentals/index|Distributed Systems]] -- service discovery, coordination
- [[../async-processing/index|Async Processing]] -- rate limiting as backpressure
- [[../ml-ai-infrastructure/index|ML/AI Infrastructure]] -- model serving behind API gateways
