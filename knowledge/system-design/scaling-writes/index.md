# Scaling Writes

Scaling writes is fundamentally harder than scaling reads because writes must maintain data integrity and ordering guarantees. While reads can be served from any replica, writes typically funnel through a single primary -- creating a bottleneck. The core strategies for scaling writes are **sharding**, **consistent hashing**, **write batching**, **WAL (Write-Ahead Logging)**, **async writes**, **CQRS**, and **event sourcing**. A Staff-level answer demonstrates understanding of the consistency trade-offs each strategy introduces.

---

## Sharding Strategies

Sharding (horizontal partitioning) splits data across multiple database nodes so that no single node handles all writes. Each shard owns a subset of the data and handles reads/writes for that subset independently.

### Hash-Based Sharding

Apply a hash function to a shard key (e.g., `user_id`) and map the result to a shard. Distributes data uniformly if the hash function and key have good distribution.

```
shard_number = hash(user_id) % num_shards
```

**Trade-offs:**
- Even distribution of data and load
- Range queries across shards are expensive (scatter-gather)
- Adding/removing shards requires rehashing and data migration (unless using consistent hashing)
- Hot spots can still occur if certain keys are disproportionately active (e.g., a celebrity's account)

### Range-Based Sharding

Assign contiguous ranges of the shard key to each shard (e.g., users A-M on shard 1, N-Z on shard 2). Efficient for range scans on the shard key.

**Trade-offs:**
- Supports efficient range queries within a shard
- Prone to hot spots if access patterns are skewed (e.g., recent timestamps on time-series data)
- Requires manual or automated rebalancing as ranges grow unevenly

### Geo-Based Sharding

Partition data by geographic region. Users in Europe hit EU shards, users in Asia hit APAC shards. Reduces latency by keeping data close to users and can help with data residency compliance (GDPR).

**Trade-offs:**
- Low latency for regional access
- Cross-region queries are expensive
- Uneven distribution if user bases vary by region
- Complicates global features (e.g., "search all users worldwide")

### Choosing a Shard Key

The shard key is the most important design decision in a sharded system. A good shard key:
- Has high cardinality (many unique values)
- Distributes writes evenly across shards
- Aligns with the most common query patterns (avoid cross-shard queries)
- Does not change frequently (re-sharding a row is expensive)

**Interview tip:** If asked to shard a social media platform, discuss why `user_id` is often a good shard key (queries are user-centric) but acknowledge the problems: celebrity users create hot shards, and queries like "show me all posts with hashtag X" require scatter-gather across all shards.

---

## Consistent Hashing

Consistent hashing solves the re-sharding problem of naive hash-based sharding. Instead of `hash(key) % N`, keys and nodes are both mapped onto a hash ring. Each key is assigned to the next node clockwise on the ring.

```
Hash Ring:

        Node A
       /      \
  Node D        Node B
       \      /
        Node C

Key "user_123" hashes to position between Node A and Node B -> assigned to Node B
```

### Virtual Nodes

Physical nodes map to multiple positions on the ring (virtual nodes). This improves distribution uniformity and ensures that when a node is added or removed, load is redistributed evenly across remaining nodes rather than overwhelming a single neighbor.

**When a node is added:** Only keys in the range immediately preceding the new node's positions need to move. This means adding a node only migrates ~1/N of the data on average.

**When a node fails:** Its keys are distributed to the next nodes on the ring. With virtual nodes, this load is spread across multiple physical nodes.

**Used by:** DynamoDB, Cassandra, Amazon's Dynamo, consistent hash-based load balancers.

---

## Write Batching

Instead of writing each record individually, collect writes into batches and flush them together. This amortizes the overhead of network round trips, transaction commits, and disk syncs.

### Application-Level Batching

Buffer writes in memory and flush periodically or when the buffer reaches a threshold.

```ruby
class WriteBatcher
  BATCH_SIZE = 1000
  FLUSH_INTERVAL = 5 # seconds

  def initialize
    @buffer = []
    @mutex = Mutex.new
    @last_flush = Time.now
    start_flush_timer
  end

  def add(record)
    @mutex.synchronize do
      @buffer << record
      flush! if @buffer.size >= BATCH_SIZE
    end
  end

  private

  def flush!
    return if @buffer.empty?
    batch = @buffer.dup
    @buffer.clear
    # Bulk insert reduces N round trips to 1
    Record.insert_all(batch)
    @last_flush = Time.now
  end

  def start_flush_timer
    Thread.new do
      loop do
        sleep(FLUSH_INTERVAL)
        @mutex.synchronize { flush! if Time.now - @last_flush >= FLUSH_INTERVAL }
      end
    end
  end
end
```

**Trade-offs:**
- Higher throughput (fewer round trips, better disk utilization)
- Increased latency for individual writes (wait for batch to flush)
- Risk of data loss if the process crashes before flushing (mitigated by WAL)
- Complexity of managing the buffer under concurrent access

---

## Write-Ahead Logging (WAL)

A WAL ensures durability by writing changes to a sequential log *before* applying them to the main data structure. If the system crashes mid-write, the WAL can be replayed to recover.

### How It Works

```
1. Client sends write request
2. Append write to WAL (sequential disk I/O -- fast)
3. Acknowledge the write to the client
4. Asynchronously apply the write to the B-tree / data file
5. Periodically checkpoint: mark WAL entries as applied
```

**Why sequential I/O matters:** Sequential disk writes are 100-1000x faster than random writes because they avoid disk seek time (HDD) or write amplification (SSD). The WAL turns random writes into sequential ones.

**Used by:** PostgreSQL (WAL), MySQL (redo log), Kafka (append-only log), LSM-tree databases (memtable + flush).

**Interview tip:** WAL is the foundation of durability in virtually every database. Understand how it connects to replication (the WAL is often what gets shipped to replicas) and crash recovery (replay uncommitted WAL entries on startup).

---

## Async Writes

Asynchronous writes decouple the write acknowledgment from the actual persistence, allowing the system to respond faster at the cost of weaker durability or consistency guarantees.

### Write-Ahead (as above)

Write to the WAL first, ack the client, then apply asynchronously. This is the most common form -- technically the write *is* durable (it is in the WAL) but not yet in its final location.

### Write-Through

Write synchronously to both the cache and the database. The client waits for both to complete. This ensures the cache is always consistent but has the highest write latency.

### Write-Back (Write-Behind)

Write to the cache only, ack the client immediately, and flush to the database asynchronously. Fastest write path but risks data loss on cache failure.

### Write-Around

Write directly to the database, skip the cache entirely. The cache is only populated on subsequent reads (cache-aside). Avoids cache pollution from write-once-read-never data.

### Comparison

| Strategy | Write Latency | Consistency | Durability Risk |
|---|---|---|---|
| Write-through | Highest | Strong | None |
| Write-ahead (WAL) | Medium | Strong (after WAL) | Minimal |
| Write-back | Lowest | Eventual | Data loss on crash |
| Write-around | Medium | Eventual (cache miss) | None (DB is source of truth) |

---

## CQRS (Command Query Responsibility Segregation)

CQRS separates the write model (commands) from the read model (queries) into distinct subsystems, each optimized for its workload. Commands mutate state through a write-optimized store; queries read from a separate, read-optimized store.

### Architecture

```
  Commands (writes)                  Queries (reads)
       |                                  ^
       v                                  |
  +-----------+    events/CDC    +-----------------+
  | Write DB  | --------------> | Read DB / Views |
  | (normalized,                | (denormalized,  |
  |  ACID)    |                 |  fast lookups)  |
  +-----------+                 +-----------------+
```

### When to Use CQRS

- Read and write workloads have vastly different scaling needs
- The read model requires denormalization or complex projections
- You need different consistency guarantees for reads vs writes
- The domain is complex enough that separating concerns simplifies each side

### Trade-offs

- **Eventual consistency** between write and read models (propagation delay)
- **Infrastructure complexity** -- two databases, a synchronization mechanism (CDC, events)
- **Operational overhead** -- monitoring lag, handling failed projections, rebuilding read models

**Interview tip:** CQRS does not require event sourcing. You can implement CQRS with a regular relational DB for writes and a denormalized view or search index (Elasticsearch) for reads, synchronized via CDC. Event sourcing adds value when you need a complete audit trail or temporal queries.

---

## Event Sourcing

Instead of storing the current state of an entity, store a sequence of state-changing events. The current state is derived by replaying all events for that entity.

### Core Concepts

```
Traditional: UPDATE accounts SET balance = 150 WHERE id = 1

Event Sourced:
  Event 1: AccountOpened { id: 1, balance: 0 }
  Event 2: MoneyDeposited { id: 1, amount: 200 }
  Event 3: MoneyWithdrawn { id: 1, amount: 50 }
  Current state: replay events -> balance = 150
```

### Benefits

- **Complete audit trail** -- every change is recorded as an immutable event
- **Temporal queries** -- "what was the balance at time T?" is trivial
- **Event replay** -- rebuild projections, fix bugs by replaying with corrected logic
- **Decoupling** -- downstream systems subscribe to events without coupling to the write model

### Challenges

- **Event schema evolution** -- events are immutable; changing their shape requires versioning
- **Replay performance** -- replaying millions of events is slow; mitigated by snapshots
- **Eventual consistency** -- read models are projections of the event stream, inherently delayed
- **Complexity** -- significantly more complex than CRUD for simple domains

### Snapshots

Periodically save the current derived state as a snapshot. To reconstruct state, load the latest snapshot and replay only events after it.

```ruby
class Account
  def self.from_events(events, snapshot: nil)
    account = snapshot || Account.new
    events.each { |event| account.apply(event) }
    account
  end

  def apply(event)
    case event
    when MoneyDeposited then @balance += event.amount
    when MoneyWithdrawn then @balance -= event.amount
    end
  end
end
```

---

## Scaling Writes: Decision Framework

```
Is write throughput the bottleneck?
  YES -> Consider sharding
    Is the query pattern key-based? -> Hash sharding
    Does it need range scans? -> Range sharding
    Is it geo-distributed? -> Geo sharding

Do writes need to be fast but can tolerate slight delays in reads?
  YES -> CQRS (separate write and read stores)
    Need full audit trail? -> Add event sourcing
    Just need fast reads? -> CDC to denormalized read store

Are individual writes slow (many round trips)?
  YES -> Write batching

Is durability critical but you need low latency?
  YES -> WAL + async apply

Is the write pattern bursty?
  YES -> Queue writes through a [[../async-processing/index|message queue]] and process asynchronously
```

---

## Related Topics

- [[../scaling-reads/index|Scaling Reads]] -- the read-side counterpart
- [[../databases-and-storage/index|Databases & Storage]] -- choosing write-optimized storage engines
- [[../async-processing/index|Async Processing]] -- message queues for write buffering
- [[../distributed-systems-fundamentals/index|Distributed Systems Fundamentals]] -- consensus for cross-shard coordination
- [[../fault-tolerance-and-reliability/index|Fault Tolerance]] -- handling write failures and retries
