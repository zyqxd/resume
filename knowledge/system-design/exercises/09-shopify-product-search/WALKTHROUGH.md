# Walkthrough: Design a Product Search and Discovery System (Shopify)

## Step 1: Clarify Requirements and Scope

Before drawing anything, pin down the multi-tenancy and scale constraints with the interviewer:
- How many merchants and what catalog sizes? (Millions of merchants. Most have < 1K products, but some power merchants have 500K+. This bimodal distribution drives the indexing strategy.)
- Is search per-store or cross-store? (Per-store only -- a customer on store A never sees store B's products. This is a hard isolation requirement.)
- What's the latency budget? (Sub-200ms p99 for search, sub-100ms for autocomplete. During BFCM, 100K+ QPS.)
- How fast must product changes appear in search? (Within 5 seconds -- near real-time, not batch.)
- Multi-language? (Yes -- merchants operate in 50+ languages. Search must use language-specific analysis.)
- Can merchants customize relevance? (Yes -- boost "new arrivals," "best sellers," custom tags.)

The scoping reveals this is fundamentally a **multi-tenant search infrastructure problem**, not a single-tenant search problem scaled up. Tenant isolation, per-merchant configuration, and extreme variance in catalog sizes are the hard parts.

---

## Step 2: High-Level Architecture

```
Storefront Clients (Browser/Mobile)
    |
    | HTTPS (per-merchant domain)
    v
+-------------------+
| API Gateway /     |  (tenant identification, rate limiting, routing)
| Edge Proxy        |
+--------+----------+
         |
    +----v----+
    | Search  |  (query parsing, fan-out to ES, result assembly)
    | Service |
    +----+----+
         |
    +----v-----------------------+------------------+
    |                            |                  |
+---v-----------+   +-----------v---+   +----------v--------+
| Elasticsearch |   | Autocomplete  |   | Relevance Config  |
| Cluster       |   | Service       |   | Service            |
| (per-tenant   |   | (prefix trie  |   | (boost rules,     |
|  routing)     |   |  + popularity)|   |  per-merchant)    |
+-------+-------+   +---------------+   +-------------------+
        |
+-------v-------+
| Index Updater |  (Kafka consumer, near real-time)
| Service       |
+-------+-------+
        |
+-------v------------------+
| CDC Stream               |
| (Debezium on Product DB) |
+-------+------------------+
        |
+-------v-------+
| Product DB    |  (MySQL -- source of truth)
| (sharded by   |
|  merchant)    |
+---------------+
```

### Core Components

1. **API Gateway / Edge Proxy** -- identifies the merchant from the request domain or shop header. Attaches tenant context to every downstream call. Rate-limits per merchant.
2. **Search Service** -- stateless query orchestration. Parses the query, resolves the merchant's relevance config, builds the Elasticsearch query, applies facet logic, and assembles the response.
3. **Elasticsearch Cluster** -- the search index. Stores product documents with variant attributes flattened into the parent document. Tenant isolation via routing.
4. **Autocomplete Service** -- prefix-matching with popularity-weighted suggestions. Separate from main search for latency isolation.
5. **Relevance Config Service** -- stores per-merchant boost rules (e.g., "boost products tagged 'new-arrival' by 1.5x"). Cached aggressively.
6. **Index Updater Service** -- Kafka consumer that reads CDC events from the product database and applies near real-time updates to ES.
7. **Product Database** -- MySQL (Shopify's primary DB). The source of truth for all product data.

---

## Step 3: Multi-Tenant Index Strategy

This is the defining architectural decision. Every choice here has cascading effects on performance, isolation, and operational complexity.

### The Options

**Option A: Index per merchant.** Each merchant gets its own Elasticsearch index. Clean isolation, easy to delete/reindex, but millions of indices blow up cluster state. ES stores index metadata in memory on every master-eligible node -- millions of indices means gigabytes of cluster state, slow master elections, and brittle recovery.

**Option B: Shared index with tenant filter.** One giant index, every query includes `merchant_id` filter. Simple operationally, but noisy-neighbor risk, no per-merchant tuning, and a single merchant's reindex affects everyone.

**Option C: Hybrid strategy (the right answer).**

```
Merchant Classification:
  - Large merchants: > 10K products -> dedicated index per merchant
  - Small merchants: < 10K products -> shared index, shard routing by tenant_id

Routing logic in Search Service:
  1. Look up merchant classification (cached in-memory, refreshed every 5 min)
  2. If large merchant: query their dedicated index
  3. If small merchant: query shared index with routing=tenant_id
  4. All queries include tenant_id filter regardless of path
```

### Why Hybrid at 10K

- **Dedicated indices (> 10K products):** These merchants generate enough query volume and index churn to justify isolation. Reindexing a 500K-product catalog takes minutes -- you don't want that blocking a shared index. You can tune shard count and replica count per merchant. The number of merchants above 10K products is manageable (thousands, not millions), so cluster state stays healthy.
- **Shared indices with routing (< 10K products):** The long tail of millions of small merchants is packed into shared indices. Elasticsearch `routing=tenant_id` directs all documents for a merchant to the same shard, so queries hit exactly one shard instead of fanning out. The `tenant_id` filter ensures strict isolation even though data is co-located.

### Shard Routing for Shared Indices

```
Index: products-shared-us-east-001
  Shard 0: merchants A, D, G (routed by tenant_id hash)
  Shard 1: merchants B, E, H
  Shard 2: merchants C, F, I

Query for merchant B:
  GET /products-shared-us-east-001/_search?routing=tenant_B
  -> hits only Shard 1 (not a fan-out to all shards)
```

Without routing, every query touches every shard in the index. With millions of small-merchant queries per second, this fan-out would multiply load by the shard count. Routing is not optional -- it's the mechanism that makes shared indices viable.

**Failure mode to mention:** If a small merchant suddenly goes viral (gets featured on TV), their query volume can saturate the shard they're on, impacting co-located merchants. Mitigation: monitor per-merchant QPS and auto-promote to a dedicated index when thresholds are crossed. This promotion can happen live by creating the dedicated index, reindexing the merchant's data into it, and updating the routing table.

---

## Step 4: Document Model and Variant-Aware Indexing

A single Shopify product can have hundreds of variants (e.g., 10 sizes x 10 colors x 3 materials = 300 variants). The naive approach of creating one ES document per variant is catastrophic: it balloons index size, distorts relevance scoring (the same product appears 300 times), and creates massive fan-out during indexing.

### Design: Single Document Per Product, Variant Attributes Flattened

```json
{
  "product_id": "prod_abc123",
  "tenant_id": "shop_xyz",
  "title": "Classic Cotton T-Shirt",
  "description": "Soft, breathable cotton tee...",
  "tags": ["new-arrival", "best-seller"],
  "product_type": "T-Shirts",
  "vendor": "Acme Clothing",
  "created_at": "2026-03-15T10:00:00Z",
  "published_at": "2026-03-15T12:00:00Z",

  "variant_colors": ["red", "blue", "black", "white"],
  "variant_sizes": ["XS", "S", "M", "L", "XL", "XXL"],
  "variant_materials": ["cotton", "organic cotton"],
  "price_min": 19.99,
  "price_max": 29.99,
  "compare_at_price_min": 34.99,

  "inventory_available": true,
  "total_inventory": 2847,

  "image_url": "https://cdn.shopify.com/...",
  "boost_score": 1.5,

  "language": "en",
  "searchable_text_en": "Classic Cotton T-Shirt soft breathable cotton tee red blue black white XS S M L XL XXL"
}
```

### Key Decisions in the Document Model

**Variant attributes as arrays.** `variant_colors: ["red", "blue"]` lets ES match a search for "red t-shirt" without creating separate documents. The `terms` query on array fields matches any element.

**Price as min/max range.** Variants have different prices. Store `price_min` and `price_max` so faceted price range filters work correctly. A search for "t-shirts under $25" filters on `price_min <= 25`.

**Inventory availability as boolean.** Don't store per-variant inventory in the search index -- that's too volatile and too granular. Inventory changes on every purchase, creating a firehose of index updates. Store a boolean `inventory_available` (is any variant in stock?) and the total count. Detailed variant-level availability is checked at product detail page load time from the inventory service.

**`searchable_text` field.** A denormalized field that concatenates title, description keywords, variant attributes, and tags. Language-specific analyzer applied. This avoids complex cross-field queries at search time and lets you control what's searchable in one place.

### ES Index Mapping (Simplified)

```json
{
  "mappings": {
    "properties": {
      "tenant_id":          { "type": "keyword" },
      "title":              { "type": "text", "analyzer": "english_custom" },
      "description":        { "type": "text", "analyzer": "english_custom" },
      "searchable_text_en": { "type": "text", "analyzer": "english_custom" },
      "tags":               { "type": "keyword" },
      "variant_colors":     { "type": "keyword" },
      "variant_sizes":      { "type": "keyword" },
      "price_min":          { "type": "float" },
      "price_max":          { "type": "float" },
      "inventory_available":{ "type": "boolean" },
      "boost_score":        { "type": "float" },
      "created_at":         { "type": "date" },
      "published_at":       { "type": "date" }
    }
  }
}
```

**Trade-off: nested vs. flattened variant attributes.** Using ES `nested` type would let you query "red AND size XL" and only match products where a single variant has both attributes (not just any variant with red and any variant with XL). But nested queries are 3-5x slower and significantly increase index size because each nested object is stored as a hidden internal document. In practice, the cross-product false positive rate is low enough that flattened arrays are the right default. Offer nested as an option for merchants who need exact variant-combination filtering.

---

## Step 5: Real-Time Index Updates via CDC

Product data lives in MySQL. When a merchant creates, updates, or deletes a product, the search index must reflect it within 5 seconds.

### CDC Pipeline

```
MySQL (Product DB)
    |
    | Binlog replication
    v
Debezium Connector
    |
    | Publishes change events
    v
Kafka Topic: product-changes
    | Partitioned by tenant_id (ordering guarantee per merchant)
    v
Index Updater Service (Kafka consumer group)
    |
    | Transforms DB row -> ES document
    | Resolves variant attributes (joins variants table)
    | Applies language detection
    v
Elasticsearch (bulk API, batched per 100ms or 500 docs)
```

### Why CDC over Application-Level Events

Application-level dual writes (`product_service.save(product); es_client.index(product)`) are tempting but dangerous:
- **Partial failure:** If ES indexing fails after the DB write, the search index is silently stale. No retry mechanism unless you build one.
- **Missed writes:** Any code path that mutates products (admin UI, API, bulk import, app integrations) must remember to publish the event. CDC captures all writes regardless of origin because it reads the binlog.
- **Ordering:** CDC preserves write ordering from the binlog. Application events can arrive out of order across multiple service instances.

### Handling Variant Fan-Out

A product update may touch the `products` table, the `variants` table, or both. The Index Updater must handle this:

```
Event: UPDATE on variants table (variant_id=v123, product_id=prod_abc)
  1. Look up product_id from event
  2. Fetch full product + all variants from DB (read replica)
  3. Rebuild the complete ES document
  4. Index to ES with product_id as document ID (upsert)
```

This "fetch and rebuild" approach is simpler and more correct than trying to do partial updates to a flattened document. The product document is small (< 5KB), and the extra DB read is cheap relative to the complexity of maintaining partial update logic for nested variant attributes.

**Debounce for bulk imports:** When a merchant bulk-imports 10K products, Debezium fires 10K CDC events in quick succession. The Index Updater debounces per merchant -- if it sees > N events for the same merchant within a window, it switches from individual indexing to a bulk reindex of that merchant's entire catalog. This prevents overwhelming ES with thousands of individual index requests.

### Backfill and Reindexing

When the index mapping changes or a merchant needs reindexing:
- Use a **reindex worker** that reads from the DB (not CDC) and bulk-indexes to a new index
- **Blue-green indexing:** build the new index alongside the old one, swap the alias when complete
- For dedicated-index merchants, this is a per-merchant operation. For shared indices, you reindex the entire shared index (or use ES reindex API with a query filter for a specific tenant)

**Failure mode:** If the Kafka consumer falls behind (lag > 30 seconds), search results become visibly stale. Alert on consumer lag. Have a fast-path for critical updates (price changes, out-of-stock) that bypass Kafka and write directly to ES via synchronous call from the application layer. This is a controlled dual-write for a narrow set of high-priority mutations, not a general-purpose pattern.

---

## Step 6: Query Processing and Relevance

### Query Flow

```
Customer types: "blue running shoes under $80"
    |
    v
Search Service receives request with tenant context
    |
    v
1. QUERY PARSING
   - Tokenize and normalize
   - Extract filters: color=blue, price_max=80
   - Remaining search terms: "running shoes"
    |
    v
2. BUILD ES QUERY
   {
     "query": {
       "function_score": {
         "query": {
           "bool": {
             "must": [
               { "match": { "searchable_text_en": "running shoes" } }
             ],
             "filter": [
               { "term": { "tenant_id": "shop_xyz" } },
               { "term": { "variant_colors": "blue" } },
               { "range": { "price_min": { "lte": 80 } } },
               { "term": { "inventory_available": true } }
             ],
             "should": [
               { "match": { "title": { "query": "running shoes", "boost": 2.0 } } }
             ]
           }
         },
         "functions": [
           { "filter": { "term": { "tags": "new-arrival" } },
             "weight": 1.3 },
           { "filter": { "term": { "tags": "best-seller" } },
             "weight": 1.5 },
           { "field_value_factor": {
               "field": "boost_score", "modifier": "none", "missing": 1 } }
         ],
         "score_mode": "multiply",
         "boost_mode": "multiply"
       }
     }
   }
    |
    v
3. EXECUTE (with routing=tenant_id for shared indices)
    |
    v
4. ASSEMBLE RESPONSE (product data, facet counts, pagination)
```

### Merchant-Customizable Relevance via function_score

Merchants configure boost rules through the Shopify admin:

```
Boost Rules (stored in Relevance Config Service):
  merchant "cool-shoes-co":
    - boost tag "new-arrival" by 1.3x
    - boost tag "on-sale" by 1.2x
    - bury tag "clearance" by 0.5x
    - sort available products first (inventory_available: true -> boost 10x)
```

At query time, the Search Service fetches the merchant's boost config (cached with 60s TTL) and injects `function_score` functions into the ES request. Each boost rule becomes a `filter` + `weight` pair within the `functions` array.

This is a **query-time boost**, not an index-time modification, so changes take effect immediately without reindexing. When a merchant toggles "promote new arrivals" in their admin, the next search query picks up the new config from cache (or after TTL expiry).

**Trade-off:** Query-time boosts add complexity to the ES query and slightly increase latency (5-10ms). The alternative is pre-computing boost scores into the document at index time, which is faster at query time but delays boost changes until the next index update. Query-time boosts are the right choice because merchants expect instant feedback when they change relevance settings, and the latency cost is marginal.

### Language-Specific Analysis

```
Merchant language settings:
  store "paris-boutique" -> primary language: fr, secondary: en
  store "tokyo-fashion"  -> primary language: ja

Index mapping uses language-specific analyzers:
  searchable_text_fr: { analyzer: "french_custom" }  (stemming, stop words, elision)
  searchable_text_ja: { analyzer: "kuromoji" }        (morphological analysis)
  searchable_text_en: { analyzer: "english_custom" }  (stemming, stop words, synonyms)
```

Products are indexed with the language field that matches the merchant's store language. For merchants with multi-language stores, the product is indexed with multiple `searchable_text_*` fields, and the query targets the field matching the customer's locale.

**Gotcha:** CJK languages (Chinese, Japanese, Korean) require specialized tokenizers. Standard whitespace tokenization fails completely on Japanese because words are not separated by spaces. The `kuromoji` (Japanese), `nori` (Korean), and `icu` (Chinese) analyzers are necessary. Missing this means search is fundamentally broken for a significant fraction of merchants.

---

## Step 7: Autocomplete and Typeahead

Autocomplete must be under 100ms -- ideally under 50ms. It's a separate subsystem from full search because the latency requirements and data access patterns are fundamentally different.

### Architecture

```
Customer types: "run"
    |
    v
Edge Cache (CDN)  <- cache hit for common prefixes
    |
    | cache miss
    v
Autocomplete Service
    |
    +-> Prefix Trie (in-memory, per merchant)
    |     "run" -> ["running shoes", "running shorts", "running watch"]
    |     Weighted by: query popularity + product count + recency
    |
    +-> ES Completion Suggester (fallback for trie miss)
          Uses "completion" field type with FST (Finite State Transducer)
```

### Building the Suggestion Corpus

Suggestions come from three sources, blended by weight:

1. **Product titles** (weight: 1.0) -- tokenized into suggestion phrases. "Nike Air Zoom Pegasus" generates suggestions for "nike", "air", "zoom", "pegasus", "nike air", etc.
2. **Popular search queries** (weight: 1.5) -- mined from search logs. "running shoes" is suggested because thousands of customers search for it.
3. **Collection/category names** (weight: 0.8) -- "Men's Shoes", "Summer Collection".

Per-merchant isolation means each merchant's autocomplete corpus is different. A search for "p" on a shoe store suggests "pumps, platforms, Puma" while "p" on an electronics store suggests "phones, PlayStation, power banks."

### Popularity Weighting

```
Suggestion score = base_relevance * popularity_decay(query_count, recency)

popularity_decay = query_count * exp(-lambda * days_since_last_search)

This ensures:
  - Frequently searched terms rank higher
  - Stale suggestions decay over time
  - Seasonal terms (e.g., "halloween costume") rise and fall naturally
```

### Caching Strategy

- **High-traffic merchants:** Precompute top suggestions for all 1-3 character prefixes. Cache at edge. Covers 90%+ of autocomplete requests.
- **Low-traffic merchants:** Cache on first request, TTL 5 minutes. Most small merchants have low enough traffic that cold starts are rare.
- **Invalidation:** When products change, invalidate the merchant's autocomplete cache asynchronously. A 30-second delay is acceptable for autocomplete freshness.

---

## Step 8: Faceted Search

Faceted search lets customers narrow results by attributes: color, size, price range, availability, product type. The facets must be **dynamic** -- they reflect what's actually available in the current result set, not a static list hardcoded per merchant.

### How Facets Work in ES

```
Customer searches: "shoes" on merchant "cool-shoes-co"

ES query includes aggregations:
{
  "query": { ... },
  "aggs": {
    "colors": {
      "terms": { "field": "variant_colors", "size": 20 }
    },
    "sizes": {
      "terms": { "field": "variant_sizes", "size": 30 }
    },
    "price_ranges": {
      "range": {
        "field": "price_min",
        "ranges": [
          { "to": 25 },
          { "from": 25, "to": 50 },
          { "from": 50, "to": 100 },
          { "from": 100 }
        ]
      }
    },
    "availability": {
      "terms": { "field": "inventory_available" }
    }
  }
}

Response includes:
  results: [shoe1, shoe2, ...]
  facets:
    colors: [{ "black": 42 }, { "white": 38 }, { "red": 21 }, ...]
    sizes: [{ "10": 35 }, { "11": 33 }, { "9": 30 }, ...]
    price_ranges: [{ "under $25": 12 }, { "$25-$50": 45 }, ...]
    availability: [{ "in stock": 89 }, { "out of stock": 15 }]
```

### Dynamic Facet Discovery

Different merchants sell different product types with different attributes. A clothing store has color/size facets; an electronics store has storage/RAM/screen-size facets. Hardcoding facet fields means every new product category requires a code change.

**Approach:** Merchants define "product options" in Shopify (e.g., "Color", "Size", "Material"). During indexing, the Index Updater extracts these option names and values into structured fields. At query time, the Search Service knows which option names exist for this merchant (cached from a metadata lookup) and requests aggregations for each.

```
Index document:
  "options": {
    "Color": ["red", "blue"],
    "Size": ["S", "M", "L"],
    "Material": ["cotton"]
  }

At query time, the Search Service requests aggregations for each known option name.
```

**Trade-off: aggregation cost.** Each aggregation adds latency. For merchants with 20+ custom option types, requesting all aggregations on every query is wasteful. Solution: only request aggregations for the top 5-8 most common option types by product count, or let the merchant configure which facets appear in their storefront.

### Post-Filter Pattern

When a customer selects a facet (e.g., color: "red"), the other facet counts should still reflect the full result set, not the filtered subset. Otherwise, selecting "red" would show "red: 21" for colors and hide all other color counts -- the customer can't see alternatives.

```
ES "post_filter" pattern:
  - Main query: "shoes" (unfiltered) -> used for aggregations
  - Post-filter: color = "red" -> applied after aggregations, only affects results

This shows:
  Results: only red shoes
  Facet counts: reflect all shoes (so customer can see "blue: 38" and switch)
```

This is a well-known ES pattern but easy to get wrong. Getting it backwards (filtering before aggregation) is one of the most common faceted search bugs.

---

## Step 9: Scaling for BFCM and Failure Modes

Black Friday/Cyber Monday (BFCM) is Shopify's Super Bowl. Search traffic spikes 5-10x over normal levels. The system must handle 100K+ QPS without degradation.

### Capacity Planning

```
Normal traffic:
  - 20K search QPS
  - 50K autocomplete QPS

BFCM peak:
  - 100K+ search QPS
  - 300K+ autocomplete QPS
  - Concentrated on top 1000 merchants (power law distribution)

ES Cluster sizing (BFCM):
  - Data nodes: 200+ (across availability zones)
  - 1 replica per shard minimum (2 replicas for dedicated-index merchants)
  - Read-heavy: scale replicas, not primaries
  - Memory: ES needs heap for aggregations. Budget 50% of node RAM for heap.
```

### Caching Under Load

```
Cache hierarchy:
  1. CDN edge cache: autocomplete for top prefixes (hit rate: 60%)
  2. Application-level Redis: recent search results per merchant (hit rate: 30%)
  3. ES query cache: repeated identical queries (hit rate: 20%)
  4. ES filesystem cache: hot index segments in OS page cache

Effective hit rate at BFCM: 70-80% of requests never reach ES.
```

### Graceful Degradation

When the system is under extreme load, degrade gracefully rather than failing hard:

1. **Disable aggregations.** Faceted counts are expensive. During overload, return results without facet counts. The storefront shows filter options without counts.
2. **Reduce result window.** Instead of scoring top 1000 and returning top 20, score top 100 and return top 20. Less accurate ranking, much cheaper.
3. **Serve stale cache.** Extend cache TTLs from 60 seconds to 5 minutes. Slightly stale results are better than timeouts.
4. **Circuit breaker on slow merchants.** If a dedicated-index merchant's index is slow (bad query pattern, huge catalog), circuit-break and return cached results rather than letting it consume cluster resources.
5. **Shed autocomplete before search.** Autocomplete is nice-to-have. If you must shed load, disable autocomplete first. Customers can still type full queries and press enter.

### Failure Modes and Mitigations

```
Failure: ES node dies
  Impact: Replicas serve reads. No data loss.
  Mitigation: Automatic shard rebalancing. Over-provision by 20%.

Failure: Kafka consumer falls behind (CDC lag)
  Impact: Search results become stale (> 5s freshness SLA violated)
  Mitigation: Alert on lag. Scale consumer instances. Fast-path for critical
  updates (out-of-stock) that bypass Kafka.

Failure: Entire ES cluster unreachable
  Impact: Search is down.
  Mitigation: Multi-region ES clusters. Fail over to secondary region.
  Fallback: serve results from a pre-built static cache (top 100 products
  per merchant, refreshed hourly). Degraded but not dead.

Failure: Merchant's index corrupted after bad reindex
  Impact: One merchant's search returns garbage.
  Mitigation: Blue-green indexing. Keep previous index version. Swap alias
  back to previous version within seconds.

Failure: Hot merchant overwhelms shared index
  Impact: Co-located merchants in same shard experience elevated latency.
  Mitigation: Per-merchant QPS monitoring. Auto-promote to dedicated index.
  Rate-limit search QPS per merchant at the gateway.
```

---

## Step 10: Extensions -- AI-Powered Discovery

Mention these as future extensions to show breadth. Don't deep-dive unless the interviewer asks.

### Semantic Search Layer

Add a vector search path alongside keyword search:
- Embed product titles + descriptions using a text embedding model
- Store vectors in ES dense_vector fields or a dedicated vector store
- At query time, embed the search query and find nearest neighbors
- Merge keyword (BM25) and semantic (vector similarity) results via Reciprocal Rank Fusion
- Especially valuable for intent-based queries ("gift for dad who likes cooking") where keyword search fails

### Generative Recommendations

- **Conversational search:** "I need an outfit for a summer wedding" -- the system understands context and recommends across product types
- **Similar product discovery:** Given a product, find semantically similar products across the catalog using embeddings
- **Auto-generated product descriptions:** Use LLMs to enrich product search text for merchants who have sparse product data, improving recall

### Personalized Search

For storefronts with logged-in customers or cookie-based sessions:
- Re-rank results based on browsing history and purchase history
- Boost categories the customer has previously engaged with
- Cold start with popularity-based ranking, warm up with behavioral signals

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Tenant isolation | Hybrid (dedicated + shared indices at 10K threshold) | Index per merchant | Millions of indices collapse ES cluster state; shared-only has noisy-neighbor risk |
| Variant indexing | Flattened arrays in parent doc | Nested type / doc per variant | Nested is 3-5x slower; one doc per variant balloons index and creates duplicates |
| Index updates | CDC via Debezium + Kafka | Application-level dual write | CDC captures all write paths; dual writes have partial-failure risk |
| Relevance customization | Query-time function_score | Index-time boost field | Query-time gives instant feedback; index-time requires reindexing |
| Autocomplete | Precomputed trie + ES completion | Full search with prefix query | Dedicated path meets 50ms latency target; full search is too slow |
| Language support | Per-language analyzer fields | Single field with ICU analyzer | Language-specific stemming and tokenization produce far better results |
| Faceted search | ES aggregations with post_filter | Application-side counting | ES aggregations are optimized for this; post_filter preserves facet counts correctly |
| BFCM scaling | Read replicas + aggressive caching | Over-provision primaries | Read replicas scale linearly; primary over-provisioning wastes resources 11 months/year |

---

## Common Mistakes to Avoid

1. **Creating one ES document per variant.** A product with 300 variants becomes 300 documents, ballooning index size and returning the same product 300 times in results. Flatten variant attributes into the parent product document.

2. **Using index-per-merchant at Shopify scale.** Millions of indices will overwhelm the ES cluster state (stored in memory on every node). Use hybrid isolation with routing on shared indices for the long tail.

3. **Dual-writing to DB and ES from application code.** Every code path that mutates products must remember to also update ES. CDC captures mutations at the database level, regardless of which service or code path wrote them.

4. **Ignoring the post_filter pattern for facets.** Filtering before aggregation means selecting "red" hides all other color options from the facet counts. Use post_filter so aggregations reflect the broader result set.

5. **Applying the same analyzer to all languages.** English stemming applied to Japanese text produces garbage. Use language-specific analyzers and detect the merchant's store language at index time.

6. **Treating autocomplete as a slow search.** Autocomplete has a 50-100ms budget. Running a full Elasticsearch query for every keystroke will miss that target under load. Use dedicated data structures (completion suggesters, prefix tries) with aggressive edge caching.

7. **No graceful degradation plan for BFCM.** When search latency spikes, having no plan means the whole storefront freezes. Design explicit degradation levels: drop facets, serve stale cache, shed autocomplete.

8. **Storing real-time inventory in the search index.** Inventory changes far more frequently than product data (every purchase decrements it). Storing per-variant inventory in ES creates a firehose of index updates. Store only `inventory_available: boolean` and check detailed availability at the product detail page.

---

## Related Topics

- [[../../02-scaling-reads/index|Scaling Reads]] -- search index scaling, caching, read replicas, edge caching for autocomplete
- [[../../01-databases-and-storage/index|Databases & Storage]] -- Elasticsearch internals, inverted indexes, shard routing, document modeling
- [[../../05-async-processing/index|Async Processing]] -- CDC pipelines, Kafka consumers, near real-time indexing
- [[../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- multi-tenant data isolation, eventual consistency, cluster state management
- [[../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- graceful degradation, circuit breakers, blue-green indexing
- [[../../09-ml-ai-infrastructure/index|ML/AI Infrastructure]] -- embedding models for semantic search, vector stores, generative recommendations
- [[../../08-api-gateway-and-service-mesh/index|API Gateway]] -- tenant identification, per-merchant rate limiting
