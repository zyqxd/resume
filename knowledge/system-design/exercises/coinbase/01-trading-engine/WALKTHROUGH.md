# Walkthrough: Design a Crypto Order Matching Engine (Coinbase)

## Step 1: Clarify Requirements and Scope

Before drawing anything, lock down the scope. A trading engine is a system where naming the wrong primary axis costs you the round.

- Spot only, or do we need derivatives? (Spot only for this round; mention perpetuals as a follow-up.)
- What latency budget? (Sub-50us internal matching, sub-1ms wire p99. This shapes every choice.)
- What throughput? (100K-2M orders/sec aggregate; per-pair the hot pairs see 50-100K/sec during BTC pumps.)
- How many trading pairs? (Hundreds. Each is independent.)
- What durability guarantee? (RPO (Recovery Point Objective — DR target) = 0. We do not lose a single accepted order. RTO (Recovery Time Objective — DR target) = seconds.)
- Is the matching engine the source of truth for balances? (No. Balances live in the ledger. The matching engine holds against pre-checked balance reservations.)
- 24/7? (Yes. No market close, no daily settlement window. This is the hardest part.)
- Regulated? (Yes -- US SEC/CFTC, Bermuda for Coinbase International (Bermuda-regulated 24/7 derivatives exchange). Audit trail is non-negotiable.)

**Primary design constraint:** Latency and determinism. Every architectural choice filters through "does this add latency to the matching hot loop, and is the resulting state deterministically reproducible from the WAL (Write-Ahead Log — append-only durability log written before in-memory state mutates)?" If the answer to the second question is no, the design fails compliance and recovery.

**The single staff-level move that sets up the whole answer:** Split the system into two paths from the start.

1. **Trading hot loop** -- sequencer, risk gateway, matching engine, WAL, fill emitter. Sub-millisecond budget. Every microsecond matters. Single-threaded matching, kernel bypass where possible, no GC pauses, no network hops we don't have to make.
2. **Market data fan-out path** -- WebSocket gateways pushing trades, ticker updates, and level2 snapshots to thousands of subscribers. Throughput-optimized, batched, lossy at the edge if we have to drop. Completely separate failure domain from the hot loop.

If you mix these two, you've already lost. The fan-out path's load patterns (slow consumers, head-of-line blocking) will poison the hot loop. Stating this split up front is the single highest-leverage move in this interview.

---

## Step 2: High-Level Architecture

```
       Clients (REST/FIX/WebSocket order entry)
                       |
                       v
       +----------------------------------+
       |   Order Gateway (auth, rate      |
       |   limit, protocol translation)   |
       +----------------+-----------------+
                        |
                        v
       +----------------------------------+
       |   Risk Gateway (balance / margin |
       |   pre-check, idempotent holds)   |
       +----------------+-----------------+
                        |
                        v
       +----------------------------------+
       |   Sequencer (assigns monotonic   |
       |   sequence numbers per pair)     |
       +----------------+-----------------+
                        |
            (Aeron Cluster / RAFT)
                        |
       +----------------v-----------------+
       |   Matching Engine (per-pair,     |
       |   single-threaded, in-memory     |
       |   order book, deterministic)     |
       |                                  |
       |   --> NVMe WAL (sync write)      |
       |   --> Fill Emitter               |
       +-----+---------------------+------+
             |                     |
             v                     v
   +-----------------+    +-------------------+
   | Settlement Bus  |    | Market Data Bus   |
   | (Kafka)         |    | (ring buffer)     |
   +--------+--------+    +---------+---------+
            |                       |
            v                       v
   +-----------------+    +-------------------+
   | Ledger Service  |    | WS Fan-Out Gateways|
   | (Aurora,        |    | (1000s of subs)   |
   | double-entry)   |    +-------------------+
   +-----------------+
```

### Core Components

1. **Order Gateway** -- terminates client connections (REST, FIX (Financial Information eXchange — standard order-entry protocol), WebSocket). Authenticates, rate limits per API key, translates wire format into the internal order struct.
2. **Risk Gateway** -- balance and margin verification *before* the order reaches the matching engine. Places idempotent holds against the ledger. The matching engine assumes risk has already approved.
3. **Sequencer** -- assigns a monotonic sequence number per trading pair. This is the linearization point. Anything before the sequencer is concurrent; anything after is strictly ordered.
4. **Matching Engine** -- single-threaded per trading pair. In-memory order book. Deterministic given the sequenced input log.
5. **NVMe (Non-Volatile Memory Express — protocol for fast SSDs over PCIe) WAL** -- durable write-ahead log. Every accepted order and matched fill is fsynced before acknowledgment. This is the durability anchor.
6. **Aeron Cluster (open-source low-latency messaging library with built-in RAFT consensus) + RAFT (consensus algorithm where a leader replicates an ordered log to a majority quorum of followers)** -- replicates the *sequenced input log*, not the order book state. Three or five replicas reach consensus on the next sequence entry. The matching engine on each replica deterministically derives identical state.
7. **Fill Emitter** -- emits matched-trade events to two destinations: the settlement bus (Kafka -> ledger) and the market data bus (ring buffer -> WebSocket gateways).
8. **Market Data Fan-Out** -- LMAX-Disruptor (lock-free fixed-size ring-buffer pattern from LMAX Exchange)-style ring buffer feeds N WebSocket gateway processes; each gateway pushes to its slice of subscribers.
9. **Ledger Service** -- consumes settlement events, performs double-entry bookkeeping, writes to Amazon Aurora (AWS managed Postgres/MySQL with read scaling and fast failover). Source of truth for balances.

