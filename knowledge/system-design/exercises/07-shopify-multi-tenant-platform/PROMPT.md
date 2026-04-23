# Exercise: Design a Multi-Tenant E-Commerce Platform (Shopify)

## Prompt

Design the multi-tenant architecture for a platform like Shopify that hosts millions of online stores on shared infrastructure. The system must isolate tenants from each other (noisy neighbor prevention), scale horizontally, and support zero-downtime migration of shops between infrastructure pods -- all while keeping per-merchant costs low.

## Requirements

### Functional Requirements
- Tenant (shop) provisioning and onboarding
- Pod-based tenant isolation (groups of shops on dedicated datastores)
- Zero-downtime shop migration between pods (rebalancing)
- Per-tenant resource limits and rate limiting
- Per-tenant custom domain routing
- Tenant-specific configuration (themes, payment providers, shipping rules)
- Admin dashboard with per-tenant metrics

### Non-Functional Requirements
- Support millions of tenants on shared infrastructure
- No single tenant can degrade the platform for others (noisy neighbor prevention)
- Zero-downtime during shop migrations between pods
- Linear horizontal scaling by adding pods
- Sub-second request routing to the correct pod
- Cost-efficient: small merchants share resources, large merchants get dedicated capacity

### Out of Scope (clarify with interviewer)
- Storefront rendering and theme engine
- App ecosystem and third-party integrations
- Billing and subscription management
- Merchant onboarding UX

## Constraints
- Pod architecture: each pod is a self-contained unit (app servers + database + cache)
- Shop-to-pod mapping must be fast and consistent
- Rebalancing happens regularly as shops grow/shrink
- Shopify uses Ghostferry for zero-downtime MySQL-to-MySQL data migration
- Some merchants (enterprise) need dedicated pods; most share
- Ruby/Rails monolith with Packwerk for module boundaries

## Key Topics Tested
- [[../../databases-and-storage/index|Databases & Storage]] -- data partitioning, sharding strategies
- [[../../scaling-reads/index|Scaling Reads]] -- per-tenant caching, read replicas
- [[../../scaling-writes/index|Scaling Writes]] -- write isolation, pod-based scaling
- [[../../distributed-systems-fundamentals/index|Distributed Systems]] -- consistent hashing, data migration
