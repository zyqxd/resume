# Exercise: Design a Rate Limiting System for APIs (Shopify)

## Prompt

Design a rate limiting system for a multi-tenant e-commerce platform's API like Shopify's GraphQL Admin API. The system must support cost-based rate limiting (where different queries consume different amounts of quota based on complexity), enforce per-app and per-merchant limits, and operate in a distributed multi-pod architecture without a single point of failure.

## Requirements

### Functional Requirements
- Cost-based rate limiting for GraphQL (static query complexity analysis before execution)
- Per-app, per-merchant rate limit buckets
- Token bucket / leaky bucket implementation (50 points/second, up to 1,000 point burst)
- Query cost estimation returned in API response headers
- Throttle status in response (remaining quota, restore rate, retry-after)
- Rate limit override for specific apps/merchants (partner tier)
- Graceful 429 responses with clear error messages

### Non-Functional Requirements
- Sub-millisecond rate limit check latency (on the hot path for every request)
- Distributed enforcement across multiple pods and regions
- No single point of failure -- degrade to permissive rather than blocking all traffic
- Consistent enforcement -- small windows of over-admission are acceptable, large bursts are not
- Handle 100K+ API requests per second

### Out of Scope (clarify with interviewer)
- DDoS protection (network-level rate limiting)
- Bot detection and CAPTCHA
- API authentication and OAuth
- Usage-based billing

## Constraints
- Multi-pod architecture: rate limits must be enforced across pods
- GraphQL queries vary wildly in cost (simple field lookup vs. nested connection with 250 items)
- Thousands of third-party apps, each with different rate limit tiers
- Must work with both REST and GraphQL APIs
- Redis-based distributed counters (common at Shopify scale)
- Trade-off: strict global consistency vs. low latency

## Key Topics Tested
- [[../../../distributed-systems-fundamentals/index|Distributed Systems]] -- distributed counters, consistency trade-offs
- [[../../../scaling-reads/index|Scaling Reads]] -- Redis, in-memory state, caching
- [[../../../api-gateway-and-service-mesh/index|API Gateway]] -- request routing, middleware, throttling
- [[../../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- fail-open vs fail-closed, degraded mode