---

## Step 3: Data Model

### In-Memory Matching Engine State

The order book is a hot in-memory structure. Persistence is via the WAL, not via writing the book itself.

```
OrderBook (per trading pair)
+-------------------------------------------+
|  bids: PriceLevel[] (sorted desc by price)|
|  asks: PriceLevel[] (sorted asc by price) |
|  by_id: HashMap<OrderId, OrderRef>        |
|  last_seq: u64                            |
+-------------------------------------------+

PriceLevel
+-------------------------------------------+
|  price: Decimal                           |
|  total_qty: Decimal                       |
|  orders: DoublyLinkedList<Order> (FIFO)   |
+-------------------------------------------+

Order
+-------------------------------------------+
|  id: OrderId                              |
|  client_order_id: String  (idempotency)   |
|  user_id: u64                             |
|  side: Buy | Sell                         |
|  type: Limit | Market | StopLimit | ...   |
|  flags: PostOnly | IOC | FOK              |
|  price: Decimal (None for market)         |
|  qty_remaining: Decimal                   |
|  qty_total: Decimal                       |
|  enqueued_seq: u64  (time priority)       |
|  hold_id: HoldId  (link to risk gateway)  |
+-------------------------------------------+
```

**Why doubly linked list per price level:** O(1) insertion at the tail (time priority), O(1) cancel by id (we keep the node pointer in `by_id`). A heap would force log(n) cancels and break FIFO.

### Persisted State (WAL records)

```
WalRecord (append-only, NVMe-backed, fsynced)
+-------------------------------------------+
|  seq: u64                                 |
|  pair_id: u32                             |
|  ts_ns: u64  (nanosecond timestamp)       |
|  payload: OrderInput | Cancel | ReplaceIn |
+-------------------------------------------+
```

Fills are *derived*, not logged separately on the input WAL. They are emitted on a separate output log:

```sql
-- Settlement-side, in Aurora (consumed via the ledger).
fills (
  fill_id          BIGINT PRIMARY KEY,
  pair_id          INT NOT NULL,
  seq              BIGINT NOT NULL,        -- input seq that produced this fill
  taker_order_id   BIGINT NOT NULL,
  maker_order_id   BIGINT NOT NULL,
  taker_user_id    BIGINT NOT NULL,
  maker_user_id    BIGINT NOT NULL,
  price            NUMERIC(38, 18) NOT NULL,
  qty              NUMERIC(38, 18) NOT NULL,
  fee_taker        NUMERIC(38, 18) NOT NULL,
  fee_maker        NUMERIC(38, 18) NOT NULL,
  ts_ns            BIGINT NOT NULL,
  UNIQUE (pair_id, seq, taker_order_id, maker_order_id)
);

-- Level 2 snapshot, periodically written for fast cold-start of subscribers.
l2_snapshots (
  pair_id          INT NOT NULL,
  seq              BIGINT NOT NULL,
  bids             JSONB NOT NULL,         -- [[price, qty], ...]
  asks             JSONB NOT NULL,
  taken_at         TIMESTAMP NOT NULL,
  PRIMARY KEY (pair_id, seq)
);

-- Sequencer state, replicated via RAFT.
sequencer_state (
  pair_id          INT PRIMARY KEY,
  last_seq         BIGINT NOT NULL,
  last_committed_at TIMESTAMP NOT NULL
);
```

### Key Schema Decisions

**`NUMERIC(38, 18)` for price and qty:** Never floats. IEEE 754 rounding errors compound on every fill. Crypto needs 18 decimal places for some tokens. Integer satoshis is also valid; Coinbase uses fixed-point decimals throughout.

**`seq` as the linearization clock:** Wall-clock time is a lie in a distributed system. `seq` is the only ordering that matters inside the engine.

**`UNIQUE (pair_id, seq, taker_order_id, maker_order_id)`:** Fills are idempotent on replay. Re-applying the WAL produces the same fill rows.

**`hold_id` on Order:** Each order carries the risk gateway's hold reference. When the order fills or cancels, we settle (release or capture) the hold by id. No separate balance lookup at fill time.

---

## Step 4: The Trading Hot Loop

This is where the latency budget lives. End-to-end target: under 1ms wire-to-wire p99, under 50us internal from sequencer ingest to fill emission. Walk through each step with the latency cost.

### Step-by-Step

