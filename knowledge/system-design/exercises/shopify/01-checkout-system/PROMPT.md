# Exercise: Design a Checkout System (Shopify)

## Prompt

Design a checkout system for a large e-commerce platform like Shopify that handles millions of merchants. The system must process orders reliably under extreme traffic (Black Friday/Cyber Monday scale), never double-charge customers, and never lose orders -- even during partial failures.

## Requirements

### Functional Requirements
- Cart-to-order state machine (cart -> checkout -> payment -> order confirmation)
- Idempotent order creation -- retries never create duplicate orders
- Payment gateway integration with PCI-compliant token isolation
- Multi-currency and multi-payment-method support
- Tax calculation at checkout time
- Discount and promotion code application
- Shipping rate calculation and method selection
- Order confirmation and receipt generation

### Non-Functional Requirements
- Sub-200ms checkout latency at p99
- Zero double-charges (exactly-once payment semantics)
- Zero lost orders during failures
- Handle 10x normal traffic during flash sales (BFCM: 284M requests/minute at edge)
- 99.99% availability during peak events
- PCI DSS compliance -- card data never touches the main application

### Out of Scope (clarify with interviewer)
- Post-purchase flows (shipping, fulfillment, returns)
- Fraud detection and prevention (mention as hook point)
- Subscription/recurring billing
- Cart persistence and abandonment recovery
- Analytics and reporting

## Constraints
- Millions of merchants on a shared multi-tenant platform
- Thousands of concurrent checkouts per second during peak
- Multiple payment providers (Stripe, PayPal, Shop Pay, etc.)
- Global user base across all timezones
- Must degrade gracefully -- partial checkout is better than no checkout

## Key Topics Tested
- [[../../../scaling-writes/index|Scaling Writes]] -- idempotent writes, exactly-once semantics
- [[../../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- graceful degradation, circuit breakers
- [[../../../async-processing/index|Async Processing]] -- payment processing, order finalization
- [[../../../distributed-systems-fundamentals/index|Distributed Systems]] -- distributed transactions, saga pattern
