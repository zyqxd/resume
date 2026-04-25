# Exercise: Design a Product Search and Discovery System (Shopify)

## Prompt

Design a product search system for a multi-tenant e-commerce platform like Shopify. The system must support full-text search across millions of merchants' product catalogs, handle variant-aware indexing (size, color, material), and provide fast autocomplete and faceted filtering -- all while maintaining per-store isolation and real-time index updates when products change.

## Requirements

### Functional Requirements
- Full-text search across product titles, descriptions, tags, and variant attributes
- Autocomplete / typeahead suggestions (< 100ms)
- Faceted filtering (price range, color, size, availability, etc.)
- Variant-aware search (a product with 100 size/color combos is one product, not 100)
- Per-merchant search isolation (search only returns results from the current store)
- Real-time index updates when products are created, updated, or deleted
- Relevance ranking with merchant-customizable boosting rules
- Multi-language support

### Non-Functional Requirements
- Sub-200ms search latency at p99
- Handle 100K+ search queries per second during BFCM
- Support merchants with catalogs of 100K+ products
- Index updates visible within 5 seconds of product change
- Highly available -- search degradation is acceptable, total outage is not

### Out of Scope (clarify with interviewer)
- AI/ML-powered recommendations (mention as extension)
- Visual search (search by image)
- Search analytics and A/B testing
- Personalized search results based on user behavior

## Constraints
- Multi-tenant: millions of merchants, each with isolated search results
- Product variants create fan-out in indexing (1 product = many searchable attributes)
- Merchants can customize relevance (boost by "new arrival", "best seller", etc.)
- Must handle catalog sizes from 5 products to 500K products
- Shopify uses Elasticsearch-style search infrastructure

## Key Topics Tested
- [[../../../scaling-reads/index|Scaling Reads]] -- search index scaling, caching, read replicas
- [[../../../databases-and-storage/index|Databases & Storage]] -- inverted indexes, search engines, data modeling
- [[../../../async-processing/index|Async Processing]] -- real-time index updates, change data capture
- [[../../../distributed-systems-fundamentals/index|Distributed Systems]] -- multi-tenant data isolation, eventual consistency
