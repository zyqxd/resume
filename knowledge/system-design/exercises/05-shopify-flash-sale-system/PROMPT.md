# Exercise: Design a Flash Sale / BFCM Traffic Handling System (Shopify)

## Prompt

Design a system that allows an e-commerce platform like Shopify to handle extreme traffic spikes during flash sales and Black Friday/Cyber Monday events. The system must protect backend services from overload while ensuring that legitimate buyers can complete purchases, and that inventory is allocated fairly.

## Requirements

### Functional Requirements
- Queue-based admission control during traffic spikes
- Per-SKU inventory reservation with TTL (abandoned reservations expire)
- Load shedding that degrades gracefully (static pages > dynamic > checkout last to shed)
- Pre-warming infrastructure before known events
- Real-time merchant dashboard showing sales velocity
- Fair ordering -- first-come-first-served for limited inventory

### Non-Functional Requirements
- Handle 100x normal traffic within minutes (BFCM 2024: 284M req/min at edge)
- Sub-second page loads during peak (storefront reads)
- Checkout availability never drops below 99.9% during events
- 10.5 trillion database queries over event weekend
- Zero overselling of limited inventory
- Pod-based horizontal scaling (Shopify's architecture)

### Out of Scope (clarify with interviewer)
- CDN and edge caching strategy (mention as given)
- Fraud detection during high-traffic events
- Post-purchase fulfillment
- Marketing and promotional tooling
- Bot detection and prevention

## Constraints
- Multi-tenant platform: millions of merchants, some running flash sales simultaneously
- Pod-based architecture: isolated groups of shops on dedicated datastores
- Must support both planned events (BFCM) and unplanned viral spikes
- Ruby/Rails monolith with extracted storefront for read scaling
- Load testing with Genghis (internal tool) and chaos engineering via Toxiproxy

## Key Topics Tested
- [[../../scaling-reads/index|Scaling Reads]] -- caching, CDN, read replicas
- [[../../scaling-writes/index|Scaling Writes]] -- queue-based writes, backpressure
- [[../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- load shedding, circuit breakers (Semian), graceful degradation
- [[../../async-processing/index|Async Processing]] -- queue-based inventory allocation
