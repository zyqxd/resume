# Exercise: Design a Real-Time Inventory Management System (Shopify)

## Prompt

Design a real-time inventory management system for a multi-tenant e-commerce platform like Shopify. The system must track stock levels across multiple warehouses, prevent overselling during concurrent purchases, and synchronize inventory across sales channels (online store, POS, marketplace integrations) -- all while supporting flash sale traffic.

## Requirements

### Functional Requirements
- Real-time stock level tracking per SKU per warehouse location
- Reservation-based inventory allocation (reserve on add-to-cart or checkout, release on timeout)
- Multi-warehouse stock aggregation and fulfillment routing
- Oversell prevention under high concurrency
- Inventory sync across sales channels (online, POS, Amazon, eBay)
- Low-stock and out-of-stock alerts for merchants
- Bulk inventory updates (CSV imports, API batch updates)
- Inventory audit log (who changed what, when)

### Non-Functional Requirements
- Strong consistency for inventory decrements (no overselling)
- Eventual consistency acceptable for read-side stock display
- Handle thousands of concurrent reservation requests per popular SKU
- Sub-100ms for inventory check and reservation
- 99.99% availability for the reservation path
- Support merchants with 100K+ SKUs

### Out of Scope (clarify with interviewer)
- Warehouse management (picking, packing, shipping)
- Demand forecasting and reorder suggestions
- Product catalog management
- Returns and restocking flow

## Constraints
- Multi-tenant: millions of merchants sharing infrastructure
- Some SKUs have single-digit stock (limited drops) with thousands of concurrent buyers
- Must handle BFCM-level concurrency spikes
- Reservation TTL must balance holding time vs. cart abandonment
- Cross-channel sync has inherent latency (POS may be offline)

## Key Topics Tested
- [[../../../scaling-writes/index|Scaling Writes]] -- high-contention writes, optimistic vs pessimistic locking
- [[../../../databases-and-storage/index|Databases & Storage]] -- consistency models, ACID guarantees
- [[../../../distributed-systems-fundamentals/index|Distributed Systems]] -- eventual consistency, conflict resolution
- [[../../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- handling partial failures, TTL-based self-healing
