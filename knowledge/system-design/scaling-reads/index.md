# Scaling Reads

Scaling reads is one of the most fundamental system design challenges and a frequent interview topic. Most production systems are read-heavy -- often 90%+ of traffic is reads. The core strategies for scaling reads are **caching**, **read replicas**, **CDNs**, **indexing**, **materialized views**, and **denormalization**. Each comes with trade-offs between consistency, complexity, and performance. A Staff-level answer demonstrates not just knowing these tools, but knowing *when* to reach for each one and how they compose.

---

## Caching Strategies

Caching stores frequently accessed data closer to the consumer, reducing latency and load on the primary datastore. The key decision is **where** to cache and **how** to keep the cache consistent with the source of truth.

### Cache-Aside (Lazy Loading)

The application checks the cache first. On a miss, it reads from the database, populates the cache, then returns the result. This is the most common pattern because it is simple and the application has full control over what gets cached.

**Trade-offs:** Cache misses incur extra latency (cache check + DB read + cache write). Stale data is possible if the underlying data changes and the cache is not invalidated. You need a TTL or explicit invalidation strategy.

```
Read flow:
  Client -> App -> Cache (HIT?) -> return
                   Cache (MISS) -> DB -> write to Cache -> return
```

### Write-Through

Every write goes to both the cache and the database synchronously. Reads always hit the cache. This ensures the cache is always consistent with the DB but adds latency to every write operation.

**Trade-offs:** Write latency increases because you must write to two places. The cache may hold data that is never read (cache pollution). Best when reads vastly outnumber writes and you need strong consistency guarantees.

### Write-Back (Write-Behind)

Writes go to the cache only, and the cache asynchronously flushes to the database on a schedule or when evicted. This gives the lowest write latency but risks data loss if the cache node crashes before flushing.

**Trade-offs:** Risk of data loss. Complex failure modes. Best for workloads where some data loss is acceptable (e.g., analytics counters, session data). Requires a durable cache layer or WAL.

### Write-Around

Writes go directly to the database, bypassing the cache. The cache is only populated on read misses. This avoids cache pollution from data that may never be read again.

**Trade-offs:** First read after a write is always a cache miss. Good for write-heavy workloads where recently written data is unlikely to be read immediately.

### Cache Invalidation

Cache invalidation is famously one of the two hard problems in computer science. Strategies include:

- **TTL-based expiry** -- simple but allows stale reads up to the TTL window
- **Event-driven invalidation** -- DB change events (CDC) trigger cache deletes. More consistent but adds infrastructure complexity
- **Version stamping** -- cache keys include a version number; bumping the version effectively invalidates old entries

### Cache Topology

| Topology | Description | Best For |
|---|---|---|
| **Local (in-process)** | HashMap/LRU in app memory | Hot-path data, config, small datasets |
| **Distributed (Redis/Memcached)** | Shared cache across app instances | Session data, API responses, computed results |
| **Multi-tier** | L1 local + L2 distributed | Minimize network hops for hot data |

**Interview tip:** Always discuss cache eviction policies (LRU, LFU, FIFO) and thundering herd mitigation (request coalescing / single-flight pattern where only one goroutine/thread fetches on a miss while others wait).

---

## Read Replicas

Read replicas are copies of the primary database that serve read traffic. The primary handles all writes and asynchronously (or synchronously) replicates to followers. This is a standard scaling pattern for relational databases (PostgreSQL, MySQL) and many NoSQL stores.

### Replication Lag

Async replication means replicas may be slightly behind the primary. This creates **eventual consistency** -- a user might write data and then read from a replica that hasn't received the write yet.

**Mitigation strategies:**
- **Read-your-writes consistency** -- after a write, route that user's subsequent reads to the primary for a short window
- **Monotonic reads** -- pin a user to the same replica for a session so they don't see time go backwards
- **Causal consistency** -- track write timestamps and only serve reads from replicas that have caught up past that timestamp

### Scaling Pattern

```
                    +-----------+
  Writes ---------> |  Primary  |
                    +-----+-----+
                          |  async replication
               +----------+----------+
               |          |          |
          +----v---+ +----v---+ +----v---+
          |Replica1| |Replica2| |Replica3|
          +--------+ +--------+ +--------+
               ^          ^          ^
               |          |          |
          Reads distributed via load balancer
```

### Promotion and Failover

When the primary fails, one replica must be promoted. This is handled by orchestration tools (Patroni for PostgreSQL, MySQL Group Replication). The promotion process involves stopping replication, ensuring the promoted replica has the latest data, and redirecting writes.

**Interview tip:** Discuss the trade-off between synchronous replication (stronger consistency, higher write latency) and asynchronous replication (lower latency, risk of data loss on failover).

---

## Content Delivery Networks (CDNs)

CDNs cache static and semi-static content at edge locations geographically close to users. They reduce latency for global audiences and offload traffic from origin servers.

### Push vs Pull CDN

- **Pull CDN** -- the CDN fetches content from the origin on the first request, then caches it. Simpler to set up. Content may be stale until TTL expires or explicit purge.
- **Push CDN** -- you explicitly upload content to the CDN. Better for large files or content you want available immediately at all edges. Requires more operational effort.

### Cache Key Design

CDN cache keys typically include the URL path and selected headers/query params. Poorly designed cache keys cause either:
- **Under-caching** -- too many unique keys, low hit rate
- **Over-caching** -- serving stale or wrong content to different users

