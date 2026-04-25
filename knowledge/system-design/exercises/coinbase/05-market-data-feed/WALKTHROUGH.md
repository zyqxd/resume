# Walkthrough: Design a Real-Time Market Data Feed (Coinbase)

## Step 1: Clarify Requirements and Scope

Before drawing anything, pin down the shape of the problem with the interviewer:
- Who are the consumers? (Web app, native mobile, public WebSocket (bidirectional persistent TCP connection over HTTP-upgrade for real-time push) API for institutional bots, internal services)
- How many concurrent connections at steady state vs peak? (Low millions steady, 10x during volatility)
- What is the latency target end-to-end? (Sub-100ms p99 from matching engine fill to subscriber receipt within a region)
- What channels per pair? (Ticker, level2 (L2 — Level 2 order book depth, price-aggregated quantity) order book diffs, recent trades, K-line (Korean candlestick — OHLC candles for a time bucket) aggregations, market summary)
- Is per-pair ordering enough, or do we need global ordering? (Per-pair only -- the trade tape for BTC-USD is causal; BTC-USD vs ETH-USD is not)
- Is the matching engine in scope? (No -- it is the producer; we design the fan-out)
- Web and mobile have the same protocol? (Same WebSocket endpoint, but mobile gets aggressive conflation and partial subscriptions)
- What does "real-time" mean to a retail user vs an institutional client? (Retail: sub-second tick; institutional: low-tens-of-ms with full level2)

This scoping matters because it cleaves the architecture along two axes. First, the **two-path separation**: the trading engine hot loop is single-writer, low-microsecond, and must never be back-pressured by a slow subscriber. Market data fan-out is a separate process that consumes the engine's output stream and explodes it to millions of consumers. Second, the **client tier separation**: mobile consumers cannot drink from the same firehose as institutional bots; the design has to support different conflation policies on the same logical stream.

**Primary design constraint:** The slowest consumer must not slow down the producer. The whole architecture bends around protecting the trading engine and the fast subscribers from the long tail of slow, mobile, and misbehaving clients.

---

## Step 2: High-Level Architecture

```
                Per-pair Matching Engines (Aeron Cluster (open-source low-latency messaging library with built-in RAFT), single-writer)
                  |          |          |          |
                  | trade events, level2 deltas, ticker updates
                  v          v          v          v
               +-------------------------------------+
               |     Core Market Data Bus            |   (in-region, in-memory)
               |  LMAX-style ring buffer per pair    |   (LMAX Disruptor — lock-free fixed-size ring-buffer pattern from LMAX Exchange)
               +-----------------+-------------------+
                                 |
                  +--------------+---------------+
                  |              |               |
                  v              v               v
            +-----------+  +-----------+   +---------------+
            | Regional  |  | Regional  |   | K-line        |
            | Fan-out   |  | Fan-out   |   | Aggregator    |
            | Cluster   |  | Cluster   |   | Service       |
            | (US-East) |  | (EU-West) |   |               |
            +-----+-----+  +-----+-----+   +-------+-------+
                  |              |                 |
                  v              v                 v
            +-----------+  +-----------+   +---------------+
            | Edge WS   |  | Edge WS   |   | Time-Series   |
            | Termi-    |  | Termi-    |   | Store         |
            | nators    |  | nators    |   | (TimescaleDB (Postgres extension for time-series workloads)) |
            +-----+-----+  +-----+-----+   +-------+-------+
                  |              |                 |
                  | WSS          | WSS             | REST
                  v              v                 v
            +-----------+  +-----------+   +---------------+
            |  Web      |  |  Mobile   |   | Snapshot REST |
            |  Clients  |  |  Clients  |   | + CDN (Content Delivery Network) cache   |
            +-----------+  +-----------+   +---------------+

           +---------------------+      +---------------------+
           | Redis ZSET          |      | S3 Cold Archive     |
           | (top-N trending,    |      | (historical K-line, |
           | market summary)     |      | trade tape replay)  |
           +---------------------+      +---------------------+
```

### Core Components

