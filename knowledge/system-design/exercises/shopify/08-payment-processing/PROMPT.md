# Exercise: Design a Payment Processing Pipeline (Shopify)

## Prompt

Design a payment processing pipeline for an e-commerce platform like Shopify that handles billions of dollars in transactions across multiple payment providers. The system must guarantee exactly-once payment semantics (never double-charge), isolate PCI scope from the main application, and support multi-provider failover -- all while maintaining sub-second payment processing times.

## Requirements

### Functional Requirements
- Payment tokenization: card details captured in isolated PCI-scoped service, only tokens flow through main system
- Exactly-once payment semantics via idempotency (Resumption pattern)
- Multi-gateway support with automatic failover (Stripe, PayPal, Adyen, etc.)
- Payment state machine (authorize -> capture -> settle, with void and refund paths)
- Multi-currency support with exchange rate handling
- Partial captures and split payments
- Refund processing (full and partial)
- Payment method storage (vaulting) for returning customers

### Non-Functional Requirements
- Sub-second payment authorization latency at p99
- Zero double-charges (exactly-once semantics even under retries and failures)
- PCI DSS Level 1 compliance -- card data never touches the Rails monolith
- 99.99% availability for the payment path
- Handle thousands of concurrent payment authorizations
- Audit trail for every payment state transition

### Out of Scope (clarify with interviewer)
- Fraud detection and risk scoring (mention as hook point)
- Subscription and recurring billing
- Payout to merchants (settlement)
- Tax calculation and remittance
- Chargeback and dispute management

## Constraints
- CardSink/CardServer architecture: isolated iframe captures card data, separate PCI-scoped service tokenizes it
- Main Rails monolith only sees payment tokens, never raw card numbers
- Payment providers have different APIs, latencies, and failure modes
- Must handle provider-specific retry semantics (some are safe to retry, some are not)
- Regional routing: prefer local payment providers for lower latency and fees
- Circuit breakers per provider per region (Semian pattern)

## Key Topics Tested
- [[../../../distributed-systems-fundamentals/index|Distributed Systems]] -- exactly-once semantics, idempotency, distributed state machines
- [[../../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- circuit breakers, multi-provider failover, graceful degradation
- [[../../../async-processing/index|Async Processing]] -- payment state machine, event-driven settlement
- [[../../../databases-and-storage/index|Databases & Storage]] -- audit logging, transaction guarantees