**Trade-offs:** CDNs add complexity for personalized or authenticated content. Solutions include edge computing (Cloudflare Workers, Lambda@Edge) that can make per-request decisions at the edge.

---

## Indexing Strategies

Indexes are data structures that allow the database to find rows without scanning the entire table. Choosing the right index strategy is critical for read performance.

### B-Tree Indexes

The default index type in most relational databases. B-trees keep data sorted and allow efficient lookups, range scans, and prefix matching. They work well for equality and range queries.

**Characteristics:**
- O(log n) lookups
- Good for read-heavy workloads
- Moderate write overhead (tree rebalancing on inserts)
- Work well with disk-based storage (node size matches page size)

### LSM-Tree Indexes (Log-Structured Merge Tree)

Used by write-optimized stores like Cassandra, RocksDB, and LevelDB. Writes go to an in-memory buffer (memtable) that periodically flushes to sorted files (SSTables) on disk. Reads may need to check multiple levels and merge results.

**Characteristics:**
- Very fast writes (sequential I/O)
- Reads can be slower due to multi-level lookups (mitigated by bloom filters)
- Compaction process merges levels, consuming CPU and I/O
- Best for write-heavy workloads

### Covering Indexes

A covering index includes all columns needed to satisfy a query, so the database can answer the query entirely from the index without fetching the actual row. This eliminates random I/O to the heap.

```sql
-- Query: SELECT name, email FROM users WHERE status = 'active'
-- Covering index:
CREATE INDEX idx_users_status_covering ON users (status) INCLUDE (name, email);
```

**Trade-off:** Larger index size, more write overhead. But dramatically faster reads for the covered queries.

### Composite Indexes and Index Order

The order of columns in a composite index matters. The leftmost prefix rule means the index can be used for queries that filter on the first column, the first two columns, etc., but not for queries that skip the first column.

```sql
-- Index on (country, city, zip_code)
-- Usable for: WHERE country = 'US'
-- Usable for: WHERE country = 'US' AND city = 'NYC'
-- NOT usable for: WHERE city = 'NYC' (skips country)
```

### Partial (Filtered) Indexes

Index only a subset of rows matching a condition. Smaller index, faster to maintain, but only helps queries that match the filter.

```sql
CREATE INDEX idx_active_users ON users (email) WHERE active = true;
```

---

## Materialized Views

A materialized view is a precomputed query result stored as a table. Unlike a regular view (which re-executes the query each time), a materialized view caches the result and must be explicitly refreshed.

**Use cases:**
- Complex aggregation queries (dashboards, reports)
- Joining multiple tables that are expensive to compute on every read
- Denormalized read models in a [[../scaling-writes/index|CQRS]] architecture

**Refresh strategies:**
- **Full refresh** -- recompute the entire view. Simple but expensive for large datasets.
- **Incremental refresh** -- only update rows affected by changes. More complex but much faster.
- **On-demand** -- refresh when queried if stale (via TTL or change detection)

**Trade-offs:** Storage cost for the materialized data. Staleness between refreshes. Refresh can be expensive and lock the view. But they dramatically speed up complex read queries.

---

## Denormalization Trade-offs

Denormalization deliberately duplicates data across tables to avoid expensive joins at read time. It trades storage and write complexity for read performance.

### When to Denormalize

- Read patterns are well-known and stable
- Joins are the bottleneck (especially cross-shard joins in distributed DBs)
- The duplicated data changes infrequently
- You need sub-millisecond read latency

### Risks

- **Data inconsistency** -- duplicated data can drift if updates miss a copy
- **Write amplification** -- every write must update all copies
- **Schema rigidity** -- denormalized schemas are harder to evolve

### Denormalization vs Materialized Views vs Caching

| Approach | Consistency | Latency | Complexity |
|---|---|---|---|
| Normalized + joins | Strong | Higher | Low |
| Materialized views | Eventually consistent | Low | Medium |
| Denormalized tables | Risk of inconsistency | Lowest | High (write path) |
| Cache layer | TTL-dependent | Lowest | Medium |

**Interview tip:** A mature answer combines multiple approaches. For example: normalized storage as the source of truth, materialized views for common aggregations, a cache layer for hot-path reads, and read replicas to distribute load. Explain which tool you would reach for first and why, given the specific access patterns of the system you are designing.

---

## Putting It Together: A Scaling Reads Decision Framework

```
Is the data static or near-static?
  YES -> CDN + aggressive caching
  NO  -> How frequently does it change?
    Rarely (minutes to hours) -> Cache-aside with TTL + read replicas
    Frequently (seconds) -> Read replicas + event-driven cache invalidation
    Real-time -> Consider [[../real-time-systems/index|real-time patterns]] instead

Is the read query complex (aggregations, joins)?
  YES -> Materialized views or denormalization
  NO  -> Proper indexing + caching

Is the dataset large (billions of rows)?
  YES -> Partitioning/sharding + read replicas per shard
  NO  -> Single primary + read replicas likely sufficient
```

---

## Related Topics

- [[../scaling-writes/index|Scaling Writes]] -- the write-side counterpart
- [[../databases-and-storage/index|Databases & Storage]] -- choosing the right storage engine
- [[../real-time-systems/index|Real-Time Systems]] -- when reads need to be live
- [[../api-gateway-and-service-mesh/index|API Gateway & Service Mesh]] -- edge caching and CDN integration
- [[../fault-tolerance-and-reliability/index|Fault Tolerance]] -- handling cache failures and replica lag