```
1. Client sends NewOrder over WebSocket/FIX/REST
2. Order Gateway (~50us)
   - TLS termination
   - Auth check (cached API key -> user_id)
   - Per-API-key rate limit (Redis token bucket)
   - Wire format -> internal struct
   - Hand off to Risk Gateway
3. Risk Gateway (~100-200us)
   - Read user balance / margin from local cache
   - Verify available >= notional + fees
   - Place idempotent hold in ledger (async, fire-and-forget with future)
   - Hand off to Sequencer
4. Sequencer (~5us)
   - Assign next seq for this pair
   - Append to WAL
   - Replicate via Aeron/RAFT (synchronous, ~100us round trip)
5. Matching Engine (~10-30us)
   - Apply order to book
   - Match against opposite side
   - Emit zero or more fills
   - Update remaining qty
6. Fill Emitter (~5us)
   - Push fills to settlement bus (Kafka)
   - Push level2 deltas + trades to market data ring buffer
7. Order Gateway sends ACK to client
```

### Why Each Step Lives Where It Does

**Why is risk pre-check before the sequencer, not inside the matching engine?** The matching engine is single-threaded. Every microsecond it spends doing balance lookups is a microsecond it cannot match. Pre-checking and stamping a hold token converts a per-order ledger query into a parallel, async operation that does not block matching. The matching engine assumes pre-approval and just settles the hold post-fill.

**Why is the sequencer separate from the matching engine?** Two reasons. First, it isolates the consensus / replication step from matching, so a slow RAFT round doesn't add to the matching critical section. Second, it gives us a clean linearization point -- everything before is async/parallel, everything after is strictly ordered.

**Why single-threaded matching?** Determinism. A single thread on one core, processing the input log in order, will produce identical output on every replica given identical input. Multi-threaded matching introduces race conditions that break replay. Coinbase, LMAX, Nasdaq, and every serious exchange runs single-threaded matching per book. You scale by sharding pairs across cores/hosts, not by parallelizing within a pair.

**Rejected alternative: lock-based multi-threaded matching.** Locks on price levels seem like a way to scale, but: (1) the contention point on the top-of-book is exactly where you want maximum throughput, (2) lock acquisition is 50-200ns even uncontended, (3) deterministic replay becomes nearly impossible. We trade peak throughput per pair for determinism and per-pair latency. Sharding by pair gets us the aggregate throughput without giving up either.

### What "Sub-50us Internal" Means in Practice

- The matching engine runs on a dedicated core, pinned, with hyperthreading off and IRQs steered away.
- No GC: Go with careful allocation discipline (sync.Pool for hot objects), or Rust/C++ with arena allocators.
- No syscalls in the hot path. Aeron Cluster does kernel-bypass messaging via shared memory.
- WAL writes go to NVMe with O_DIRECT; we batch fsyncs in groups of N orders to amortize the fence cost.
- EC2 cluster placement groups so all replicas are on the same rack; sub-100us round-trip RAFT.

---

## Step 5: Order Book Internals

The order book is a price-indexed FIFO queue. Implementation choices have direct latency consequences.

### Data Structure Choice

For each side of the book (bids, asks), we need:

1. Find best price -- O(1) (this is the most common operation; every match starts here).
2. Insert at price level -- O(1) average for an existing level, O(log n) or O(1) for a new level.
3. Cancel by order id -- O(1) to find the order, O(1) to unlink from its level's FIFO.
4. Iterate price levels in order -- only on snapshot rebuild, not in the hot path.

The standard structure: a sorted map keyed by price (skip list, BTree, or array of price buckets) where each value is a doubly linked list of orders. A separate hash map from `OrderId -> OrderRef` makes cancel-by-id O(1).

```
BidBook
  prices: SkipList<Price, PriceLevel>   // descending iteration
  PriceLevel.orders: DoublyLinkedList<Order>
  PriceLevel.total_qty: Decimal

by_id: HashMap<OrderId, *Order>          // O(1) cancel lookup
```

**Skip list vs sorted array vs heap:**

| Structure | Best price | Insert | Cancel by id | Notes |
|---|---|---|---|---|
| Skip list | O(1) cached pointer | O(log n) | O(1) | Standard at exchanges. Probabilistic balance. |
| Sorted array (ladder) | O(1) | O(1) at known index | O(1) | Best for bounded price grids; worst for sparse |
| Min/max heap | O(1) peek | O(log n) | O(n) without aux index | Cancel cost kills it |
| BTree map | O(1) cached | O(log n) | O(1) with id index | Slightly slower constants than skip list |

For BTC-USD, prices have a tick size (0.01 USD). The price space is bounded enough that some implementations use a fixed array of price buckets, indexed by `(price - min) / tick`. Coinbase's matching engine is in Go and uses a sorted map with a doubly linked list per level -- we'll go with that pattern, calling the data structure a skip list since that's the canonical academic name for the access pattern.

### Match Loop

```
on_new_limit_order(order):
  if order.side == Buy:
    while order.qty_remaining > 0 and asks.best_price <= order.price:
      level = asks.best_level()
      maker = level.orders.front()
      qty = min(order.qty_remaining, maker.qty_remaining)
      emit_fill(taker=order, maker=maker, price=level.price, qty=qty)
      order.qty_remaining -= qty
      maker.qty_remaining -= qty
      if maker.qty_remaining == 0:
        level.remove(maker)
        if level.empty():
          asks.remove_level(level.price)
  if order.qty_remaining > 0:
    bids.insert(order)
    by_id.put(order.id, order)
```

