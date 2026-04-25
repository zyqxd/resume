# Walkthrough: Design a Multi-Chain Blockchain Indexer / Ingestion Platform (Coinbase)

## Step 1: Clarify Requirements and Scope

Before drawing anything, pin down the scope with the interviewer. Multi-chain indexing is a deceptively wide problem -- the answer for "ingest 5 EVM chains" looks nothing like the answer for "60+ heterogeneous chains powering deposit credit."

- How many chains are in scope, and what's the spread? (60+ at Coinbase, including BTC UTXO (Unspent Transaction Output -- Bitcoin's accounting model), EVM-family, Solana, Cosmos/IBC (Inter-Blockchain Communication -- Cosmos's cross-chain messaging), Polkadot.)
- Who are the consumers? (Deposit detection, explorer/search, analytics, fraud, tax, plus external products like Coinbase Cloud / NaaS.)
- What latency does deposit detection need? (Single-digit seconds at p95 from tip block to balance credit on fast chains; tens of seconds tolerable on BTC because of confirmations.)
- What latency does analytics need? (Minutes is fine; analytics reads warm/cold tiers, never tip.)
- Are we building tip-only, or full historical backfill? (Both. Year-plus backfill must be a first-class workflow, not a one-off script.)
- How are reorgs treated? (As a normal state transition. Indexer is responsible for replaying / reversing. Downstream consumers should never have to think about reorgs.)
- Who owns node operations? (We do. The fleet is part of the system. 60+ chains x N nodes per chain x blue/green = thousands of nodes.)

This scoping is critical because it forces the candidate to decide between two architectural extremes. The naive answer is "one indexer service that talks to all chains." The right answer at Coinbase scale is **per-chain pipelines** for the chains that need them, sharing a common substrate (storage, schema, fan-out) underneath. The Solana I/O (Coinbase's per-chain dedicated Solana ingestion pipeline, 12x throughput) launch in 2025 is the canonical example: Coinbase moved Solana off the chain-agnostic ingestion path because one chain's throughput was distorting the design for all the others.

**Primary design constraint:** Deposit detection latency for the user, *and* reorg correctness. Crediting a customer for a deposit that later disappears in a reorg is unacceptable. Failing to credit a confirmed deposit is also unacceptable. Every architectural choice filters through these two lenses.

---

## Step 2: High-Level Architecture

```
+----------------+   +----------------+   +----------------+
|  BTC Nodes     |   |  ETH Nodes     |   |  Solana Nodes  |   ...60+ chains
|  (Bitcoin Core)|   |  (Erigon/Geth) |   |  (Validator)   |
+--------+-------+   +--------+-------+   +--------+-------+
         |                    |                    |
         | ZMQ + RPC          | stream + RPC       | Geyser + RPC
         v                    v                    v
+----------------+   +----------------+   +----------------+
| BTC Ingester   |   | ETH Ingester   |   | Solana I/O     |  per-chain ingestion
| (UTXO-aware)   |   | (log/topic)    |   | (push+backfill)|  pods
+--------+-------+   +--------+-------+   +--------+-------+
         |                    |                    |
         +--------------------+--------------------+
                              |
                              v
                  +-------------------------+
                  |     ChainStorage        |  raw block data availability layer
                  |  (immutable, S3/GCS)    |  ~1500 blocks/sec production
                  |  block + tx + receipt   |
                  +-----------+-------------+
                              |
                              v
                  +-------------------------+
                  |     Chainsformer        |  streaming + batch transformation
                  |  (normalize, decode,    |  (raw bytes -> typed events)
                  |   reorg-aware)          |
                  +-----------+-------------+
                              |
              +---------------+---------------+
              |               |               |
              v               v               v
     +-----------------+ +-----------+ +-----------------+
     | ChaIndex (hot)  | | Postgres/ | | Elasticsearch   |
     | DynamoDB        | | Aurora    | | (explorer       |
     | balances, last  | | (derived  | | search)         |
     | seen, addr->tx  | | indices)  | |                 |
     +--------+--------+ +-----+-----+ +--------+--------+
              |                |                |
              +----------------+----------------+
                              |
                              v
                  +-------------------------+
                  |   Per-Chain Kafka       |  fan-out: one cluster per chain
                  | (asset_transfer events, |  (or per chain group)
                  |  reorg events,          |  partitioned by address
                  |  block lifecycle)       |
                  +-----------+-------------+
                              |
        +---------+-----------+-----------+---------+----------+
        v         v           v           v         v          v
   +--------+ +--------+ +-----------+ +--------+ +--------+ +--------+
   |Deposit | |Search/ | |Analytics  | |Fraud   | |Tax     | |External|
   |Detect. | |Explorer| |Warehouse  | |Engine  | |Engine  | |Cloud / |
   |(low ms)| |(secs)  | |(minutes)  | |(secs)  | |(daily) | |NaaS    |
   +--------+ +--------+ +-----------+ +--------+ +--------+ +--------+
                              |
                              v
                  +-------------------------+
                  |   Snapchain / NodeSmith |  node fleet ops:
                  |   (snapshot deploys,    |  blue/green, EBS snapshots,
                  |    AI-driven upgrades)  |  AI upgrade orchestration
                  +-------------------------+
```

### Core Components

1. **Per-chain ingestion pods** -- one logical pipeline per chain (or per chain family). Owns the node connections, the push stream subscription, the RPC (Remote Procedure Call) poller, and the cursor state. Solana I/O is the dedicated example.
2. **ChainStorage** -- the data availability layer. Stores raw blocks + transactions + receipts immutably. Treats every chain as an opaque byte stream with a height + hash. ~1500 blocks/sec in production.
3. **Chainsformer** -- decodes raw blocks into normalized typed events. Streams (real-time tip) and batch (backfill, re-derivation) modes share the same code path.
4. **ChaIndex / DynamoDB** -- hot key-value indices: address -> last seen tx, address -> balance, asset -> top holders. Single-digit ms reads.
5. **Postgres / Aurora (AWS managed Postgres/MySQL) derived stores** -- richer queryable indices for non-hot-path workloads (explorer joins, period reporting).
6. **Per-chain Kafka clusters** -- the fan-out backbone. Each chain has its own cluster (or partition group) so a Solana traffic spike does not back up BTC consumers.
7. **Snapchain** -- node fleet automation. Snapshot-producer nodes write EBS (Elastic Block Store -- AWS persistent disks) snapshots; consumer nodes mount them and skip multi-day initial sync. Blue/green deploys with NLBs (Network Load Balancers -- AWS) for static IPs.
8. **NodeSmith** -- AI-driven upgrade orchestration. Triage agent classifies upgrade announcements; Upgrade Orchestrator agent executes.

### Why This Shape

The shape encodes three big bets. First, **separate raw from derived**: ChainStorage is immutable, ChaIndex and Postgres are projections that can be rebuilt. Second, **per-chain at the edges, shared in the middle**: ingestion pods are chain-specific because chain quirks dominate at the edge; ChainStorage and the schema underneath are shared because the abstraction holds. Third, **Kafka as the fan-out boundary**: every internal consumer reads from Kafka topics, never from the indexer directly, so consumers scale and fail independently.

---

## Step 3: Data Model

### Raw Layer (ChainStorage)

Raw blocks are stored in object storage, addressed by `(chain_id, height, block_hash)`. The hash is part of the key so a reorg's discarded block is still retained -- you can always retrieve "what we used to think was block 1000" alongside "what block 1000 is now."

```
S3 key:  chain={chain_id}/height={height}/hash={block_hash}/block.bin
S3 key:  chain={chain_id}/height={height}/hash={block_hash}/receipts.bin
Index:   DynamoDB (chain_id, height) -> [list of (block_hash, status, ingested_at)]
```

### Normalized Schema (Chainsformer Output)

Every chain projects onto a small, opinionated schema. Chain-specific data lives in a `raw` field, but the columns we depend on for deposit detection are uniform across chains.

```sql
-- One row per block we've ever seen, including reorged-away blocks.
blocks (
  chain_id        VARCHAR(32) NOT NULL,
  block_hash      VARCHAR(128) NOT NULL,
  parent_hash     VARCHAR(128) NOT NULL,
  height          BIGINT NOT NULL,
  timestamp       TIMESTAMP NOT NULL,
  status          VARCHAR(20) NOT NULL,  -- 'BLOCK_SEEN','PENDING_FINALITY','FINALIZED','REORGED'
  finality_score  INT NOT NULL,          -- chain-specific confirmation count
  ingested_at     TIMESTAMP NOT NULL,
  finalized_at    TIMESTAMP,
  PRIMARY KEY (chain_id, block_hash)
);

-- Universal asset transfer event. Every chain projects onto this.
asset_transfers (
  event_id        UUID PRIMARY KEY,             -- deterministic from (chain_id, tx_hash, log_index)
  chain_id        VARCHAR(32) NOT NULL,
  block_hash      VARCHAR(128) NOT NULL,
  block_height    BIGINT NOT NULL,
  tx_hash         VARCHAR(128) NOT NULL,
  log_index       INT NOT NULL,
  from_address    VARCHAR(128),
  to_address      VARCHAR(128),
  asset_id        VARCHAR(64) NOT NULL,         -- 'BTC','ETH','USDC@ETH','SOL', etc.
  amount          NUMERIC(78,0) NOT NULL,       -- raw integer, decimals applied at read
  status          VARCHAR(20) NOT NULL,         -- mirrors block status
  raw             JSONB NOT NULL,               -- chain-specific payload
  ingested_at     TIMESTAMP NOT NULL
);

-- One row per address per asset, the "what does the user own right now" view.
address_balance_view (
  chain_id        VARCHAR(32) NOT NULL,
  address         VARCHAR(128) NOT NULL,
  asset_id        VARCHAR(64) NOT NULL,
  balance         NUMERIC(78,0) NOT NULL,
  last_block_height BIGINT NOT NULL,
  last_event_id   UUID NOT NULL,
  PRIMARY KEY (chain_id, address, asset_id)
);

-- Reorg events are first-class. Consumers subscribe to these.
reorg_events (
  reorg_id        UUID PRIMARY KEY,
  chain_id        VARCHAR(32) NOT NULL,
  fork_height     BIGINT NOT NULL,        -- last common ancestor
  abandoned_hash  VARCHAR(128) NOT NULL,  -- block we used to follow
  new_tip_hash    VARCHAR(128) NOT NULL,  -- block we now follow
  depth           INT NOT NULL,           -- number of blocks reversed
  detected_at     TIMESTAMP NOT NULL
);
```

### Key Design Decisions

**Deterministic `event_id`:** computed as `hash(chain_id, tx_hash, log_index)`. This is the primary idempotency key for downstream consumers. If the deposit detector receives the same event_id twice (because of a Kafka rebalance), it's a no-op -- not a double credit.

**`raw` as JSONB:** the universal schema captures 90% of what consumers need. The remaining 10% (Bitcoin script types, Solana inner instructions, Cosmos IBC packet metadata) lives in `raw`, queryable but not denormalized into columns. This is the single biggest schema pressure-relief valve. Without it you either get a thousand-column table or a per-chain table explosion.

**`status` field on every row:** the same lifecycle string lives on blocks and on asset_transfers. Reorgs flip `FINALIZED` events back to `REORGED`, which tells downstream consumers exactly what to undo. We never delete rows -- the audit trail is the truth.

**`amount` as `NUMERIC(78,0)`:** wide enough to hold uint256 (largest EVM amount is ~10^77). Decimals are applied at read time using a per-asset decimals registry. Float for money is a non-starter on a crypto exchange.

---

## Step 4: Per-Chain Ingestion Pipeline

This is where the staff-level signal lives. The chain-agnostic mistake is "one ingester polls RPC for all chains." The Solana I/O architecture (announced 2025) is the corrective.

### Hybrid Ingestion: Push + Poll

Every chain uses both a push source (low latency, lossy on restart) and a poll source (authoritative, slow). They feed the same downstream pipeline; the poller catches what the pusher missed.

| Chain   | Push source       | Poll source     | Notes |
|---------|-------------------|-----------------|-------|
| Bitcoin | ZMQ (ZeroMQ -- high-performance asynchronous messaging library Bitcoin Core uses for push events) pubsub        | RPC `getblock`  | ZMQ for tip, RPC for backfill and confirmations |
| Ethereum| Erigon (high-performance Ethereum execution client with built-in indexing/streaming) stream / WS subscribe | JSON-RPC `eth_getBlockByNumber` | WS subscriptions drop on restart; RPC polls catch up |
| Solana  | Geyser (Solana's push-based stream interface for low-latency block and account data) plugin (gRPC (Google's high-performance RPC framework) stream) | JSON-RPC `getBlock` + slot subscribe | Solana I/O dedicated cluster |
| Polygon | EVM stream        | JSON-RPC        | Same as ETH but 256-block finality |
| Cosmos  | Tendermint WS event subscribe | RPC | IBC packets need cross-chain correlation |

### Ingester State Machine

```
        +-------------+
        | TIP_FOLLOW  | <-- push stream healthy, RPC validates every N blocks
        +------+------+
               |
               | push stream desync OR restart
               v
        +-------------+
        | BACKFILL    | <-- RPC poller pulls (cursor, tip), drains gap
        +------+------+
               |
               | gap closed, push stream re-subscribed
               v
        +-------------+
        | TIP_FOLLOW  |
        +-------------+
```

The ingester always knows two cursors: `last_seen_height` (push stream tip) and `last_finalized_height` (RPC-confirmed). On startup it never trusts the push stream alone -- it RPCs for the latest finalized block first, backfills any gap, then subscribes to push.

### Solana I/O: The Per-Chain Win

Pre-2025, Solana shared the same chain-agnostic ingester as the EVM family. Solana produces ~50K transactions/sec at peak, vs ~15 for Bitcoin and ~1500 for Ethereum. Sharing a Kafka cluster meant Solana spikes back-pressured every other chain's consumer lag.

The Solana I/O redesign:
- Dedicated Kafka cluster (no shared neighbor).
- **One transaction per Kafka message**, not one block per message. Whole-block messages were too large and forced consumers to do fine-grained filtering after deserialization. Per-tx messages let consumers filter by address at the broker level via partition key.
- Geyser push + parallel RPC backfill running in lockstep.
- Result: 12x throughput, 20% deposit detection latency reduction, absorbs 8x baseline traffic spikes.

The lesson generalizes: when one chain dominates the throughput envelope, give it a dedicated pipeline. Don't force the other 59 chains to pay for Solana's tail.

---

## Step 5: Reorg Handling State Machine

Reorgs are not exceptions. On Bitcoin, ~1-block reorgs happen on the order of once per day. Treating reorgs as a rare error path is the most common failure mode on this problem.

### Block Lifecycle

```
        +-------------+
        | BLOCK_SEEN  |  ingested via push or poll, parent unknown / unverified
        +------+------+
               |
               | parent verified; emit pending events
               v
        +--------------------+
        | PENDING_FINALITY   |  block + events emitted to consumers tagged 'pending'
        +------+-------------+
               |
               | confirmation count >= chain threshold
               v
        +-------------+
        | FINALIZED   |  events re-emitted with status='finalized'; deposit credited
        +------+------+
               |
               | (rare) ancestor reorged
               v
        +-------------+
        | REORGED     |  emit reverse events; downstream undoes
        +-------------+
```

### Per-Chain Confirmation Thresholds

| Chain    | Finality model | Default conf threshold | Rationale |
|----------|----------------|------------------------|-----------|
| Bitcoin  | Probabilistic  | 3 (small) / 6 (large)  | Hash power based, rollback probability 10^-3 at depth 6 |
| Ethereum | Hybrid (PoS)   | 12-32                  | Justified -> finalized over 2 epochs (~12.8 min) |
| Solana   | Optimistic + supermajority | 32 slots (~12.8s) | Fast finality once confirmed |
| Polygon  | PoS + checkpoints | 256 blocks            | Heimdall checkpoints to ETH every ~30 min |
| Cosmos   | BFT (instant)  | 1                      | Tendermint BFT finalizes on commit |
| Avalanche| Snowman BFT    | 1-2                    | Sub-second finality |

The threshold lives in the indexer config, **not in the deposit service**. This is a load-bearing decision. If every consumer reimplements "what's finalized?" you get drift -- one consumer credits at 6 confs, another at 12. Centralizing the policy means the indexer emits a `finalized` event exactly once per block, and everyone downstream agrees.

### Reverse-and-Replay on Reorg

```
1. Push stream or RPC reports new tip with parent_hash that doesn't match our last block.
2. Walk backward from new tip and current tip, finding last common ancestor (LCA).
3. For every block from current tip down to LCA+1:
     - Mark block status = 'REORGED'
     - For every asset_transfer in that block, emit reverse event:
         { event_id: <original>, status: 'REORGED', amount: -<original> }
     - Update address_balance_view (subtract back out)
4. For every block from LCA+1 up to new tip:
     - Run normal ingestion (BLOCK_SEEN -> PENDING_FINALITY -> FINALIZED)
5. Emit single reorg_event with depth = (current_tip - LCA)
```

Downstream consumers see the same `event_id` they saw before, now with `status='REORGED'`. The deposit detector knows to debit (or, if the deposit was still pending, just cancel the pending credit). Idempotency is what makes this safe -- the deposit detector keyed its credit on `event_id`, so the reverse maps to exactly that credit.

### Deep Reorgs

Most reorgs are 1-2 blocks. A 6+ block reorg is a "reorg storm" event -- usually a node desync, occasionally a real chain incident. The indexer caps automatic reverse-and-replay at the chain's finality threshold. Beyond that, it pages on-call and halts the deposit detector for that chain. Crediting backward through a 50-block reorg automatically would be more dangerous than the outage.

---

## Step 6: Storage Layering

Raw is immutable, derived is rebuildable. This is the second load-bearing decision after per-chain pipelines.

### Tier Structure

| Tier | Store | Latency | Lifetime | Purpose |
|------|-------|---------|----------|---------|
| Hot  | DynamoDB / Cassandra | < 5ms | last 30-90 days | balance lookup, "did we see this address?", deposit detection |
| Warm | Postgres / Aurora    | 10-100ms | last 1-2 years | explorer queries, derived joins, period reports |
| Cold | S3 / GCS (ChainStorage)| seconds | forever | raw blocks, audit, re-derivation source |
| Search| Elasticsearch       | 100ms-1s | last 1-2 years | explorer text search, address search |

### Re-Derivation on Schema Change

When the schema changes -- new asset class, new chain integration, bug in an old decoder -- you need to rebuild derived state. The pattern:

```
1. Spin up a new Chainsformer version (e.g., v15) reading from the same ChainStorage tier.
2. Write its output to a parallel DynamoDB / Postgres namespace (suffix _v15).
3. Backfill from the chain's genesis block (or whatever range matters).
4. When v15 catches up to tip and has been validated, swap consumer pointers.
5. Decommission v14 namespace.
```

Because raw is immutable in S3, re-derivation is just compute + storage cost. There's no "we lost the historical truth" risk. This is the single biggest argument for keeping ChainStorage decoupled from the index layer -- if they were the same store, schema migrations would be terrifying.

---

## Step 7: Fan-Out to Consumers

Every internal product reads from Kafka, never from the indexer's database directly. This bounds blast radius and lets each consumer scale independently.

### Topic Topology

```
chain.bitcoin.asset_transfers          partitioned by address (hash mod N)
chain.bitcoin.block_lifecycle          partitioned by block_hash
chain.bitcoin.reorg_events             single partition (low volume, ordering matters)

chain.ethereum.asset_transfers         partitioned by address
chain.ethereum.contract_logs           partitioned by contract_address
chain.ethereum.block_lifecycle
chain.ethereum.reorg_events

chain.solana.asset_transfers           per-tx messages (Solana I/O), per-cluster
chain.solana.block_lifecycle
chain.solana.reorg_events

... 60+ chains
```

Per-chain topic naming (instead of `asset_transfers` with a `chain_id` field) means consumers can subscribe selectively. The deposit detector subscribes to all `chain.*.asset_transfers` topics; the ETH-only NFT indexer subscribes only to `chain.ethereum.contract_logs`. Wildcards keep the topology manageable.

### Partition Key: Address

Asset transfer topics partition by `to_address || from_address` (whichever the consumer cares about). This gives per-address ordering -- critical for the deposit detector, because two deposits to the same address must be processed in order. Cross-address ordering is not preserved, which is fine.

### Exactly-Once via Idempotency

Kafka guarantees at-least-once delivery. The indexer never claims exactly-once at the broker level -- instead, every message has the deterministic `event_id`, and consumers store seen event_ids in a 7-day TTL (Time To Live) set (Redis or DynamoDB). Duplicate delivery becomes a no-op.

### Lag Monitoring

Every consumer group's lag is monitored per partition. The deposit detector's lag SLO (Service Level Objective) is 1 second; analytics is 5 minutes. When lag exceeds threshold:
- Deposit detector lag spike -> page on-call, scale up consumer pool, possibly halt partial chain.
- Analytics lag spike -> auto-scale consumers, no page.
- Per-chain isolation means a Solana lag spike doesn't trigger ETH alerts.

---

## Step 8: Node Fleet Management (Snapchain + NodeSmith)

Running 60+ chains means thousands of nodes. Treating nodes as cattle, not pets, is the operational difference between "we run an indexer" and "we run a platform."

### Snapchain: Snapshot-Based Node Deploys

Bitcoin Core takes 1-3 days to do an initial sync. Geth takes 4-7 days. Solana validator initial sync is days even on top-tier hardware. If every node deploy required initial sync, you couldn't roll new nodes daily.

Snapchain's pattern (Coinbase since 2018, AWS blog 2024):

```
+----------------+       writes EBS snapshot          +-----------------+
| Producer Nodes | -------------------------------->  | EBS Snapshots   |
| (long-lived)   |       every N hours                | (immutable)     |
+----------------+                                    +--------+--------+
                                                               |
                                                               | mount
                                                               v
                                                      +-----------------+
                                                      | Consumer Nodes  |
                                                      | (ephemeral,     |
                                                      |  30-day max)    |
                                                      +-----------------+
```

Producer nodes do the slow initial sync once, then run forever, periodically writing EBS snapshots. Consumer nodes mount the latest snapshot at boot and only need to catch up a few minutes of tip blocks. A new consumer node is hot in 5-10 minutes instead of 5-7 days.

**Tenets:**
- **Immutability:** consumer nodes never modify their disk state outside the chain's own writes; if they desync, they're terminated and replaced.
- **Ephemerality:** every consumer node has a 30-day hard expiry. Forces fleet to be replaceable.
- **Consensus:** multi-approver process for promoting a new producer snapshot to "official." A bad snapshot would corrupt every new consumer.
- **Automation:** node provisioning, snapshot promotion, blue/green cutover are all automated.

**NLB per node for static IPs across blue/green:** when you cut over from blue to green, peer nodes (other chain participants) need stable endpoints. An NLB in front of each node gives a static IP that survives instance replacement.

### NodeSmith: AI-Driven Upgrades

Every chain ships hard forks. Missing a mandatory upgrade by 24 hours can desync the node from the network for weeks. With 60+ chains, manual upgrade tracking is a full-time team.

NodeSmith (2025) is a two-agent system:
- **Triage Agent:** monitors chain announcement channels (Discord, GitHub, mailing lists). Classifies upgrades by severity, mandatory/optional, deadline.
- **Upgrade Orchestrator:** executes the upgrade. Spins up green fleet on new version, validates against the chain, cuts traffic, decommissions blue.

Reported impact: 500+ upgrades in 3 months, 30% effort reduction, zero missed mandatory upgrades. In an interview, this is the hook to talk about AI-augmented operations -- not as buzz but as a real cost-pressure response to fleet sprawl.

---

## Step 9: Per-Chain Quirks Worked Examples

The universal schema works because the chain-specific decoder layer absorbs the differences. Three worked examples:

### Bitcoin: UTXO Model

Bitcoin has no accounts. A "transfer" is "tx consumed UTXO_A and UTXO_B, produced UTXO_C and UTXO_D." There is no `to_address` field on the transaction; addresses are derived from output scripts.

Decoder logic:
```
For each tx:
  inputs = list of (prev_tx_hash, prev_output_index)  -- what got spent
  outputs = list of (script_pubkey, amount)            -- what got created

For each output:
  address = decode_script(script_pubkey)               -- P2PKH, P2SH, P2WPKH, P2TR
  emit asset_transfer(
    from_address = sum_of_input_addresses (best-effort, multi-sender txs are messy),
    to_address = address,
    amount = output.amount,
    asset_id = 'BTC'
  )
```

The `from_address` is the messy part: a Bitcoin tx can have N inputs from N different addresses going to M different outputs. The indexer emits one event per output with `from_address` set to the dominant input address (or null for coinbase / multi-sender). Consumers that need exact provenance read the `raw` field.

### Ethereum: Logs and Topics

ETH has accounts and a flat balance model, but ERC-20 token transfers are not first-class -- they're emitted as `Transfer(address from, address to, uint256 value)` events on the contract. Indexing token transfers means scanning every contract's event logs.

Decoder logic:
```
For each tx receipt:
  For each log entry:
    if log.topics[0] == keccak256("Transfer(address,address,uint256)"):
      emit asset_transfer(
        from_address = log.topics[1],
        to_address = log.topics[2],
        amount = decode(log.data),
        asset_id = format('{}@ETH', log.address)  -- contract address as asset id
      )
  For ETH itself (native value transfer):
    emit asset_transfer(
      from_address = tx.from,
      to_address = tx.to,
      amount = tx.value,
      asset_id = 'ETH'
    )
```

ETH's quirk is that one tx can emit 50+ logs (DeFi swaps, vault deposits). The indexer emits 50+ asset_transfer events from one tx -- each with a distinct `log_index`, deterministic event_id.

### Solana: Parallel Execution

Solana txs run in parallel and reference accounts they touch. Native SOL transfers happen in the system program; SPL token transfers happen in the token program. Inner instructions (CPIs) can recursively trigger more transfers.

Decoder logic:
```
For each tx:
  For each instruction (and recursively, inner instructions):
    if instruction.program_id == system_program and instruction.type == Transfer:
      emit asset_transfer(asset='SOL', ...)
    if instruction.program_id == spl_token_program and instruction.type == Transfer:
      emit asset_transfer(asset=format('{}@SOL', mint_address), ...)
```

The Solana quirk: a single tx can produce dozens of transfers across both native SOL and SPL tokens, and inner CPIs need recursive decoding. This is why Solana I/O ships one tx per Kafka message instead of one block -- the per-tx transfer fan-out is too wide to ship as a single bulky payload.

---

## Step 10: Deposit Detection Latency Path

The customer-facing metric. "Customer sent 1 ETH at time T; when does Coinbase show 1 ETH credited?"

### Latency Budget (Ethereum, illustrative)

```
T+0ms:    block produced on chain
T+200ms:  block propagates to our node (Erigon/Geth)
T+250ms:  Erigon stream emits block to ingester
T+300ms:  ingester decodes, writes to ChainStorage (S3 PUT)
T+350ms:  Chainsformer normalizes -> asset_transfer event with status='pending'
T+380ms:  Kafka publish to chain.ethereum.asset_transfers
T+400ms:  Deposit detector consumes message
T+450ms:  Deposit detector: address-belongs-to-customer? lookup in ChaIndex (DynamoDB)
T+500ms:  Pending credit visible in customer UI ("Pending: 1 ETH")
...
T+~13min: 12 confirmations reached, Chainsformer re-emits with status='finalized'
T+~13min: Deposit detector finalizes, customer can trade/withdraw the funds
```

The pending credit is the user-perceived latency. The finalized credit is the safety boundary -- you can't let a customer withdraw funds that might reorg away.

### Where Latency Hides

- Node propagation (T+0 to T+200ms): improve by running geographically close to chain peers, peering directly with major mining pools / validators.
- Push stream lag (T+200 to T+250ms): direct connection vs WS-over-public-internet.
- ChainStorage write (T+300ms): write to local SSD cache first, async to S3.
- Kafka publish (T+380ms): per-chain cluster avoids head-of-line blocking from other chains.
- Deposit detector consumption (T+400ms): consumer pool sized so lag is bounded.

The Solana I/O 20% latency reduction came from collapsing two of these stages -- one tx per message removed a deserialize-and-fan-out step inside the deposit detector.

---

## Step 11: Multi-Chain Schema Normalization

The asset transfer abstraction is the load-bearing schema decision. It works because most consumers ask the same question regardless of chain: "did money move from address A to address B?"

### What's Universal

- `from_address`, `to_address`, `amount`, `asset_id`, `tx_hash`, `block_height`, `status`.
- Idempotent `event_id` deterministic from `(chain_id, tx_hash, log_index)`.
- Reorg lifecycle (PENDING -> FINALIZED -> optional REORGED).

### What's Chain-Specific (lives in `raw`)

- Bitcoin: input UTXO references, script types, witness data.
- Ethereum: gas used, contract address, full topic set, internal traces.
- Solana: program ids, account references, compute units, inner instruction tree.
- Cosmos: IBC packet metadata, module name, message type.

### Resisting Over-Abstraction

The temptation is to project everything into common columns. The discipline is to stop at the universal slice and let chain-specific details live in `raw`. The 80/20 rule: 80% of consumer queries need only the universal columns. The 20% that need chain specifics are sophisticated enough to read `raw` themselves.

### Resisting Under-Abstraction

The opposite mistake is one fully chain-specific schema per chain. Then every consumer learns 60+ schemas, and adding a new consumer is a 60-chain integration project. The right level is "universal columns + raw blob" -- consumer onboarding is one schema, and hard cases drop to raw.

---

## Step 12: Failure Modes

### Failure: Node Desync

A node falls behind the chain (slow disk, network partition, missed upgrade). Mitigation:
- Continuously RPC-poll a secondary independent node for tip height; alert if our primary lags by > N blocks.
- Snapchain consumer nodes are 30-day max anyway, so a quietly-broken node hits its expiry and gets replaced.
- For critical chains, run 3+ nodes and quorum-read (only ingest blocks at least 2 of 3 nodes have).

### Failure: RPC Outage

Push stream is up, but we can't validate via RPC. Mitigation:
- Indexer continues ingesting from push stream but marks blocks `BLOCK_SEEN` instead of escalating to `FINALIZED` (no validation yet).
- Deposit detector sees pending credits but won't finalize them.
- Once RPC recovers, indexer backfills validation and finalizes.

### Failure: Reorg Storm

A chain has a deep reorg (6+ blocks) or many shallow reorgs in quick succession. Mitigation:
- Auto-reverse halts at the chain's configured finality threshold. Beyond that depth, the indexer halts the deposit detector for that chain and pages on-call.
- Indexer continues ingesting but in a pure observer mode -- consumers see no new finalized events.
- Manual review of the reorg before re-enabling deposit detection.

### Failure: Consumer Lag

Deposit detector falls behind. Mitigation:
- Auto-scale consumer pod count based on lag.
- If lag continues to grow, page on-call -- a stuck consumer is more often a code problem than a capacity problem.
- For non-critical consumers (analytics), lag is allowed to grow into the warm tier; analytics reads from Postgres if it falls hours behind.

### Failure: S3 Throttle

ChainStorage write rate exceeds S3 partition limits during a backfill. Mitigation:
- ChainStorage uses many key prefixes (`chain={id}/height={height}/...`) so writes spread across S3 partitions.
- Backfill jobs throttle themselves; tip ingestion always has priority.
- Local SSD write-through buffer absorbs short S3 outages.

### Failure: Kafka Cluster Outage

Per-chain isolation contains the blast: only that chain's consumers stall. Mitigation:
- Indexer buffers events to a local outbox (disk) when Kafka is unreachable; replays once Kafka recovers.
- For multi-hour outages, the outbox is bounded (disk fills); the indexer pauses ingestion and waits.
- Per-chain isolation means a Kafka incident in the Solana cluster doesn't affect BTC deposits.

### Failure: NodeSmith Misclassifies an Upgrade

The Triage Agent labels a mandatory upgrade as optional, the upgrade window passes, the node desyncs. Mitigation:
- Triage Agent surfaces classification confidence; low-confidence upgrades require human review.
- Independent monitoring on chain version drift -- if our nodes are running a different version than network majority, alert regardless of NodeSmith's classification.
- NodeSmith is an accelerator, not a replacement for human oversight on hard forks.

---

## Step 13: Cost & Capacity

Blockchain nodes dominate cost. A single Ethereum archive node is ~12 TB of NVMe + RAM headroom; running blue/green plus producer/consumer means 4-6x that per chain for the high-traffic chains. Across 60+ chains, the node fleet is the budget.

### Bin-Packing the Fleet

Not every chain needs maximum redundancy. The fleet is tiered:

| Tier | Chains | Node count per chain | Why |
|------|--------|---------------------|-----|
| Critical | BTC, ETH, USDC chains, Solana | 6+ (3 producer, 3 consumer per region) | Deposit volume, customer impact |
| Standard | Polygon, Arbitrum, Optimism, Cosmos hubs | 3-4 | Material volume, less critical |
| Long-tail | Niche chains, low-volume L1s | 2 | Liveness only, tolerate degraded |

Snapchain ephemerality (30-day node lifespan) means the fleet rotates continuously. Provisioning is automated; capacity changes happen via fleet autoscaling, not manual node operations.

### Predictive Autoscaling

Coinbase has reported using ML to predict traffic 60 minutes ahead and pre-warm capacity. The signals: deposit announcement schedules, market events, time-of-day, social media chatter. The point isn't the model -- it's that nodes take 5-10 minutes to come online (even from snapshot), so reactive autoscaling is too slow. Predictive autoscaling pre-warms before the spike.

### Cost Levers

- **Cold storage tiering:** raw blocks beyond 30 days move to S3 Glacier or equivalent. Re-derivation tasks pay seconds-of-restore latency for years-old blocks.
- **Node sharing across products:** the same nodes feed indexing, the explorer, and Coinbase Cloud / NaaS. One node, many tenants.
- **Right-sizing per chain:** Bitcoin doesn't need EVM tracing nodes; Solana doesn't need archive nodes for everything. Per-chain node config matches workload.

---

## Step 14: Tradeoffs Summary

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Pipeline boundary | Per-chain at the edges | Single chain-agnostic ingester | One chain (Solana) can dominate throughput; per-chain isolates blast radius |
| Ingestion source | Hybrid push + poll | Push-only or poll-only | Push is fast but lossy on restart; poll is authoritative but slow; you need both |
| Reorg handling | First-class state machine | Exception path | Reorgs happen routinely on probabilistic-finality chains; treating them as exceptions guarantees bugs |
| Storage layering | Raw immutable + derived rebuildable | Single combined store | Schema changes on derived state are routine; raw immutability lets you re-derive without data loss |
| Schema | Universal columns + `raw` blob | Per-chain schema OR fully flattened | 80% of consumers want universal; 20% need raw; one schema per chain explodes consumer integration cost |
| Confirmation policy location | In indexer config | In each consumer | Centralizing prevents drift; one source of truth for "finalized" |
| Fan-out | Per-chain Kafka topics | Single shared topic | Per-chain isolation; consumer can selectively subscribe |
| Idempotency | Deterministic event_id + consumer dedup | Broker-level exactly-once | Cheap, scales, no broker-version coupling |
| Node fleet | Snapchain blue/green + ephemeral | Long-lived hand-tended nodes | 60+ chains x N versions makes pets impossible |
| Upgrade ops | NodeSmith AI-augmented | Manual on-call rotation | 500+ upgrades/quarter is more than human ops can sustain |
| Tip vs backfill | Same code path, different mode | Separate systems | Backfill is just historical tip; sharing reduces drift |

---

## Step 15: Common Mistakes to Avoid

1. **Treating reorgs as an exception path.** Bitcoin has reorgs daily; Polygon and L2s have their own variants. If your design assumes "blocks are final once seen," you will miss-credit deposits the first week in production. The state machine has REORGED as a status, full stop.

2. **Over-abstracting per-chain quirks.** Every chain is different. Pretending Bitcoin UTXOs and Ethereum accounts are "really the same thing under a generic ledger model" produces a leaky abstraction that breaks the moment a consumer needs UTXO-specific data. The right level is universal columns + raw blob, accepting that some queries drop to raw.

3. **Single global Kafka cluster.** It's appealing -- one cluster, simpler ops. Then Solana spikes and BTC consumers lag, or a Solana incident takes down deposit detection for ETH. Per-chain (or per-chain-group) clusters cost more but contain blast radius. The Solana I/O launch was partly a story about why this isolation pays for itself.

4. **Indexing every event for every consumer.** The deposit detector wants asset transfers. The fraud engine wants tx graphs. The explorer wants full receipts. Building a single denormalized index that satisfies all of them is impossible. The right shape: ChainStorage holds the raw, each product builds the derived view it needs from the same raw substrate. Coupling consumers to a shared mega-index is how you end up with 30-second deposit latency because the analytics team's batch job is hammering the same DynamoDB table.

5. **Trusting push streams alone.** Push streams (Geyser, ZMQ, WS subscriptions) drop on restart, miss messages on broker hiccup, and don't have replay. Designing as if push is reliable is a 24-hour outage waiting for the next process restart. Always pair push with RPC catch-up.

6. **Confirmation policy living in each consumer.** "Should this deposit be credited at 6 confs or 12?" If every consumer answers separately, drift happens. Customer X gets credited; Customer Y for the same block doesn't. Centralize confirmation policy in the indexer, emit events with explicit `pending` and `finalized` status. Consumers consume; they don't decide finality.

7. **Treating nodes as pets.** Long-lived hand-tuned nodes work for 5 chains. At 60+, with hard forks every quarter on each, you cannot manually maintain. Snapchain ephemerality, blue/green, NodeSmith automation -- pick your version, but the architectural pattern is "nodes are fungible cattle, replaced on a schedule."

8. **No per-chain rate limiting on ingestion.** A misbehaving chain (or node) can flood your pipeline with malformed data. Each chain ingester needs its own backpressure boundary so a Solana feature-flag bug doesn't pollute the BTC pipeline.

---

## Step 16: Follow-up Questions

**Q: How would you add a new chain in a week?**

The 60+ chain target is only sustainable if onboarding is templated. The week looks like:
- Day 1-2: Stand up nodes (use existing Snapchain template if chain family is supported; otherwise a one-time producer sync).
- Day 2-3: Implement the chain-specific decoder (raw block bytes -> universal asset_transfer + raw blob). For an EVM-family chain, this is config; for a novel consensus model, it's real work.
- Day 3-4: Configure confirmation thresholds and reorg policy. Wire push + poll sources.
- Day 4-5: Add Kafka topic, register consumer subscriptions.
- Day 5-7: Backfill from a recent block (not genesis), validate against the chain's own block explorer, then enable for deposit detection.

The thing that makes a week realistic: ChainStorage and the universal schema are already there. The new chain only adds the decoder and the node config.

**Q: How do you backfill a year of history?**

Backfill is the same code path as tip ingestion, just running in batch mode. Approach:
- Spin up a dedicated Chainsformer instance pointed at a historical range.
- It reads from ChainStorage (raw blocks already exist there because nodes synced from genesis), decodes, and writes to a parallel namespace in DynamoDB / Postgres.
- Backfill runs at full throttle, separate from tip ingestion. Per-chain Kafka clusters protect tip from being starved by backfill.
- Once backfill completes the range, swap the consumer's read pointer or merge namespaces.

The reason a year of backfill is feasible: ChainStorage is already populated. The expensive part (running a node from genesis) was paid once.

**Q: How would you support light clients vs full nodes?**

Full nodes give us everything; light clients give us headers + Merkle proofs. For an indexer, we always need full nodes for ingestion -- you can't decode tx-level events from headers. Light clients are a customer-facing product (mobile wallets), built on top of the indexer, not part of it. The indexer can serve light clients by exposing a header + proof API on top of ChainStorage.

**Q: How do you index NFTs efficiently?**

NFTs are a specialization of the ETH log/topic indexer. The decoder watches for:
- ERC-721 `Transfer(address,address,uint256)` (note: third argument is tokenId, not amount).
- ERC-1155 `TransferSingle` and `TransferBatch`.
- Mint events (transfer from `0x0`).
- Burn events (transfer to `0x0`).

NFT-specific projection lives in a dedicated derived index (e.g., a Postgres table keyed on `(contract_address, token_id)` with current owner, history, metadata URI). Heavy queries -- "all NFTs owned by address X across all collections" -- benefit from a separate consumer building this projection rather than overloading the asset_transfers table. Image / metadata resolution is async and downstream of the indexer (off the request path).

**Q: How would you handle a chain that introduces a new finality model mid-life (e.g., Ethereum's transition from PoW to PoS)?**

Confirmation thresholds are versioned per chain. The indexer config carries `(chain_id, height_range, confirmation_policy)` tuples. ETH's pre-merge blocks use the PoW threshold; post-merge blocks use the PoS finality model. The indexer applies the right policy per block. This is why centralizing confirmation policy in the indexer matters -- one config change, every consumer adapts.

**Q: How do you index cross-chain bridges?**

Bridges are events on chain A that correspond to events on chain B, with some delay. The indexer captures both sides as normal asset_transfers (bridge contract on chain A, mint event on chain B). A separate "bridge correlation" consumer joins them on a bridge-specific identifier (often a nonce or hash). This lives outside the core indexer because the correlation logic is bridge-specific and changes more often than the indexer schema.

**Q: What changes if Coinbase wanted to expose the indexer as an external product (Coinbase Cloud / NaaS)?**

Most of the architecture stays. The new concerns:
- Multi-tenant rate limiting and authentication on the query API.
- Per-customer namespacing of derived indices (some customers want NFT indexing; others don't pay for it).
- SLA (Service Level Agreement) differentiation (internal deposit detection vs. external customer queries).
- Cost attribution per customer for compute and storage.

ChainStorage and Chainsformer are already shared infrastructure between internal and external products at Coinbase, which is part of why they're open source -- the abstraction was designed for multi-consumer fan-out from day one.

---

## Related Topics

- [[../../../03-scaling-writes/index|Scaling Writes]] -- per-chain Kafka partitioning, idempotent ingestion via deterministic event_id
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- raw vs derived storage layering, hot/warm/cold tiering, re-derivation patterns
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- finality models, consensus differences across chains, eventually consistent indices
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- node desync, reorg storms, snapshot-based recovery, per-chain blast radius
- [[../../../07-real-time-systems/index|Real-Time Systems]] -- hybrid push/poll ingestion, streaming fan-out, latency budgets
- [[../../../05-async-processing/index|Async Processing]] -- backfill pipelines, derived index rebuilding, NodeSmith upgrade orchestration
