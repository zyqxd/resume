# Exercise: Design a Webhook Delivery System (Shopify)

## Prompt

Design a webhook delivery system for an e-commerce platform like Shopify that reliably delivers event notifications to thousands of third-party app endpoints. The system must guarantee at-least-once delivery, handle endpoint failures gracefully, and scale to billions of webhook deliveries per day during peak events like BFCM.

## Requirements

### Functional Requirements
- Event subscription management (apps subscribe to event types per merchant)
- At-least-once delivery guarantee for all webhook events
- Retry with exponential backoff and jitter on delivery failure
- Dead letter queue for persistently failing endpoints
- Idempotency keys so consumers can deduplicate
- Webhook payload signing (HMAC) for authenticity verification
- Delivery status tracking and merchant-visible logs
- Rate limiting per destination endpoint

### Non-Functional Requirements
- Billions of deliveries per day during BFCM
- Sub-second delivery latency for 95% of webhooks under normal load
- Fan-out: a single event may trigger webhooks to hundreds of app endpoints
- Handle slow/unresponsive endpoints without blocking other deliveries
- 99.9% delivery success rate (eventual delivery with retries)
- Webhook payload size up to 64KB

### Out of Scope (clarify with interviewer)
- App installation and OAuth flow
- Webhook subscription UI
- Real-time streaming alternative (GraphQL subscriptions)
- Webhook transformation or filtering

## Constraints
- Thousands of third-party apps with varying endpoint reliability
- Events per second spike 100x during BFCM
- Consumer endpoints have wildly different response times (10ms to 30s)
- Must not retry indefinitely -- disable webhooks for persistently failing endpoints
- PII in webhook payloads requires encryption in transit

## Key Topics Tested
- [[../../async-processing/index|Async Processing]] -- job queues, retry strategies, dead letter queues
- [[../../scaling-writes/index|Scaling Writes]] -- high fan-out event delivery
- [[../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- circuit breakers, backpressure, endpoint health tracking
- [[../../distributed-systems-fundamentals/index|Distributed Systems]] -- at-least-once delivery, idempotency