Notes:

- The match loop walks one price level at a time. Cascading matches (one taker order eats through multiple maker price levels) are common and produce multiple fills from a single input.
- Order types modify this: `IOC` (Immediate-Or-Cancel — fill what you can now, cancel the rest) skips the final insert (any unfilled qty is canceled); `FOK` (Fill-Or-Kill — fill the entire quantity immediately or cancel) rolls back if it can't fill the full quantity in one go; `post-only` rejects the order if it would cross the spread; `market` ignores the price check.

### Cancel and Replace

```
on_cancel(order_id):
  order = by_id.get(order_id)
  if not order: return CancelReject(reason="unknown order")
  level = book.level_at(order.price, order.side)
  level.remove(order)
  if level.empty():
    book.remove_level(order.price, order.side)
  by_id.remove(order_id)
  release_hold(order.hold_id)
  emit_cancel(order_id)
```

**Replace** is logically Cancel + New, but we keep them as one input record so the WAL replay is atomic. A replace at the same price preserves time priority (Coinbase's docs are explicit on this); a replace at a different price gets a new sequence and goes to the back of the new level. You should mention this -- it's a subtle but real correctness point.

---

## Step 6: Replication and Consensus

We need RPO=0: zero accepted orders lost on failure. We need deterministic replay: every replica derives identical state. We need fast failover: RTO measured in seconds.

### What Gets Replicated

We replicate the *sequenced input log*, not the order book state. This is the key architectural choice.

```
+------------------------+        +------------------------+
| Sequencer Leader       | -----> | Sequencer Follower 1   |
|  - assigns seq         |  RAFT  |  - applies same input  |
|  - writes WAL          |        |  - derives same book   |
|  - matches             |        |                        |
+-----------+------------+        +-----------+------------+
            |                                 |
            v                                 v
       Identical fills produced (deterministic given identical input)
```

Why replicate input not state:

1. **Tiny payload:** an order is ~200 bytes. The book on a hot pair is megabytes. Replicating input is 1000x less data.
2. **Determinism check:** if a follower's derived state diverges from the leader's, you have a bug. This is your built-in correctness audit.
3. **Recovery is replay:** a new replica catches up by replaying the WAL from the last snapshot.

Coinbase uses **Aeron Cluster** for this -- an open-source low-latency messaging layer with RAFT consensus baked in. Aeron handles the cluster membership, leader election, and log replication. The matching engine is the deterministic state machine that consumes the replicated log. The underlying pattern is classic state-machine replication; Aeron is the implementation. Mention Aeron once, then describe what the pattern actually does.

### Leader Election and Failover

- 3 or 5 replicas per pair (3 for cost, 5 for higher fault tolerance).
- RAFT leader is the sequencer; followers replay the same log.
- Heartbeat timeout: ~150ms. On leader loss, a follower is elected within ~300-500ms.
- During failover, order entry is paused (the gateway returns `503 retry-after`). Existing connected sessions are not killed; they sit in a quiesced state.
- After election, the new leader resumes from the last committed seq. No order is lost because every committed seq has been replicated to a quorum before ack.

**RTO budget:** detection (150ms) + election (300ms) + warm-up (100ms) ~= 550ms. Real-world numbers from Coinbase's QCon talk: sub-second failover, single-digit second total impact.

### Why Not Multi-Leader (Active-Active)?

Multi-leader breaks linearizability for the matching engine. Two leaders can't agree on the order of two near-simultaneous orders without consensus, and consensus on every order is exactly what we already have via RAFT. Active-active for matching is a category error. You can do active-active for *order entry* (any gateway can accept orders) but the sequencer is single-leader by necessity.

### Snapshot and Truncation

The WAL grows forever otherwise. Every N seconds (or every M sequences), we take a coherent snapshot of the book state and truncate the WAL up to that snapshot. New replicas bootstrap from the most recent snapshot + replay the tail.

---

## Step 7: Market Data Fan-Out

This is the second of the two paths. Latency-sensitive in aggregate (subscribers want fresh data) but throughput-bound in design (thousands of subscribers per pair, each on a slow TCP connection). The hot-loop matching engine cannot wait for slow subscribers.

### The Producer-Consumer Problem

The matching engine emits fills and book deltas at line rate. Each WebSocket subscriber consumes at its own rate, bounded by their connection bandwidth and any application-level processing. If you connect them with a Go channel, three things go wrong:

1. **Channel allocation pressure** -- channels with buffers cause GC churn at millions of messages per second.
2. **Slow consumer head-of-line blocking** -- one slow consumer fills its buffer and either backs up the producer or forces drops.
3. **Cache contention** -- channel ops touch shared metadata; many subscribers thrash the producer's CPU.

Coinbase's August 2025 blog post documents replacing Go channels with an **LMAX-Disruptor-style ring buffer** -- a fixed-size circular array with sequence-based coordination via `sync.Cond` and per-message reuse via `sync.Pool`. They reported a 38x latency reduction on the fan-out path. The underlying pattern is the LMAX Disruptor; the Go implementation is the specific engineering. Mention "LMAX Disruptor" once and explain what it is: a single-producer-multiple-consumer queue where producers write to a slot whose index is the next sequence, and consumers each track their own read sequence independently.

```
   Matching Engine (producer)
              |
              v
   +-----------------------+
   |   Ring Buffer         |
   |   [slot 0][slot 1]... |   (fixed size, pow-of-2)
   |   producer_seq = 1024 |
   +--+----+----+----+-----+
      |    |    |    |
      v    v    v    v
   Cons1 Cons2 Cons3 Cons4   (each tracks own read_seq)
   |
   v (per-consumer)
   WebSocket Gateway -> N subscribers (TCP fan-out)
```

### Slow-Consumer Handling

If a consumer's read_seq falls too far behind the producer_seq:

- Option A: drop messages for that consumer; mark its WebSocket as degraded; let the client reconnect and snapshot.
- Option B: kick the consumer (close the WebSocket).

We choose Option A by default: prefer staying connected with a snapshot reset over hard-disconnecting. The client gets a `level2_snapshot` followed by incremental `level2_update` messages, and rebuilds state. This is exactly how Coinbase's public WebSocket feed works.

### Batched vs Unbatched Updates

Cascading matches produce many fills from one taker order. Sending each fill as a separate WebSocket message multiplies framing overhead. Coinbase batches updates per sequence:

```
{
  "type": "l2update",
  "product_id": "BTC-USD",
  "sequence": 12345678,
  "changes": [
    ["sell", "67250.00", "0.50"],
    ["sell", "67260.00", "0.0"],   // level cleared
    ["buy",  "67240.00", "1.20"]
  ]
}
```

A single envelope, all the changes from that sequence, one WebSocket frame. Saves a lot of CPU at the gateway and reduces wire bytes.

### Channel Topology

- `ticker` channel: best bid/ask updates only. Smallest, most subscribed.
- `trades` channel: every executed fill.
- `level2` channel: incremental order book updates.
- `level3` (full order book) channel: every order add/cancel. High-volume; usually only for institutional subscribers.

Each channel is a separate ring buffer + gateway pool. A user subscribing to ticker only never pays the cost of level3 fan-out.

---

## Step 8: Risk Pre-Checks and Balance Holds

The matching engine assumes the order is funded. The risk gateway is responsible for that guarantee.

### The Pre-Check Flow

```
on_new_order(order):
  user_balance = balance_cache.get(user_id, asset)   // read-through to ledger
  notional = order.qty * (order.price or marked_to_market)
  fee = notional * fee_rate
  required = notional + fee
  if user_balance.available < required:
    return Reject(reason="insufficient_funds")
  hold = ledger.place_hold(
    user_id=user_id,
    asset=asset,
    amount=required,
    idempotency_key=order.client_order_id,
    ttl=30_minutes
  )
  order.hold_id = hold.id
  forward_to_sequencer(order)
```

### Why Holds, Not Direct Debits

A "hold" reserves balance without moving it. On fill, the hold converts to an actual debit. On cancel, the hold releases. This avoids:

- Settling balance changes mid-order (which would require a ledger round-trip per fill -- too slow).
- Race conditions where a user's balance is debited but the order doesn't fill, leaving phantom credits.

### Idempotency

`client_order_id` is the idempotency key end-to-end:

- The gateway dedupes duplicate submits.
- The risk gateway places at most one hold per `client_order_id`.
- The matching engine rejects duplicate inputs.
- The fill emitter uses `(seq, taker_id, maker_id)` as the natural key.

This is non-negotiable for a trading system. Network retries are common; double-submitted orders are catastrophic.

### TTL on Holds

Holds expire after 30 minutes by default. If the matching engine crashes after the hold is placed but before the order is recorded (vanishingly rare given the WAL-before-ack flow, but possible across the gateway boundary), the hold self-releases. This is the same self-healing pattern used in inventory reservations -- TTL (Time To Live) prevents zombie balance lockup.

### Where Balance Lives

The risk gateway reads from a *local replica* of the ledger's balance projection, not the ledger itself. Reading the ledger on every order would be 5-10ms latency, blowing the budget. Instead:

- Ledger publishes balance change events to Kafka.
- Each risk gateway subscribes and maintains an in-memory balance cache.
- Reads are sub-microsecond (in-process map lookup).
- Writes (holds) go to the ledger directly, but async with respect to matching.

The eventual consistency window is the Kafka lag (typically <1s). During that window, a user could submit an order based on stale balance. This is bounded by the hold mechanism: the ledger rejects holds that exceed actual balance, and the order gets a late reject. We accept this trade-off because the alternative (synchronous ledger reads) destroys latency.

---

## Step 9: Settlement Pipeline

Matched fills must be reflected in the ledger. The ledger is the source of truth for balances.

```
Matching Engine
     |
     v
Fill Emitter -- writes fill record to settlement bus
     |
     v
Kafka topic: trade.fills (partitioned by user_id)
     |
     v
Ledger Service (consumer group)
     |
     v
Aurora: double-entry journal write (atomic)
     |
     v
Balance projection update
     |
     v
Kafka topic: balance.changes -> Risk Gateway cache
```

### Why Kafka Between Matching and Ledger

- **Decoupling for failure isolation:** Aurora hiccup must not stall matching. Kafka is the buffer.
- **Replay:** if the ledger has a bug, we can rewind the consumer group and reprocess.
- **Multiple consumers:** ledger, analytics, tax engine, real-time PnL all consume the same fill stream.

### Double-Entry Bookkeeping

Each fill produces two paired journal entries: one debit, one credit. For a BTC-USD buy at $67,000 for 0.5 BTC with $10 fees:

```
DR  user.usd_account     $33,500 + $10 fee  (decrease USD)
CR  user.btc_account     0.5 BTC            (increase BTC)
DR  fee_revenue          $10                (Coinbase's revenue)
```

The ledger guarantees no transaction commits unless debits equal credits. This is how you provably never lose or create money.

### Idempotency at the Ledger

The fill key `(pair_id, seq, taker_order_id, maker_order_id)` is unique. Aurora has a unique index on it. If the consumer reprocesses the same fill (Kafka at-least-once), the second insert is a no-op. The ledger projection update is similarly idempotent (using the same key as a journal entry id).

### Why Aurora and Not the Same NVMe WAL?

Different access patterns. The matching engine WAL is append-only sequential writes, optimized for fsync latency, and the data is short-lived (truncated on snapshot). The ledger needs:

- Long-term durable storage (multi-year retention for regulatory).
- Complex queries (user balance history, tax events, withdrawals).
- Multi-region replication for read scaling and DR.

Aurora gives us managed Postgres with multi-AZ replication, fast failover, and read replicas. The Coinbase International Exchange runs Aurora for settlement state at 100K msgs/sec; this is well within Aurora's capability when partitioned by user.

---

## Step 10: Volatility Scaling and Circuit Breakers

Crypto markets have 10x volume spikes during BTC rallies or crashes. The system must scale up and, when scaling isn't enough, halt trading rather than corrupt state.

### Predictive Auto-Scaling

Coinbase published an autoscaler post describing an ML model that predicts trading volume 60 minutes ahead with reasonable accuracy. Inputs: BTC spot price velocity, social media volume, historical patterns at this time of day, news event flags. Output: target fleet size for gateways and risk services.

- Gateways and risk gateway scale horizontally -- standard k8s HPA based on the prediction.
- Matching engines do *not* scale horizontally per pair (single-threaded by design). Per-pair throughput is a fixed ceiling; mitigation is sharding *more* pairs onto more cores, not parallelizing one pair.
- Snapchain (Coinbase's internal name for the snapshot/replay system; mention once and move on) builds standby replicas pre-warmed during predicted spikes.

### Circuit Breakers

When price moves >10% in 5 minutes (configurable per pair, per market), trading auto-halts. This is regulatory practice in TradFi (LULD bands at NYSE) and increasingly in crypto.

```
On every fill:
  update price_window for this pair (last 5 min)
  if abs(latest_price - window_start_price) / window_start_price > 0.10:
    halt_trading(pair_id, reason="price_band_breach")
```

Halt mechanics:

- New orders rejected with a specific code; clients see `pair_halted`.
- Existing book is preserved (bids/asks remain).
- Cancels are still accepted. Halts must allow risk reduction.
- A human or automated process resumes trading after a cooldown (typically 5 minutes).

### Why Halt, Not Just Slow Down

A circuit breaker is a deliberate consistency-over-availability choice. During extreme volatility:

- Market data lag grows (subscribers can't keep up).
- User balances may be stale (Kafka lag widens).
- Cascading liquidations risk creating a feedback loop.

Halting freezes the world, lets state catch up, and prevents the system from booking fills it can't safely settle. A 5-minute halt is far better than a 5-minute backlog of mis-settled trades.

### Position Limits

Per-user open-order and position limits scale dynamically. During a halt or near-halt regime, limits tighten. After the market settles, limits relax back to baseline. This is mostly a risk-engineering control, but it keeps any one user from amplifying volatility.

---

## Step 11: Failure Modes

### Failure: RAFT Leader Loss Mid-Match

A matching engine leader dies after replicating a sequenced order to a quorum but before producing a fill. Recovery:

- A follower wins the election.
- The new leader's WAL has the order at that seq (replicated before ack).
- Replay produces the same fill (deterministic).
- Order entry pauses for ~500ms during election.

No order is lost. No fill is duplicated, because the fill key `(pair, seq, taker, maker)` is idempotent at the ledger. Subscribers may see the fill emitted twice on the market data path; the gateway dedupes by sequence number before sending to clients.

### Failure: Sequencer Crash Before WAL fsync

The order has a sequence number assigned but is not yet durably persisted. The sequencer crashes.

- Mitigation: we never ack the client until WAL is fsynced AND replicated to a quorum. So this case is invisible to the client -- they'll get a timeout and retry with the same `client_order_id`. Idempotency makes the retry safe.
- The lost order on the failed leader is also lost on the followers (it was never replicated). Net: no inconsistency, just a retry.

### Failure: WAL Corruption

NVMe disk corruption. Detected via per-record checksums on the WAL.

- The corrupt replica fails its replay and removes itself from the cluster.
- A new replica is provisioned, starts from the most recent snapshot, replays clean WAL from another replica.
- During the rebuild window, we run with reduced quorum. If we drop below quorum, we halt the pair.

### Failure: Network Partition Between Matching Engine and Risk Gateway

Risk gateway can't communicate with the matching engine.

- New orders pile up at the risk gateway.
- After timeout, the gateway returns `503 retry-after` to clients.
- Once the partition heals, risk gateway resumes forwarding.
- No orders are lost (held in-memory at the gateway with bounded buffer; gateway sheds load if buffer fills).

### Failure: Risk Gateway Approves on Stale Balance

User has $100. Risk gateway's cache is stale and says $200. User submits a $150 order.

- Hold placement at the ledger fails because actual balance is $100.
- Order is late-rejected.
- This is rare and bounded by Kafka lag (sub-second typically).

### Failure: Kafka Consumer Lag (Settlement Path)

Ledger consumer falls behind matching.

- Fills accumulate in Kafka.
- Risk gateway's balance cache (which is fed from the ledger's projection) goes stale.
- User can over-place orders during the lag.
- Mitigation: monitor lag aggressively. If lag > 5 seconds, narrow risk gateway tolerance (require buffer above stated balance) or halt order entry on affected pairs.

### Failure: Malformed Order

Bad price (negative, NaN), unsupported pair, oversized payload.

- Reject at the gateway. Do not let it reach the matching engine. Malformed input that reaches the matching engine could produce non-deterministic behavior across replicas (one replica's parser is more lenient than another's). Strict input validation at the boundary protects determinism.

### Failure: Exchange-Wide Halt

Regulator request, major incident, or operational decision.

- Halt all pairs. New orders rejected. Cancels still accepted (always).
- WebSocket subscribers receive a `system_halt` message.
- Pending settlement fills continue to drain (ledger keeps consuming Kafka).
- Resume requires a human runbook with explicit approvals.

---

## Step 12: Tradeoffs Summary

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Matching threading | Single-threaded per pair | Multi-threaded with locks | Determinism for replay, lower latency at top-of-book |
| Replication unit | Sequenced input log | Replicated state | 1000x smaller payload, built-in determinism check |
| Consensus | RAFT (via Aeron Cluster) | Custom protocol | Battle-tested, predictable latency, OSS |
| Risk check location | Pre-sequencer (separate gateway) | Inside matching engine | Matching loop stays focused; risk parallelizes |
| Balance source for risk | In-memory cache, Kafka-fed | Synchronous ledger read | Sub-microsecond reads; ledger fan-out absorbs writes |
| Hold mechanism | Idempotent reservation with TTL | Direct debit on order | Self-heals on crash; avoids phantom debits |
| Settlement transport | Kafka -> Aurora | Direct sync write | Decouples failure domains; enables replay |
| Order book structure | Skip list + DLL per level | Heap | O(1) cancel, FIFO time priority |
| Market data transport | Ring buffer (Disruptor pattern) | Go channels | 38x latency improvement per Coinbase blog |
| Slow consumer policy | Drop + snapshot reset | Hard disconnect | Preserves connection, lets client recover |
| Storage for WAL | NVMe with O_DIRECT | Network-attached storage | Fsync latency 10-100x lower |
| Cluster placement | EC2 cluster placement group | Multi-AZ | Sub-100us RAFT round trip; AZ failure handled by region failover |
| Volatility response | Circuit breakers (halt) | Slow down / queue | Consistency > availability for a trading system |
| Auto-scaling driver | ML prediction (60-min lead) | Reactive HPA | Pre-warm before the spike, not during |
| Fixed-point arithmetic | NUMERIC(38, 18) | Floats | IEEE 754 errors compound over millions of fills |
| Time priority on replace | Same price = preserve | Always lose priority | Matches Coinbase's documented behavior; better UX |

### Consistency vs Latency, Specifically

Trading is one of the few domains where strict serializability is non-negotiable on the write path *and* sub-millisecond latency is the bar. We get both by making the write path narrow: single-threaded matching against a replicated input log. Everything else (risk, settlement, fan-out) is async or eventually consistent and stays out of the critical section.

---

## Step 13: Common Mistakes

1. **Treating it like a generic CRUD service.** This is the single biggest interview failure mode. A trading engine is not a SaaS app with a database. The hot loop is closer to operating-system kernel design than to web services. If your design has Postgres on the matching path, you've already lost a couple of orders of magnitude on latency.

2. **No two-path split.** Mixing the matching hot loop with the market data fan-out path. A slow WebSocket subscriber should not affect matching. State this separation up front. Designs that put matching and fan-out behind the same goroutine pool will fall over the moment a subscriber's TCP buffer fills.

3. **Ignoring sequencing.** Skipping past the sequencer step or treating it as an afterthought. Sequencing is the linearization point and the foundation for replay. Without it, replicas diverge and you have nothing to audit.

4. **Multi-threaded matching within a pair.** Adding locks or sharding price levels across cores. This is a category error -- you've replaced determinism with race conditions for marginal throughput gain that you don't need (per-pair throughput is already in the millions of ops/sec).

5. **No circuit breakers.** Designing a system that always tries to keep matching during volatility. Real exchanges halt. Your design must too. If you don't mention circuit breakers, the interviewer will press you with a flash crash scenario and you'll have no answer.

6. **Storing balances inside the matching engine.** This couples matching to settlement and forces a round-trip to the ledger on every fill. Pre-checked holds with a separate ledger is the correct factoring.

7. **No idempotency on `client_order_id`.** Without end-to-end idempotency, a network retry creates duplicate orders. This is the most common source of "we double-bought BTC" incidents on exchanges that get this wrong.

8. **Using floats for price/qty.** Drifts a satoshi here, a cent there. Over millions of fills it's a regulatory finding waiting to happen. Fixed-point or integer-base-units only.

9. **Replicating order book state instead of input.** The book is huge; the input is tiny. Replicating state requires solving the consistency problem twice (once at the storage layer, once at the application layer). State-machine replication via the input log is the canonical approach.

10. **Forgetting the 24/7 constraint.** TradFi exchanges close every night and reconcile during the close. Crypto doesn't. Every operation -- snapshot, schema migration, deploy, rebalance -- has to happen with the engine running. This invalidates the "deploy a new version with downtime" playbook entirely.

---

## Step 14: Follow-up Questions

### How would you add derivatives (perpetuals, futures)?

The matching engine is largely the same. The risk gateway changes substantially: margin instead of full-balance holds, mark-to-market every N seconds, liquidation engine that issues market orders when a position breaches its maintenance margin. Funding rate calculation runs out-of-band against the index price. The settlement pipeline gains a periodic funding payment job. The interesting failure mode is cascading liquidations during a sharp move -- you mitigate this with auto-deleveraging (ADL) and insurance funds, both of which are off the matching critical path.

### How do you handle re-org of the sequencing log?

Re-org doesn't apply within a single RAFT cluster -- consensus precludes it. Cross-cluster re-orgs are not a thing because each pair's cluster is the authoritative log for that pair. The only related question is what happens if you discover a bug that produced incorrect fills: you rewind the ledger consumer, replay with the fixed code, and reconcile. You do not rewind the matching engine itself; the input log is treated as an immutable source of truth.

### How do you do canary deploys without losing nanoseconds?

You do not deploy new matching engine code on the leader during trading hours unless you have to. Standard practice:

1. Deploy new code to a non-voting replica.
2. Compare its derived state to the leader's, sequence by sequence, for a long observation window. Any divergence is a deploy blocker.
3. Promote the new replica to a voting follower.
4. Trigger a leader handoff when load is low.
5. Observe for an hour. Roll forward the rest of the cluster.

Code changes that affect matching output (fee logic, price band rules) require a coordinated cutover with explicit sequence numbers: "starting at seq N, the new logic applies." This is encoded in the WAL itself so replay is deterministic in either direction.

### How does Coinbase International (Bermuda) differ from Coinbase US in architecture?

Coinbase International Exchange launched May 2023, regulated in Bermuda, primarily for institutional perpetuals and derivatives. Architectural differences:

- Single global region (no need for multi-region as the customer base is institutional and concentrated).
- Aurora for settlement state at 100K msgs/sec, less geographic complexity.
- Different risk model -- margin-based, not full-balance pre-checks, because derivatives.
- Different regulatory regime -- Bermuda's BMA, no SEC/CFTC, so circuit breaker thresholds and reporting cadence differ.
- The matching engine itself is the same shape: Aeron Cluster + RAFT + single-threaded matching. The wrapping layers (risk, settlement, regulatory reporting) are what specialize.

### How do you handle a deposit landing on-chain mid-order?

Deposits are confirmed by the blockchain indexer (a separate system). Once confirmed, the indexer publishes a `deposit.credited` event that the ledger consumes. The user's available balance increases. The risk gateway's cache picks this up via the balance.changes Kafka topic. From the matching engine's perspective, the user simply has more buying power on subsequent orders -- there is no special case for in-flight orders. This is one place where the 24/7 nature is felt: balances genuinely move while you're trading.

### What if a customer disputes a fill?

The fill record is immutable. Disputes are resolved at the ledger level (refunds, adjustments) with separate journal entries that reference the original fill. The matching engine never rewrites history. This is also why the audit trail must survive forever in cold storage -- regulators ask about specific fills years after the fact.

---

## Related Topics

- [[../../../03-scaling-writes/index|Scaling Writes]] -- single-writer hot loop, batched fsync, sequence-based linearization
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- RAFT replication, circuit breakers, deterministic replay
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- consensus, state-machine replication, end-to-end idempotency
- [[../../../07-real-time-systems/index|Real-Time Systems]] -- ring buffer producer-consumer, WebSocket fan-out, slow-consumer policy
- [[../../../05-async-processing/index|Async Processing]] -- settlement via Kafka, ledger projections, balance-cache fan-out
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- NVMe WAL, Aurora for settlement, fixed-point arithmetic for money