1. **Matching engines** -- per-pair, single-writer, on Aeron Cluster. Authoritative producer of every fill, book update, and ticker change. Out of scope for this design but the upstream we consume.
2. **Core market data bus** -- in-region in-memory ring buffer per pair. Consumes the engine's output, applies sequence numbers, and serves it to N internal subscribers without back-pressuring the engine.
3. **Regional fan-out cluster** -- a tier of stateless workers that subscribe to the core bus and replicate streams into their region. Each worker holds in-memory snapshots of book state per pair so it can serve resnapshot requests.
4. **Edge WebSocket terminators** -- stateless pods that own client connections. Each connects to the regional fan-out and pushes filtered, optionally-conflated streams to subscribers.
5. **K-line aggregator service** -- consumes the trade tape and emits OHLCV (OHLC — open/high/low/close — plus volume) candles at multiple intervals into the time-series store.
6. **Time-series store (TimescaleDB / InfluxDB (time-series database))** -- backs historical K-line REST queries and chart loads.
7. **Redis ZSET cluster** -- backs top-N trending, market summary, and the Coinbase Explore (Coinbase's market discovery surface that displays live prices for thousands of pairs) homepage. Updated by a low-frequency aggregator.
8. **Snapshot REST + CDN** -- serves initial page load (top movers, last price, depth-of-book at moment of request). Cacheable for 1-5 seconds.
9. **S3 cold archive** -- compressed historical trade tape and K-line, for institutional backfill and compliance.

The structure is a **pyramid of fan-out tiers**: one writer (matching engine) becomes thousands (regional fan-out workers) becomes millions (clients). Each tier amplifies and decouples failure domains.

---

## Step 3: Data Model

The wire format is what the interviewer cares about; the internal Go/Rust types mirror it.

### Tick / Ticker Update

```
ticker_update {
  pair:           "BTC-USD",
  sequence:       8472913,        // monotonic per pair
  last_price:     "67421.50",
  bid:            "67421.40",
  ask:            "67421.60",
  best_bid_size:  "0.05",
  best_ask_size:  "0.12",
  volume_24h:     "12453.91",
  change_24h:     "+0.0243",      // fraction
  timestamp:      "2026-04-25T14:30:00.123456Z"
}
```

Ticker updates are batched on the producer side. When a single match cascades through 30 price levels, we emit one ticker update reflecting the final state, not 30. Coinbase Advanced Trade explicitly batches.

### Level2 Update (Incremental Order Book Diff)

```
level2_update {
  pair:           "BTC-USD",
  sequence:       8472914,
  changes: [
    { side: "buy",  price: "67421.40", size: "0.04" },   // size 0 means remove
    { side: "sell", price: "67421.60", size: "0.00" }
  ],
  timestamp:      "2026-04-25T14:30:00.124100Z"
}
```

Level2 is a diff stream. Initial subscription returns a `level2_snapshot` with all 50 levels each side, then `level2_update` deltas after that. Clients reconstruct the book locally.

### Level2 Snapshot

```
level2_snapshot {
  pair:           "BTC-USD",
  sequence:       8472900,        // resume from here
  bids:           [["67421.40","0.05"], ["67421.30","0.20"], ...],
  asks:           [["67421.60","0.12"], ["67421.70","0.08"], ...],
  timestamp:      "2026-04-25T14:30:00.100000Z"
}
```

### Trade Event

```
trade_event {
  pair:           "BTC-USD",
  sequence:       8472915,
  trade_id:       4451093,
  price:          "67421.50",
  size:           "0.013",
  side:           "buy",          // taker side
  timestamp:      "2026-04-25T14:30:00.124300Z"
}
```

### K-line (Candle)

```
kline {
  pair:           "BTC-USD",
  interval:       "1m",
  open_time:      "2026-04-25T14:30:00Z",
  close_time:     "2026-04-25T14:30:59.999Z",
  open:           "67400.00",
  high:           "67450.00",
  low:            "67395.00",
  close:          "67421.50",
  volume:         "12.453",
  trade_count:    143
}
```

### Market Summary (per pair, refreshed every 1-5s)

```
market_summary {
  pair:           "BTC-USD",
  last_price:     "67421.50",
  change_24h:     "+0.0243",
  volume_24h:     "12453.91",
  market_cap:     "1325432100000",
  rank:           1
}
```

### Key Design Decisions in the Schema

**Sequence number per pair.** Every message in any channel for a given pair shares a monotonic sequence. Clients track the highest sequence they have seen and detect gaps. This is the single most important field: without it, no resume protocol works.

**Strings for prices and sizes, not floats.** Wire format uses decimal strings to avoid IEEE 754 rounding. Internally the engine uses fixed-point integers (price in microcents, size in satoshis-equivalent). Floats in market data are a recurring bug source on the consumer side.

**Diff-based level2.** A snapshot is heavy (50 levels x 2 sides = 100 entries x ~30 bytes = ~3KB). Diffs are tiny (one or two changes per update). Subscribers reconstruct locally; we only resnapshot when they fall out of sync.

**Batched ticker.** A market order that walks 50 levels of the book emits one ticker update, not 50. The producer coalesces; the receiver gets the final state. This is bandwidth-critical during volatility.

---

## Step 4: The Producer-Consumer Hot Path

This is where the design earns its staff stripes. The matching engine is single-writer per pair; if any subscriber can slow it down, the whole exchange slows down. The market data bus must be a **lock-free, allocation-free, fan-out-capable** structure.

### Why Not Go Channels

The naive design pipes the matching engine output through a Go channel to N goroutines, one per subscriber. This collapses for two reasons:

1. **Channel send blocks when the channel is full.** A slow consumer blocks the writer. With one writer and thousands of subscribers, the slowest one gates the whole feed.
2. **Allocation per send.** Each channel send copies the message; under millions of messages per second, GC pressure becomes catastrophic.

Coinbase published in August 2025 that they replaced Go channels with an **LMAX Disruptor-style ring buffer** and saw a 38x latency reduction.

### LMAX-Style Ring Buffer

```
       producer cursor
            v
  +---+---+---+---+---+---+---+---+
  |   |   | E | E | E |   |   |   |    fixed-size circular array
  +---+---+---+---+---+---+---+---+
        ^               ^
        |               |
   slow consumer    fast consumer
   cursor           cursor
```

- A fixed-size pre-allocated array of message slots (typical: 2^20 = ~1M slots per pair).
- The producer writes to `cursor % size`; the cursor monotonically increments forever.
- Each consumer holds its own cursor and reads independently. No locks between consumers; each pulls at its own rate.
- The producer uses `sync.Cond` (or a futex-style wakeup) to signal consumers when new data is written, avoiding spin loops while keeping latency low.
- Message slots are recycled via a `sync.Pool`. No per-message allocation.

### Backpressure Semantics

The critical question: what happens when a slow consumer falls behind enough that the producer is about to wrap around and overwrite slots the consumer has not read yet?

**Two policies, by tier:**

- **Internal (engine to fan-out): drop the consumer.** If a regional fan-out worker falls so far behind that the ring would overwrite, kick it. It reconnects, gets a fresh snapshot, and resumes. The producer never blocks.
- **Edge (fan-out to client): conflate, then drop on overflow.** Per-connection ring buffers with smaller capacity. If a client's buffer overflows, send a `disconnect` frame, close the socket, let the client reconnect with snapshot.

The principle: the producer never waits. Subscribers either keep up, get conflated, or get kicked.

### Why This Beats Channels

| Property | Go Channel | LMAX Ring Buffer |
|---|---|---|
| Write latency | Variable (lock contention) | Single CAS, sub-microsecond |
| Slow consumer impact | Blocks writer | Independent cursor, no impact |
| Allocation per message | Yes | No (pre-allocated slots) |
| Fan-out cost | One channel per subscriber | One ring, N cursors |
| Detect lag | Counting full sends | Compare cursor to producer |
| GC pressure | High under load | Near-zero |

The pattern is widely used in trading systems (LMAX, Aeron, Chronicle Queue) for exactly this reason.

---

## Step 5: Multi-Tier Fan-Out Topology

The canonical mistake here is "one Kafka topic per pair, scale subscribers to millions." Kafka topics with millions of consumers per group melt the broker -- partition assignment, offset tracking, and rebalances dominate. The right shape is a **pyramid**.

### Tier Breakdown

| Tier | Instances | Inputs | Outputs (fan-out factor) | State |
|---|---|---|---|---|
| Matching engine | 1 per pair | Order entry | 1 producer cursor on the bus | Order book, sequence |
| Core market data bus | 1 per pair, replicated | Engine output | ~10-20 regional fan-out workers | In-memory ring, last snapshot |
| Regional fan-out | 50-200 per region | Core bus subscription | ~1000 edge terminators each | Per-pair last snapshot, sequence |
| Edge WebSocket terminators | 1000-5000 per region | Regional fan-out | ~5000-20000 client connections each | Per-connection buffers |
| Clients | Millions | Edge WSS | -- | Local book reconstruction |

Total fan-out from one producer to N clients = (10) x (200) x (5000) ~= 10M. The arithmetic shows why each tier is necessary: no single broker would survive a millions-of-fan-out load on one topic.

### What State Each Tier Holds

- **Core bus** holds the authoritative latest book snapshot per pair (so a fan-out worker that reconnects can rehydrate without bothering the engine).
- **Regional fan-out worker** holds a copy of the latest snapshot for every pair it serves (typically all of them, since memory cost is small: 2000 pairs x 3KB = 6MB).
- **Edge terminator** holds **only per-connection state** (subscriptions, last sequence sent, buffer). It does not hold book state -- if a client reconnects, the snapshot comes from the regional worker.

### Replication Across Regions

Each region runs its own fan-out cluster, subscribed to the **same core bus** (cross-region link). For latency reasons, the core bus lives in the same region as the matching engine (typically US-East). EU and Asia regions take a 70-100ms cross-Atlantic hop once, into their regional fan-out, and from there serve local clients with low latency.

The cross-region link is a single firehose per pair, not per-client. Bandwidth: at ~5K messages/sec per pair x 2000 pairs x ~100 bytes = 1 GB/sec aggregate, well within a dedicated link.

---

## Step 6: WebSocket Protocol Design

### Connection Lifecycle

```
Client --> Edge: WSS handshake (TLS (Transport Layer Security), optional permessage-deflate)
Edge --> Client: connection_ack { server_time, supported_channels }
Client --> Edge: subscribe { channels: ["ticker", "level2", "trades"], pairs: ["BTC-USD","ETH-USD"] }
Edge --> Client: subscriptions { active: [...] }
Edge --> Client: level2_snapshot { pair, sequence: N, bids, asks }
Edge --> Client: ticker_update { pair, sequence: N+1, ... }
Edge --> Client: trade_event { pair, sequence: N+2, ... }
Edge --> Client: level2_update { pair, sequence: N+3, ... }
...
Client --> Edge: unsubscribe { channels: ["level2"], pairs: ["BTC-USD"] }
Client --> Edge: ping
Edge --> Client: pong
```

### Subscribe-Within-5s Rule

A connection that opens but never subscribes is a leak. Coinbase's public API enforces a 5-second window: if the client does not send `subscribe` within 5s, the connection is closed. This bounds idle connection cost during connection storms.

### Sequence Numbers and Gap Detection

Every message for a given pair carries a monotonic `sequence`. Client logic:

```
on_message(msg):
  if msg.sequence == last_sequence[msg.pair] + 1:
    apply(msg)
    last_sequence[msg.pair] = msg.sequence
  else if msg.sequence > last_sequence[msg.pair] + 1:
    // gap detected
    request_resnapshot(msg.pair)
  else:
    // duplicate or out-of-order, ignore
    pass
```

Gap detection is the **client's responsibility** (because the server cannot know what the client missed during a TCP (Transmission Control Protocol)-level loss or reconnection). The protocol exposes the necessary information; the client implements the logic.

### Resume After Reconnect

On reconnect:
1. Client sends `subscribe` with `last_sequence` per pair.
2. Edge asks the regional fan-out worker for everything since `last_sequence`.
3. If the regional worker still has those messages buffered (recent past), it backfills incrementally.
4. If they are too old (rare -- buffers are tens of seconds deep), the worker returns a fresh `level2_snapshot` and resumes from there.

The cutoff is operationally-tuned. In practice: hold ~30s of message history in the regional fan-out's circular buffer per pair. If a client is offline longer than that, they get a snapshot -- which is fine because they were going to render a fresh page anyway.

### Protocol Message Types

| Type | Direction | Purpose |
|---|---|---|
| `subscribe` | C -> S | Request channels for one or more pairs |
| `unsubscribe` | C -> S | Drop channels / pairs |
| `subscriptions` | S -> C | Confirm active subscriptions |
| `level2_snapshot` | S -> C | Full book state, sent on subscribe and on resnapshot |
| `level2_update` | S -> C | Incremental book diff |
| `ticker_update` | S -> C | Batched ticker change |
| `trade_event` | S -> C | Executed trade |
| `kline` | S -> C | Closed candle for an interval |
| `error` | S -> C | Subscription errors, sequence gaps |
| `ping` / `pong` | both | Liveness / heartbeat |
| `disconnect` | S -> C | Server is closing connection (with reason) |

---

## Step 7: Conflation and Backpressure

The single hardest operational problem in this system is the **slow consumer**. A mobile client on a saturated 3G link cannot consume 5K msg/sec. A bot with a slow GC pause stalls for 200ms. Without explicit handling, slow consumers either back-pressure the system (catastrophic) or accumulate unbounded buffers (memory leak, eventual OOM).

### The Drop-Old-Keep-New Policy

For ticker and market summary channels, a stale tick has zero value -- nobody cares what the price was 800ms ago. Conflation policy:

```
on tick for pair P:
  if connection has pending tick for pair P in buffer:
    replace it
  else:
    enqueue
```

This is a **per-pair coalescing buffer**. The buffer holds at most one pending message per (pair, channel). When the connection drains, it sends the latest. The middle ticks are dropped. The client sees a smooth-but-decimated stream that always converges on truth.

### Level2: Cannot Conflate Diffs

You cannot drop a level2 diff; the book reconstruction would diverge. So level2 has a different policy: **buffer up to N diffs, then resnapshot**.

```
on level2_update for pair P:
  if pending_buffer[P].size < CAP:
    enqueue
  else:
    drop the entire pending buffer for P
    enqueue level2_snapshot for P (fresh state)
```

This is the **kick-and-resnapshot** pattern. Behind a slow consumer, the server gives up on incremental diffs and sends a single snapshot when the connection drains. The snapshot is heavier (3KB) than several diffs but bounded.

### Per-Connection Buffer Caps

Every WebSocket connection has a **bounded send buffer** at the edge terminator. Typical: 1MB per connection. If write to the socket would exceed this:

1. First, try to apply conflation (collapse pending ticks for same pair).
2. If still over cap, send a `disconnect { reason: "buffer overflow" }` frame and close the socket.
3. Client reconnects, requests snapshot, resumes.

A kick is preferable to OOM. A disconnected client is a self-healing event; an OOM'd terminator takes thousands of clients down with it.

### Why Slowest-Consumer-Wins Is the Failure Mode

The naive bug: producer holds a single buffer, broadcasts to N subscribers, blocks on the slowest socket write. One slow client cascades into degraded latency for all clients sharing that producer. Avoided by:

1. **Per-consumer cursors** at the bus tier (no shared queue).
2. **Per-connection buffers** at the edge tier (no shared output queue).
3. **Bounded buffers + drop policies** (no slow path waiting for fast path).

Every level of the stack must be designed to **never let a slow consumer slow a fast one**.

---

## Step 8: Storage Tiers

Market data has wildly different access patterns at different time horizons. The right answer is a **tiered storage strategy**, with each tier optimized for its access pattern.

### Tier 1: In-Memory Ring Buffer (sub-second hot path)

- Per-pair LMAX ring buffer in the regional fan-out worker, ~30 seconds deep.
- Backs gap-fill on reconnect.
- Backs the live feed.
- Cost: ~30s x 5K msg/s x 200 bytes x 2000 pairs = ~6 GB per worker. Fits in RAM.

### Tier 2: Redis ZSET (top-N trending and market summary)

- One sorted set per dimension (volume_24h, change_24h, market_cap).
- Score = the dimension value; member = pair symbol.
- `ZREVRANGE 0 99` returns top-100 by volume in O(log N).
- Updated every 1-5 seconds by a market summary aggregator.

```
ZADD market:volume_24h 12453.91 BTC-USD
ZADD market:volume_24h 8231.45 ETH-USD
ZREVRANGE market:volume_24h 0 99 WITHSCORES
```

This is exactly the right Redis primitive for "top-N trending." It backs the Coinbase Explore homepage in O(log N) per query without touching a database.

### Tier 3: Time-Series Store (K-line history, charts)

- TimescaleDB or InfluxDB. Hypertables partitioned by time, indexed by pair.
- One row per (pair, interval, open_time).
- Queries: "give me 1m candles for BTC-USD for the last 24h" -- a partition-pruned scan.
- Multi-interval pre-aggregation: write 1m candles, downsample to 5m / 1h / 1d via continuous aggregates.

```sql
CREATE TABLE klines (
  pair        TEXT NOT NULL,
  interval    TEXT NOT NULL,
  open_time   TIMESTAMPTZ NOT NULL,
  open        NUMERIC NOT NULL,
  high        NUMERIC NOT NULL,
  low         NUMERIC NOT NULL,
  close       NUMERIC NOT NULL,
  volume      NUMERIC NOT NULL,
  trade_count INT NOT NULL,
  PRIMARY KEY (pair, interval, open_time)
);
SELECT create_hypertable('klines', 'open_time');
```

Why not use a relational OLTP database? K-line writes are append-heavy time-stamped data; Postgres alone struggles past tens of thousands of inserts/sec across all pairs. Timescale's hypertables and compression buy 10-100x on this workload.

### Tier 4: S3 Cold Archive

- Compressed parquet files of the full trade tape, partitioned by date and pair.
- Used for institutional backfill ("give me every BTC-USD trade for Q1 2025"), regulatory replay, and ML training.
- Hot tier (Timescale) keeps ~90 days; older data evicts to S3.
- Query path: a separate analytics endpoint, not the live feed.

### Why Not Just Kafka for Everything

Kafka is fine as the **transport** between matching engine and fan-out, but it is not a substitute for:
- The in-memory ring (latency floor of Kafka is ~5ms; the ring is sub-microsecond).
- A time-series store (Kafka can't answer "give me OHLC for BTC-USD last 24h" without a derived consumer).
- Redis ZSET (Kafka has no sorted-set primitive).

Kafka is one piece of the puzzle, not the whole puzzle.

---

## Step 9: Initial Page Load Path

When a user opens the Coinbase Explore page for the first time, they need to see prices **before** the WebSocket establishes. The WebSocket is for live updates; the initial paint comes from REST.

### REST Snapshot Endpoints

```
GET /v1/market/summary           -> top 100 pairs with last price + 24h stats
GET /v1/market/ticker/BTC-USD    -> single pair ticker
GET /v1/market/depth/BTC-USD     -> level2 snapshot
GET /v1/market/trades/BTC-USD    -> last 100 trades
GET /v1/market/klines/BTC-USD    -> K-line for chart
```

### CDN Caching

All of these endpoints are cacheable for 1-5 seconds at the CDN edge (Cloudflare or CloudFront in front of the API):

- `Cache-Control: public, max-age=2, stale-while-revalidate=10`
- During a homepage flash crowd, the CDN absorbs 99%+ of traffic. The origin sees ~one request per pair per region per second instead of millions.

This is the pattern: **bursty, repetitive read traffic goes to the CDN**. The WebSocket feed picks up live updates after the initial paint.

### REST + WebSocket Handoff

```
1. Browser loads Coinbase Explore.
2. REST fetch of /market/summary (CDN-cached) -> render homepage.
3. JavaScript opens WebSocket connection.
4. WebSocket subscribes to ticker for visible pairs.
5. Server sends current ticker (matches REST snapshot or close).
6. Subsequent updates stream live.
```

The transition is seamless because both the REST snapshot and the WebSocket feed converge on the same source of truth, and the snapshot's freshness window (1-2s stale) is well within human perception.

### Why Not WebSocket-Only

A WebSocket-only initial load means every client opens a connection just to render a page. Connection setup is expensive (TCP + TLS = ~3 round trips, ~150ms on mobile). Worse, the homepage flash crowd would create a connection storm rather than a CDN-absorbable HTTP burst. REST + CDN handles flash crowds cleanly; WebSocket connections are reserved for clients that actually need live updates.

---

## Step 10: Multi-Region Topology

Coinbase serves users globally. A single-region market data system means a Sydney user pays 200ms to get a tick from US-East. We need regional fan-out, but the matching engine itself is single-region (the trading engine is centralized for fairness reasons).

### Topology

```
US-East (matching engines, core bus)
  |
  | dedicated cross-region link, ~70ms to EU, ~150ms to AP
  |
  +-- US-East fan-out cluster -> US clients (LAN latency)
  +-- EU-West fan-out cluster -> EU clients (LAN latency, 70ms upstream)
  +-- AP-Southeast fan-out cluster -> AP clients (LAN latency, 150ms upstream)
```

The matching engine takes the cross-region hop **once per region**, not once per client. Inside a region, the fan-out is local and sub-ms.

### Anycast for Routing

Clients connect to a global DNS hostname (`ws-feed.coinbase.com`). Behind it, a global anycast IP routes the connection to the nearest region's WebSocket terminator. No client logic needed for region selection.

### What's Globally Consistent vs Regional

- **Live ticker / level2 / trades:** regional fan-out, no cross-region read consistency required (the data is broadcast from one source, just replicated to each region).
- **K-line / historical:** stored in the time-series cluster; replicated cross-region with eventual consistency (~seconds). A user fetching last week's BTC chart sees the same data in EU and US.
- **Top-N trending:** the Redis ZSET cluster in each region is fed from the same aggregator, eventually consistent. A few-second skew between regions is acceptable for market summary.

### Cross-Region Failover

If US-East fails, the EU fan-out cluster cannot serve trades because the matching engines are gone. The system enters a **read-only degraded mode**: serve last-known K-line, freeze the order book at last state, surface a banner. Trading is halted until US-East recovers (or is failed over to a hot standby region).

This is the deliberate trade-off: market data fan-out is highly available, but the matching engine is the bottleneck on availability. Coinbase has a documented degradation: trading halts before bad market data is served.

---

## Step 11: Volatility Scaling

The 10x scenario is real. When BTC pumps 8% in 20 minutes:
- Trade volume spikes 10x.
- Message rate per pair spikes 10x.
- Concurrent connections spike 5-10x (people open the app to check prices).
- Bandwidth spikes 50-100x (bigger ticks plus more clients).

The system must absorb this without melting.

### Predictive Autoscaling

Coinbase publishes that they use ML models to **predict load 60 minutes ahead** based on signals like:
- Off-platform price action (other exchanges spiking ahead of Coinbase).
- News / social sentiment for major assets.
- Time-of-day / day-of-week baselines.
- Macro signals (Fed announcements, regulatory news).

When the predictor fires, the orchestrator pre-warms additional fan-out workers and edge terminators. Pre-warmed capacity has connections ready, JIT compiled, and warm caches -- it can absorb a spike in seconds, where cold-starting a pod takes 30-60s.

### Reactive Autoscaling

The predictor is not perfect. A flash news event can spike load in seconds. The reactive layer:
- **CPU-based HPA** on edge terminators.
- **Connection-count-based HPA** on edge terminators (a pod is full at 10K connections, scale before).
- **Bandwidth-based HPA** on regional fan-out (network-bound, not CPU-bound).
- All three trigger in parallel; whichever hits first scales out.

### Connection Limits and Fair Queueing

Per-pod connection budget: 10,000-20,000 concurrent WebSockets per terminator. Beyond that, the OS and event loop choke. Total fleet: 1000-5000 terminators per region = 10M-100M concurrent.

When all terminators are full, the load balancer rejects with `503` -- but with a `Retry-After: 30` header. Clients back off and retry. This is **better than accepting and dropping mid-stream**, which causes a reconnect storm.

Within a connection, **fair queueing across pairs**: a single client subscribing to all 2000 pairs cannot starve another client subscribing to one pair. Each subscription has its own conflation buffer, drained round-robin.

### Bandwidth Compression

`permessage-deflate` (RFC 7692) gives 50-70% compression on JSON market data. The cost is server CPU. During steady state, it's optional (the client requests it). During spikes, it can be made mandatory for high-volume channels to keep bandwidth manageable.

---

## Step 12: Failure Modes and Operational Resilience

### Failure: Regional Fan-Out Cluster Loses a Node

Edge terminators downstream of the dead node detect the disconnect. They reconnect to a sibling fan-out worker. Each terminator caches its connections' subscriptions, so the resubscribe is automatic.

Clients see a brief gap, detect the sequence-number jump, and resnapshot. Total client-perceived blip: 1-3 seconds.

### Failure: Slow-Client Storm (Mobile Reconnect After App Update)

When 5M mobile clients come back online simultaneously after an iOS update, they all try to reconnect at once.

- **Stagger reconnects with jitter.** Client SDK adds `0..30s` of random delay before reconnecting after a clean shutdown.
- **Connection rate-limiting at the LB.** Cap new connections per second per IP / per pop.
- **Snapshot caching.** A regional fan-out worker getting hit with 100K snapshot requests in a second serves them from a 1-second-stale shared cache rather than constructing fresh per-request.

### Failure: Sequence Gap Storm (Bad Deploy on Fan-Out)

A bad fan-out deploy drops messages. Every connected client detects gaps and triggers resnapshot. This can amplify into a self-DOS if not handled.

- **Server-side rate limiting on resnapshot requests.** A single client triggering more than N resnapshots/min for the same pair gets throttled.
- **Bulk snapshot service.** When the gap is universal (deploy bug), the server can broadcast a `level2_snapshot` to all subscribers of that pair pre-emptively, avoiding millions of explicit requests.

### Failure: Matching Engine Fail-Over

The matching engine for BTC-USD fails over to a hot standby (sub-second, via Aeron Cluster consensus). The new leader picks up the sequence number where the old one left off. The market data bus sees a brief gap, then resumes.

For market data subscribers, this is just a brief sequence-gap event. They resnapshot from the regional fan-out worker, which still has the last snapshot in memory.

### Failure: Sticky LB Pinning Breaks During Deploy

Edge terminator pods are stateful in one sense: they own client connections. A rolling deploy must drain connections gracefully:

1. Deploy controller sends `SIGTERM` to a pod.
2. Pod stops accepting new connections (LB removes it from rotation).
3. Pod sends `disconnect { reason: "shutdown", retry_after: 0 }` to all connected clients.
4. Clients reconnect, hit a different pod, resume subscriptions with last_sequence.
5. Pod waits up to 30s for in-flight messages to flush, then exits.

Without graceful drain, a deploy disconnects millions of clients abruptly, all of whom retry simultaneously -- exactly the slow-client storm above.

### Monitoring and Alerting

Critical metrics:
- **End-to-end latency**: matching engine fill timestamp to client receipt timestamp (sampled). p50, p99, p99.9.
- **Producer cursor vs slowest consumer cursor** at each tier. Lag = (producer - slowest_consumer). Alert on > 1s.
- **Per-connection buffer occupancy.** Histogram. Alert on tail > 80% cap.
- **Resnapshot rate.** Spike means lots of clients are seeing gaps.
- **WebSocket connection churn.** New connections per second + closures per second. Spike pattern indicates instability.
- **Drop count per pair.** Conflation drops are normal; spikes indicate slow-consumer pressure.
- **CDN cache hit rate** on snapshot REST. Dropping below 90% means the origin is exposed.

---

## Step 13: Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Bus structure | LMAX-style ring buffer | Go channels / Kafka | Sub-microsecond, no GC, slow consumers don't gate producer |
| Slow consumer policy | Conflate, then kick | Block, then OOM | Producer must never wait; bounded buffers prevent OOM |
| Order book delivery | Snapshot + diff | Full snapshot every tick | Diffs are 100x smaller; resnapshot only on gap |
| Subscription protocol | WebSocket | SSE (Server-Sent Events — one-way HTTP streaming from server to client) / HTTP/2 (HTTP version supporting multiplexed streams and server push) push | Bidirectional sub/unsub, lower overhead per message |
| Fan-out topology | Multi-tier pyramid | One-broker-fan-out | Single broker can't fan out to millions; tiered scales linearly |
| Initial page load | REST + CDN, then WS upgrade | WebSocket-only | CDN absorbs flash crowds; WS reserved for live updates |
| Per-pair vs global ordering | Per-pair only | Global sequence | Global serializes the exchange; per-pair is sufficient and parallelizable |
| K-line storage | Time-series DB (Timescale) | Postgres OLTP | Time-series append patterns + compression are 10-100x cheaper |
| Top-N trending | Redis ZSET | DB GROUP BY ORDER BY | O(log N) reads vs full table scan |
| Multi-region | Regional fan-out, central engine | Multi-region engine | Engine fairness and latency demand single-writer; data plane regionalizes cleanly |
| Conflation policy | Drop-old keep-new (ticker), buffer + resnapshot (level2) | Block until delivered | Stale ticks are worthless; book diffs cannot be dropped |
| Compression | Optional permessage-deflate | Always-on / never | Client-negotiated; mandatory during volatility |

---

## Step 14: Common Mistakes to Avoid

1. **One Kafka topic per pair, scaled to millions of subscribers.** Kafka brokers cannot handle millions of consumer-group members on one topic; partition assignment churn alone melts the cluster. The right shape is multi-tier fan-out with brokers (or in-memory rings) at the source and stateless terminators at the edge.

2. **No conflation, treating every tick as must-deliver.** A slow client receives every tick, falls behind, accumulates buffer, and OOMs the terminator. The whole pod takes thousands of healthy clients with it. Conflation (drop-old-keep-new for tickers, kick-and-resnapshot for level2) is non-negotiable.

3. **Broadcasting through one central node.** A single fan-out node holding all subscriber connections is a single point of failure and a single bottleneck. Sharded by pair across multiple nodes. Connections distributed across thousands of edge terminators.

4. **No gap-detection protocol.** Without sequence numbers, a client cannot detect missed messages from a lost packet or reconnection. The protocol must include monotonic sequences and a documented resume path. The client SDK enforces gap detection; the server provides resnapshot.

5. **Treating mobile and web as identical.** Mobile is bandwidth/battery/CPU constrained. The same firehose that a desktop browser handles in a tab will drain a phone battery in 30 minutes and saturate a 3G link. Mobile gets aggressive default conflation, partial subscriptions (visible pairs only), and tighter buffer caps.

6. **Channel-based fan-out in Go.** Go channels block on send, allocate per send, and create one channel per consumer. Under millions of msg/sec across thousands of subscribers, GC and lock contention dominate. The 38x latency reduction Coinbase shipped in 2025 came from replacing channels with LMAX rings.

7. **Coupling K-line aggregation to the hot path.** If the hot path waits on Timescale inserts, a K-line storage hiccup pauses the live feed. K-line aggregation runs in a separate consumer with its own backpressure; hot path never waits on history persistence.

8. **No sticky load balancer or no graceful drain.** A round-robin LB redistributes clients on every deploy, causing connection storms. A non-draining deploy disconnects everyone abruptly. Sticky LB + graceful drain (SIGTERM, stop-accepting, broadcast disconnect, wait, exit) keeps reconnect rates manageable.

9. **No predictive autoscaling for known volatility.** The big spikes are signaled minutes ahead by off-platform price action and news. Reactive autoscaling alone takes 30-60s to add capacity, which is too slow for a 10x flash. Pre-warming based on prediction adds capacity before the spike arrives.

10. **Building resnapshot as a per-client recompute.** When 100K clients all need resnapshot at once (gap storm), generating fresh per-request overwhelms the regional worker. Cache the snapshot per pair with 1s freshness; serve all concurrent requests from the same cached blob.

---

## Step 15: Follow-up Questions

**How would you add a new asset class -- say, perpetual futures with funding rates?**

The matching engine emits a new event type (`funding_rate_event`). The market data bus is per-pair regardless of asset class, so no architectural change. The wire protocol gets a new channel name (`funding`) and message type. K-line aggregator picks up perp-specific fields (mark price, index price). The data model and tier breakdown stay the same; only the schema is extended.

**How do you charge for a low-latency feed (institutional vs retail tier)?**

Two-tier protocol: same WebSocket endpoint, but auth-based subscription paths. Retail gets default conflation (drop-old-keep-new at ~10Hz). Institutional gets uncompacted level2 + every tick + lower conflation thresholds. The fan-out tier inspects the subscription's auth claim and routes to a different per-connection policy. Billing instruments at the auth gateway (counted by message volume or flat fee per pair-month). The architecture has only one stream; the tier difference is a per-connection policy applied at the edge.

**How would you ensure best-execution requirements for the public feed?**

Best-execution regulation requires that the public market data is not lagged behind a private feed delivered to favored subscribers. This means:
- All public subscribers see the same conflation policy at the same tier.
- No "latency arbitrage" path where some clients get bytes faster than others (ban co-located fast paths for the public feed).
- Audit log: every message published to the public bus is timestamped at the producer and re-timestamped at the edge; SLA (Service Level Agreement) on the gap. Periodic compliance reports show distributions.
- The trade tape published to the public WebSocket is sequenced identically to the trade tape sent to internal services -- one source, fan-out from there.

**How would you ship a level3 (full order book, individual orders) feed for institutional clients?**

Level3 is unbatched: every order place, modify, cancel, fill is a separate event. Volume is 10-100x level2. Architecture changes:
- Separate WebSocket endpoint with stricter auth and rate-limiting (level3 clients are vetted).
- Different fan-out path with no conflation -- every order event matters for institutional reconstruction.
- Higher per-connection bandwidth (10-100 Mbps per institutional connection).
- Smaller fan-out factor (level3 has hundreds, not millions, of subscribers).
- Direct path from matching engine to a dedicated level3 fan-out, parallel to the level2 path; level2 is conflated, level3 is not.

**What if a single pair (BTC-USD) generates 50% of total system load -- how do you avoid noisy-neighbor?**

The fan-out tiers are already sharded by pair, so BTC-USD has its own dedicated set of fan-out workers. If BTC-USD load spikes, autoscaling adds workers for that pair only; other pairs are unaffected. At the edge, a pod hosting clients with diverse subscriptions still runs fair queueing per-pair within each connection, so a heavy BTC-USD subscriber doesn't starve their ETH-USD subscription. The pyramid topology naturally isolates per-pair load -- the only shared resource is the edge terminator's connection budget, which is isolated by client.

**How do you detect a misbehaving / abusive client?**

Per-connection metrics at the edge: subscribed pair count, message receipt rate, buffer occupancy, reconnect frequency. Outliers (subscribing to all 2000 pairs and constantly reconnecting) get rate-limited or banned at the LB layer. The pattern matching is straightforward; the harder problem is distinguishing a legitimate institutional bot from an abusive one, which is solved by auth tier (institutional clients pre-declare their expected load profile during onboarding).

---

## Related Topics

- [[../../../07-real-time-systems/index|Real-Time Systems]] -- WebSocket fan-out, ring buffers, conflation, snapshot+diff protocols
- [[../../../02-scaling-reads/index|Scaling Reads]] -- multi-tier fan-out, CDN-cached snapshots, regional edge replication
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- slow-consumer isolation, gap-and-resnapshot, predictive autoscaling
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- per-pair sequencing, regional vs global ordering, anycast routing
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- LMAX ring buffer, time-series stores (Timescale/Influx), Redis ZSET for top-N
- [[../../../05-async-processing/index|Async Processing]] -- K-line aggregation pipelines, S3 cold archive, separate fan-out path from hot loop
- [[01-trading-engine/PROMPT|Coinbase Trading Engine]] -- the upstream producer this design consumes
