# Coinbase Staff System Design: Crash Course

A self-contained guide to the architecture patterns, technology choices, and failure modes that Coinbase interviewers expect Staff candidates to know. Read this before any Coinbase system design round.

**A note on vocabulary:** Coinbase has internal names for many of its systems: Aeron Cluster (open-source low-latency messaging library with built-in RAFT), ChainStorage (Coinbase's open-source data-availability layer for raw blocks, ~1500 blocks/sec), Snapchain (Coinbase's blue/green blockchain node deploy system using EBS snapshots), Solana I/O (Coinbase's per-chain dedicated Solana ingestion pipeline, 12x throughput), cb-mpc (Coinbase's open-source MPC library released March 2025), FinHub-Ledger (Coinbase's ledger team), NodeSmith (AI-agent automation for blockchain node upgrades across 60+ chains). In the interview, name-drop them once to show you've done your homework, then describe the underlying industry pattern. You don't need experience with the specific tools -- you need to recognize the categories.

---

## How Coinbase Thinks About Architecture

Coinbase is a regulated, custody-grade, 24/7 financial platform serving ~110M verified users. Every design decision is downstream of three constraints:

1. **Customer fund safety is the top priority.** The system is judged not on uptime but on whether $1 of customer crypto ever leaves without authorization. ~98% of customer assets live in air-gapped cold storage. Multi-tier custody (hot/warm/cold) plus MPC (Multi-Party Computation -- multiple parties jointly compute over secret inputs without revealing them), HSM (Hardware Security Module -- tamper-resistant device that holds keys and signs without exposing them), and multi-sig signing are first-class architectural concerns. Coinbase is the qualified custodian for 9 of 11 spot BTC ETFs (Exchange-Traded Funds) and 8 of 9 ETH ETFs -- their custody brand is what the institutional market trusts.

2. **Volatility is the design target.** During BTC pumps, ETF approvals, or major news, traffic spikes 10x. Identity service serves 1.5M reads/sec at peak. Coinbase ML predicts spikes 60 minutes ahead and pre-warms infrastructure. Trading halts on >10% price moves in 5 minutes -- *consistency wins over availability for trading paths*. If your design handles steady-state but collapses during a Bitcoin pump, it fails.

3. **Compliance is structural, not a sidecar.** KYC (Know Your Customer) tiers, OFAC (Office of Foreign Assets Control -- US Treasury sanctions body) screening, Travel Rule -- FinCEN/FATF rule requiring originator/beneficiary info above ~$3000 (>$3K), SAR (Suspicious Activity Report) (>$10K daily), audit immutability, jurisdiction policy, and per-state US licensing (NY BitLicense -- NY DFS virtual-currency-business license, etc.) live in the *first* architecture diagram. "Bolt-on compliance" is a top reject pattern.

**How to frame any Coinbase problem in an interview:** "At the core this is a regulated financial system with custody-grade security. The shape of the answer is: protect customer funds against worst-case adversaries, design for 10x volatility spikes, and treat compliance as architecture from minute one. When money flows, the ledger is double-entry append-only. When chains are involved, reorgs are expected events. Fail-closed for money paths, fail-open for read paths."

This framing is the inverse of the Shopify mental model. Shopify protects the revenue path with fail-open and tiered degradation. Coinbase protects the fund-safety path with fail-closed and conservative default behavior.

---

## The Coinbase Interview Loop (Staff / IC6)

Knowing the loop shape helps you allocate prep time:

1. **Recruiter screen** (30-45 min) -- background, motivation, cultural-tenet alignment.
2. **Triple-set screen** -- CCAT (~15 min cognitive), values test (~15 min), CodeSignal (90 min, 4 problems, production-quality code expected, *not* LeetCode-optimal).
3. **Hiring manager screen** (45-60 min) -- behavioral + scope.
4. **Pair programming / "machine coding" round** (60-90 min, sometimes two of these). Build a real subsystem incrementally as requirements expand. **This is where most candidates fail** -- production-grade code with clean naming, separation of concerns, idiomatic style. Not LeetCode optimization.
5. **System design** (60-90 min). Whiteboard / Excalidraw. Problems are larger than the time slot -- they stop you when they have a signal, not when you "finish."
6. **Reverse system design** (IC6+, 45-60 min). Walk through a system you've actually built. Coinbase's published guidance: *"if you know the basics of an online brokerage, you're about as ready as you can be"* -- bring real-time price feeds, multi-exchange API aggregators, or trading-system components even if your past work wasn't crypto.
7. **Behavioral / leadership** (45-60 min). STAR format mapped to the 10 cultural tenets.
8. **(IC6+) Senior leadership / cross-functional** (60 min) -- director or VP. Strategic vision, business judgment, ability to influence at the org level.

**Bar Raiser system.** Every panel includes at least one trained bar raiser with explicit veto power. Hiring rule: *"If you're not a hell yes, you're a no."* A "maybe" rounds to "no." Hiring managers do not have unilateral authority. This means your worst round can sink you even if the others were strong.

**Top rejection cause.** Per Coinbase's own blog: *"Most candidates who fail do so because their code or process isn't good enough."* Sloppy code in pair programming is the #1 killer. System design rejection patterns are listed in the [Common Mistakes](#common-mistakes-that-fail-candidates) section.

---

## Cultural Tenets That Show Up in Design Rounds

Coinbase has 10 cultural tenets and 6 engineering principles. The ones most relevant to system design rounds:

| Tenet / Principle | What it looks like in system design |
|---|---|
| **#SecurityFirst** | Custody, KMS (Key Management Service), MPC, multi-sig drawn into the *first* diagram. Audit trail is non-optional. |
| **#ExplicitTradeoffs** | Every choice paired with the rejected alternative + reason. "Postgres over DynamoDB because we need multi-row transactions; we pay with horizontal scale ceiling, mitigated by sharding." |
| **#BuildValue** | Don't reinvent Kafka, Redis, Postgres, Aeron. Do build the matching engine, custody flow, ledger, compliance engine. |
| **#OneCoinbase / #APIDriven** | Design APIs other teams can build on. Loose coupling enables independent deploys. |
| **#1-2-Automate** | Anything done three times gets automated. NodeSmith for blockchain node upgrades is the canonical example. |
| **Act Like an Owner** | Walk through cost, on-call, observability, blast radius, capacity. Not just "the system works." |
| **Repeatable Innovation** | Standardize, platform-think. Reference Project 10 Percent (70/20/10 work split). |
| **Tough Feedback / Continuous Learning** | When pushed back on, react curiously. *"Being wrong with confidence is a negative signal; humility is a positive signal"* -- Coinbase's own words. |
| **Mission First** | If asked, frame designs around economic-freedom mission; explain why a feature serves users globally. |

The single most-cited differentiator at staff level: **explicit tradeoffs paired with rejected alternatives.** Make it audible.

---

## The Technology Stack

### Databases

**PostgreSQL (primary OLTP and ledger store)**

OLTP = Online Transaction Processing. Coinbase's source of truth for user balances, journal entries, account state, withdrawal requests, KYC applications. Strong consistency is non-negotiable.

**When to reach for Postgres at Coinbase:**
- Any double-entry journal entry (financial ledger, deposit/withdrawal accounting)
- Any state machine for high-stakes operations (withdrawal pipeline, KYC, signing requests)
- Any data that must survive a cache failure
- Audit logs and append-only event trails

**Key patterns to know:**
- **Append-only journal entries.** Never `UPDATE balance = balance - 100`. Always `INSERT INTO journal_entries (account, debit, credit, ...)`. Balances are derived.
- **Sub-account partitioning for hot accounts.** The exchange omnibus account is touched by every trade -- if you serialize all trades through one row, you get nowhere. Split it into N sub-accounts and route writes by hash; rollups happen offline.
- **Idempotency keys with unique constraints.** `UNIQUE (idempotency_key)` on the entries table is the database-level last-line-of-defense against duplicate writes from retries.
- **Optimistic concurrency** with version columns for general transactional flows.
- **Pessimistic locking** (`SELECT FOR UPDATE`, `SELECT FOR UPDATE SKIP LOCKED`) for hot rows or queue-style processing.
- **Sharding by user_id** is the typical strategy when one Postgres can't handle the load. Per-user transactional integrity matters more than cross-user atomicity for most flows.
- **Outbox pattern** for atomic publish-after-commit (write business data + outbox row in one transaction; relay process publishes to Kafka).
- **Multi-region replication** for DR. Sync replication for the journal (RPO=0). Async replicas for reads.

**Why not DynamoDB for ledger?** No multi-row transactions on the partitions you care about. Limited support for complex constraints. The ledger needs ACID (Atomicity, Consistency, Isolation, Durability) across debit + credit pairs; Postgres gives that natively.

**DynamoDB (high-throughput KV / online feature store)**

Where Coinbase reaches for DynamoDB: identity-service hot lookups (1.5M reads/sec), online feature store for ML serving (sub-50ms), session state, sequence-feature lookups for fraud models.

**When DynamoDB beats Postgres:**
- Pure key-value access patterns where you don't need joins or transactions
- Read traffic that exceeds what a Postgres replica fleet can serve cost-effectively
- Workloads with predictable per-key access (a user's last 100 transactions)

**Key patterns:**
- **Single-table design** with composite sort keys for relational-ish access patterns
- **TTL (Time To Live) on hot ephemeral data** (sessions, feature freshness windows)
- **Conditional writes** for compare-and-swap semantics (replaces optimistic locking)
- **Streams** for change data capture without dual-write risk

**Aurora — AWS managed Postgres/MySQL (settlement state, trading metadata)**

Coinbase International Exchange (Bermuda-regulated 24/7 derivatives exchange) uses Aurora for trade settlement state. Why: managed Postgres with read scaling, fast failover, snapshot-based backups, multi-AZ.

**Redis (rate limits, session state, pub-sub, ZSETs)**

Used for sub-millisecond hot-path needs alongside the durable store. Same patterns as Shopify: rate limit counters, session caches, sorted sets for leaderboards (top trending pairs in Coinbase Explore (Coinbase's market discovery surface)), Lua scripts for atomic operations.

**RocksDB — embedded key-value store (streaming state)**

Embedded key-value store backing Spark Real-Time Mode (Databricks' sub-second streaming mode) streaming aggregations in fraud detection. Why: durable local state for streaming windows, supports exactly-once semantics with replay.

**InfluxDB / TimescaleDB (time-series, K-line history)**

For market-data K-line aggregations (1m, 5m, 1h, 1d candles), trade history, latency metrics. Time-series-optimized compression, automatic downsampling, retention policies.

**Object storage (S3) + immutable raw block tier**

For ChainStorage's raw block layer, audit log cold tier (5-7 year regulatory retention), KYC document vault (with KMS field-level encryption), large reconciliation snapshots.

**Data warehouse (Databricks, Snowflake, BigQuery analogues)**

For cross-user analytics, model training feature backfill, regulatory reporting. Coinbase publicly uses Databricks Lakebase for online predictions and Spark for offline materialization.

**Lakebase** is Databricks' Postgres-compatible serving layer that Coinbase migrated fraud-model serving onto -- gets you Postgres reads with seamless integration into the Databricks training workflow.

### Capacity Reference Numbers

Use these to sanity-check claims in interview:

| System | Throughput | Latency | Notes |
|---|---|---|---|
| Postgres single node | 5-10K writes/sec | 1-10ms | Beyond this, shard. |
| DynamoDB | 100K+ ops/sec per table | <10ms p99 (99th-percentile latency) | Auto-scales with on-demand pricing. |
| Redis single node | 100K+ ops/sec | <1ms | Memory-bound, not throughput-bound. |
| Kafka per partition | 10-100K msg/sec | 1-10ms | Per partition; cluster total scales with partitions. |
| Matching engine (Coinbase Aeron + RAFT (consensus algorithm with leader-replicated log)) | 100K-2M ops/sec per pair | <50us internal, <1ms wire | Single-threaded per pair, sharded across pairs. |
| WebSocket (bidirectional persistent TCP connection over HTTP-upgrade) fan-out per node | 10-50K connections | 10-100ms tick latency | Conflate to slow consumers. |
| ChainStorage raw block serving | Up to 1500 blocks/sec | 10-100ms | Coinbase published number. |
| Spark RTM (Spark Real-Time Mode) stateless features | --- | 150ms | Per Coinbase Databricks case study. |
| Spark RTM stateful aggregations | --- | 250ms | Per Coinbase Databricks case study. |

### Message Queues and Streaming

**Kafka (event backbone)**

Same patterns as Shopify: durable log, partitioned by key (typically `user_id` or `chain_id`), multiple consumer groups for independent fan-out, CDC (Change Data Capture) via Debezium (open-source CDC tool) for database change streams.

**Coinbase-specific patterns:**
- **Per-chain Kafka clusters.** Solana I/O isolates Solana traffic from other chains (12x throughput improvement). The lesson: don't share a broker across heterogeneous traffic patterns.
- **One transaction per Kafka message** (Solana I/O pattern). Don't bundle blocks; let downstream consumers parallelize at the transaction level.
- **Settlement bus** between matching engine and ledger. Matched trades emit to Kafka with `(pair, sequence_number)` as key for per-pair ordering. Ledger consumes and applies double-entry idempotently.
- **Transactional outbox** for any DB-then-publish flow. Never publish from app code after a DB commit -- commit + outbox row in one transaction, separate relay publishes.

**Aeron Cluster + RAFT**

Coinbase's matching engine uses Aeron (open-source low-latency messaging) with RAFT consensus for *replication of compute* (deterministic state machine replicated across nodes by replaying the same input log). Single-threaded per pair, in-memory order book, NVMe (Non-Volatile Memory Express -- fast SSD protocol)-backed WAL (Write-Ahead Log) for durability, sub-50us internal latency, sub-millisecond wire p99.

**LMAX Disruptor (lock-free fixed-size ring-buffer pattern from LMAX Exchange) / Ring Buffer**

Coinbase Aug 2025 blog: market data fan-out replaced Go channels with LMAX-style fixed-size ring buffer + sync.Cond + sync.Pool. Result: 38x latency reduction. The pattern: lock-free producer-consumer queue with subscriber-paced reads.

**Temporal — workflow orchestration platform**

Coinbase publicly uses Temporal for long-running multi-step async workflows: KYC onboarding, withdrawal pipelines, signing ceremonies. Why: durable state across retries and crashes, replay-safe activity execution, observable workflow IDs that survive client disconnect.

### Caching and Edge

**CDN for static assets and public market data snapshots.** Coinbase Explore's "top 100 trending" can be CDN-cached with 5-30s TTL.

**Multi-region anycast** for global routing. WebSocket connections terminate at the nearest edge cluster, fan-out reaches them via regional brokers, central matching engine remains the source of truth (per-pair).

**WAF (Web Application Firewall) + L7 (OSI Layer 7) rate limiting** at the edge for OFAC pre-checks, abuse mitigation, bot defense.

---

## Architecture Patterns

### Two-Path Architecture (Trading Hot Loop vs. Market Data Fan-Out)

**How to describe this problem:** "A trading system has two completely different shape requirements: the matching hot loop needs sub-millisecond determinism, and the market-data fan-out path needs to push to thousands of slow consumers. Mixing them poisons the hot loop. The pattern is two failure domains, two replication models, two SLAs (Service Level Agreements)."

**Hot loop:** sequencer → risk gateway → matching engine → WAL → fill emitter. Single-threaded per pair, in-memory order book, deterministic from WAL replay, NVMe-backed durability, RAFT replication of compute (not data).

**Fan-out path:** matching engine emits to ring-buffer-fronted bus → core fan-out cluster → regional brokers → edge WebSocket terminators → clients. Conflated, lossy at the edge, slow-consumer kicked + re-snapshot.

State this split in the *first sentence* of any trading or market-data answer. It's the single highest-leverage staff-level move.

### Double-Entry, Append-Only Ledger

**How to describe this problem:** "When money flows, balances are derived from an immutable journal of debits and credits, not stored as mutable fields. The pattern is double-entry bookkeeping: every transaction produces two equal-and-opposite journal entries. The sum of entries on an account is the balance. Corrections are reversing entries, never updates."

This is the FinHub-Ledger team's signature design. Open any money-touching design with this framing.

**Why mutable balances fail:**
- Race conditions on the balance row (two writers both decrement from a stale value)
- No audit trail (you can't reconstruct what happened)
- No replay (you can't rebuild a user's history from the journal)
- No reconciliation (you have one source of truth, not two to compare)

**Why double-entry wins:**
- Each transaction is atomic with both entries in one DB transaction
- The journal is the audit trail by construction
- Replay rebuilds any account's balance from `SUM(credits) - SUM(debits)`
- Reconciliation against external sources (chain, bank) is a continuous diff against the journal

### Multi-Tier Custody (Hot / Warm / Cold)

**How to describe this problem:** "Customer crypto must be safe from external attackers, insider threats, supply-chain compromise, and `$5 wrench` coercion of any single human. The pattern is multi-tier custody with progressively stronger trust requirements. ~2-5% in HSM-backed hot, 5-20% in MPC/TSS warm, 75-98% in air-gapped cold."

**Hot tier (HSM-backed signing):**
- Operational liquidity for instant withdrawals
- HSM generates and holds private keys; keys cannot be exported
- Per-withdrawal limits ($10K typical for BTC), daily velocity caps
- 2-5% of total assets, bounded by insurance underwriting limits

**Warm tier (MPC / TSS (Threshold Signing Scheme -- k-of-n parties produce one signature)):**
- Mid-size institutional withdrawals
- Coinbase open-sourced cb-mpc library (March 2025): ECDSA (Elliptic Curve Digital Signature Algorithm -- Bitcoin/Ethereum signatures) + EdDSA (Edwards-curve Digital Signature Algorithm -- Solana signatures) threshold signing
- Key shares distributed across HSMs in different security zones
- Full key never reconstructed at rest or in flight
- Quorum policy (e.g., 3-of-5 shares) for signing approval

**Cold tier (air-gapped + multi-sig):**
- Bulk reserves
- Cross-Domain Solution (CDS -- military-grade air-gap technology) bridges air-gap when needed
- Multi-sig with quorum approvers, camera-monitored cold rooms
- Promotion ceremonies (cold→warm) are deliberately slow, multi-human, audited

Funds move *down* tiers continuously (deposits hit warm, sweep to cold). Funds move *up* only via slow ceremonies. No automated cold-to-hot path.

### State Machines for High-Stakes Operations

**How to describe this problem:** "Operations that touch money or compliance involve multiple steps that can fail at any boundary. The pattern is a durable state machine where every transition is an idempotent journal entry, and recovery from partial state walks the state machine forward (or compensates) -- never ad-hoc rollback."

Examples:

```
Deposit:
  DETECTED → PENDING_CONFIRMATIONS → CONFIRMED → CREDITED → SETTLED
                ↓                       ↓
             REORGED ----------------- REORGED (reverse credit)

Withdrawal:
  REQUESTED → DEBITED → RISK_PASSED → POLICY_PASSED → UNSIGNED → SIGNED → BROADCAST → CONFIRMED → SETTLED
       ↓        ↓          ↓             ↓             ↓          ↓          ↓           ↓
     REJECTED  RETURNED  RETURNED      RETURNED      FAILED   RBF_SENT   ABANDONED  REORGED

KYC:
  STARTED → SUBMITTED → DOC_VERIFIED → SANCTIONS_CHECKED → SCORED → DECIDED
              ↓             ↓               ↓                ↓
           ABANDONED      MANUAL_REVIEW  MANUAL_REVIEW   MANUAL_REVIEW
```

If you can't draw the state machine in interview, you can't reason about partial-failure recovery. Coinbase explicitly probes "what happens if the process dies between step N and N+1?"

### Per-Chain Confirmation Policy and Reorg Awareness

**How to describe this problem:** "Each blockchain has a different finality model. Treating them uniformly is wrong. The pattern is a per-chain confirmation policy table, with reorg as an *expected* state transition, not an exception."

| Chain | Default confirmations | Notes |
|---|---|---|
| Bitcoin | 3-6 (amount-tiered) | Higher confirmations for >$10K equivalents |
| Ethereum | 12 | Coinbase's published number; higher for institutional flows |
| Solana | Fast finality (~12.8s) | Slot-based; commitment levels (processed/confirmed/finalized) |
| Polygon | 256 blocks | ~8-10 minutes to finality |
| Layer 2 / L2 (rollups and scaling layers on top of L1; Base is Coinbase's Ethereum-aligned L2; Arbitrum, Optimism) | Varies; depends on L1 finality | Optimistic rollups have 7-day challenge windows; respect that for large amounts |

**Reorg handling state machine:**
1. Block ingested → emit "tentative" event
2. Watch confirmation count → at threshold, emit "finalized" event
3. If chain reorgs *below* the finalized point → page on-call (this should never happen in practice; if it does, your confirmation threshold was wrong)
4. If chain reorgs *above* the finalized point but below the credit threshold → reverse tentative credits, re-emit on the new chain

**Deposit detection latency** = time from block-on-chain to user balance credited. This is the customer-facing metric. Coinbase's Solana I/O pipeline cut this 20% by per-chain optimization.

### Idempotency End-to-End

**How to describe this problem:** "Every operation across multiple systems must be replay-safe. A retry from the client should not double-charge. A failure between signing and broadcast should not produce two on-chain transactions. The pattern is an idempotency key propagated end-to-end -- client → API → ledger → external systems -- with each layer deduping by key."

**Key derivation rules:**
- **Client-initiated:** `(user_id, intent_id)` from the client
- **System-initiated:** `(source_system, source_event_id)` (e.g., `(matching_engine, fill_id)` for settlement)
- **Chain-initiated:** `(chain, txid, log_index)` for on-chain events
- **Fan-out:** `(event_id, subscription_id)` for webhook delivery

**Failover trap:** Idempotency keys are scoped to a single backend. Failing over from one signer to another with the same key can produce two valid signatures of different on-chain transactions. Always namespace per-backend (e.g., `hsm-east:abc-123` vs `hsm-west:abc-123`) and *check status before failover*. Same trap as Shopify's payment-gateway failover.

### Reconciliation as a First-Class Subsystem

**How to describe this problem:** "Two sources of truth must continuously agree. Internal ledger ↔ blockchain state. Internal ledger ↔ bank statements. Online feature store ↔ offline batch. The pattern is a continuous reconciler that diffs both sides, alerts on drift, and never auto-corrects financial drift."

**Reconciliation tiers:**
- **Continuous (per-event):** Every chain confirmation diffs against the journal entry that should have been created. Lag > 30s alerts.
- **Periodic (per-block, per-batch):** Sweep recent blocks, compare ledger state, flag discrepancies.
- **End-of-day:** Full state snapshot reconciliation, generated for compliance.

**Auto-correct policy:**
- Cache or derived-state drift: auto-correct (re-derive from journal)
- Financial journal drift: *never* auto-correct -- page on-call, manual investigation required

This is what separates audit-ready from "works in dev." The reconciler exists because every distributed system drifts; the question is detection latency and escalation.

### Online / Offline ML Feature Parity

**How to describe this problem:** "ML features computed during model training must be identical to those computed during model serving. Two pipelines drift silently and the model that scored 95% offline scores 60% in production. The pattern is one feature pipeline with two sinks: an online store for serving and an offline materialization for training."

Coinbase's Spark RTM stack:
- One Spark Structured Streaming job consumes events from Kafka
- Stateless features computed inline (target: 150ms)
- Stateful aggregations backed by RocksDB local state (target: 250ms)
- Output sinks: DynamoDB (online serving) + Tecton/feature warehouse (offline materialization)
- Both sinks share the same feature transformation code

**Sequence features for ML** (Coinbase blog 2025): user action sequences feed LSTM (Long Short-Term Memory -- sequence-modeling RNN variant) and Transformer (neural network using self-attention) models. Stateless pipeline conforms schema, writes to DynamoDB. Tecton (feature platform with online/offline parity) + Spark for offline materialization. >98% online/offline parity is the published target.

### Score / Decide / Act Layer Separation

**How to describe this problem:** "Risk and compliance decisions involve three independent concerns: how risky is this (model output)? what should we do (policy)? how do we enforce (plumbing)? Conflating them makes the system unmaintainable. The pattern is three layers, one direction."

- **Score:** ML model produces a number (or vector). Versioned, A/B (randomized controlled experiment)-able, shadow-deployable.
- **Decide:** Versioned policy bundle (rules + thresholds) consumes the score and produces an action class (`allow`, `block`, `2fa_challenge`, `manual_review`, `rate_limit`). Policy is data, deployable independently.
- **Act:** Plumbing that executes the action. Idempotent, audit-logged, explainable per decision.

Adding a new fraud signal adds a feature. Tuning a threshold ships a policy bundle. Adding a new enforcement type ships an action handler. Each is independent.

### Defense in Depth on Money Movements

**How to describe this problem:** "Money movement passes through multiple independent gates so that compromising one (a stolen 2FA (Two-Factor Authentication), a phished account) doesn't bypass the rest. Cheapest gates first to fail fast."

Withdrawal gate ordering (cheap → expensive):
1. Authentication / 2FA
2. Velocity limits (per-asset, per-day)
3. Withdrawal address allowlist (48-hour wait on new addresses)
4. OFAC sanctions screening
5. Travel Rule data collection (>$3K)
6. Address risk score (Node2Vec graph-embedding algorithm)
7. ML fraud score
8. Policy gate (jurisdiction, tier eligibility)
9. Hot tier capacity check
10. Sign + broadcast + N-confirmation watch

Each gate is independent. The $320M crime insurance policy is contingent on this defense-in-depth posture.

### Compliance as Architecture

**How to describe this problem:** "KYC tiering, OFAC screening, Travel Rule, SAR generation, audit immutability, retention, jurisdiction policy -- these are first-class services with versioned policies, drawn into the *first* architecture diagram, not added at the end."

Concrete primitives:

| Compliance concern | Architectural primitive |
|---|---|
| Audit immutability | Append-only journal + hash-chained audit log with externalized roots |
| KYC tier gating | Tier engine queried on every fund-touching action |
| Travel Rule (>$3K) | Withdrawal pipeline gate, originator/beneficiary metadata in tx context |
| SAR (>$10K daily) | Streaming aggregation, auto-generated case for filing |
| OFAC sanctions | Address screen on every outbound, periodic re-screen |
| Jurisdiction policy | Policy table joined on `user.jurisdiction` at decision time |
| Retention (5-7yr) | Tiered storage with cold-archive lifecycle |
| Explainability | Feature snapshot + model version stored per decision |
| Re-KYC trigger | Event-driven (jurisdiction change, high volume) + periodic |

### Predictive Autoscaling for Volatility

**How to describe this problem:** "Coinbase load is bimodal. Steady-state is one thing; BTC pump or ETF approval is 10x. Reactive autoscaling can't react fast enough -- by the time the metric crosses threshold, the spike has started and you're already overloaded. The pattern is predictive: classify upcoming spikes from upstream features and pre-warm 60 minutes ahead."

Coinbase's published autoscaler:
- Time-series forecasting alone is insufficient (no causal lag)
- Feed upstream features: price moves, social signals, scheduled events (ETF decisions, earnings, halvings)
- Classify "spike incoming" 60 minutes ahead
- Pre-warm databases, replicas, application servers, WebSocket terminators, hot wallet liquidity

This pairs with circuit breakers for the unforecasted long tail and per-tier capacity headroom for the steady state.

### Workflow Orchestration (Temporal)

**How to describe this problem:** "Long-running, multi-step async processes need durable state across process crashes, replay-safe activity execution, and observable workflow IDs that survive client disconnects. The pattern is a workflow orchestrator -- Temporal in Coinbase's case."

When to reach for it:
- KYC application (multi-step, multi-vendor, save/resume across sessions)
- Withdrawal pipeline (debit → risk → policy → sign → broadcast → confirm, each idempotent)
- Signing ceremonies (multi-human approvals with timeouts and escalation)
- Cold-to-warm rebalance ceremonies

Why not a database state column + cron + ad-hoc service calls:
- Crash between steps loses the in-flight workflow
- Retries at each step require manual idempotency tracking
- Observability is "log files and a dashboard" instead of "this workflow is on step 4 of 7, last activity completed 200ms ago"
- Replay for debugging is impossible

Temporal gives you all of that as primitives.

### Per-Chain Pipelines Beat Chain-Agnostic at Scale

**How to describe this problem:** "Initial blockchain ingestion abstracts over chains. Eventually one chain (Solana) has 10x the throughput of others, and the unified pipeline buckles. The pattern is per-chain dedicated pipelines with a normalized output schema, not a chain-agnostic input pipeline."

Coinbase's Solana I/O blog (2025):
- Hybrid ingestion: Geyser (Solana's push-based stream interface for low-latency data) push (low latency, lossy on restart) + parallel RPC backfill (slow, authoritative)
- Dedicated Kafka cluster (isolation from other chains)
- One transaction per Kafka message (not whole blocks), enables transaction-level parallel consumption
- Result: 12x throughput, 20% deposit latency reduction, absorbs 8x baseline traffic spikes

The general lesson: **specialize the pipeline per chain; abstract over chains at the *event schema* layer.**

---

## Patterns for Specific Problem Domains

### Trading and Order Matching

**How to frame it:** "A trading engine is fundamentally a deterministic state machine over a sequenced input log, optimized for sub-millisecond latency and replicated for fault tolerance. The hardest subproblems are sequencing (linearization point), matching (in-memory price-time priority), durability (WAL with RAFT), and fan-out separation."

- Two-path architecture (hot loop vs market data) -- the highest-leverage move
- Single-threaded matching per trading pair, sharded across pairs
- Aeron Cluster + RAFT for replication of compute (not data)
- NVMe-backed WAL for durability; RPO=0 (Recovery Point Objective), RTO (Recovery Time Objective) seconds via RAFT failover
- Risk pre-check (balance/margin verification) *before* the matching engine
- Matched trades emit to settlement bus → ledger consumes for double-entry
- Circuit breakers halt trading on >10% moves in 5 min (consistency > availability)
- Predictive autoscaling for volatility (60-min lead time)
- Sub-50us internal matching, sub-millisecond wire p99
- 100K-2M ops/sec aggregate, 50-100K/sec on the hottest pair during a pump

### Custody and Wallet Architecture

**How to frame it:** "Custody is a security-first domain optimized for the worst-case adversary. The patterns are multi-tier funds segregation (hot/warm/cold), threshold signing (MPC/HSM/multi-sig), defense in depth on money movements, and explicit insider-threat modeling."

- Hot/warm/cold tier split with ~2-5% / 5-20% / 75-98% asset distribution
- HSM for hot tier signing (keys generated on-device, non-exportable)
- MPC (cb-mpc, open-sourced March 2025) for warm tier, key shares across HSMs
- Multi-sig + air-gap (CDS) for cold tier with quorum approvers and ceremonies
- Withdrawal limits ($10K hot, daily velocity caps), allowlist with 48-hour wait
- Per-asset confirmation thresholds; reorg as expected event
- Address risk score (Node2Vec) on every outbound destination
- KYC tier gating, OFAC screening, Travel Rule (>$3K), SAR (>$10K daily)
- Audit log immutability with hash-chained externalized roots
- Insider threat as first-class: no single human can move funds, quorum + cooling-off periods

### Financial Ledger

**How to frame it:** "A financial ledger is fundamentally a double-entry append-only journal with derived balances, end-to-end idempotency, and continuous reconciliation against external sources of truth. The hardest subproblems are concurrency on hot accounts (the omnibus), cross-system saga compensation, and reconciliation drift detection."

- Double-entry, append-only journal -- never mutable balance fields
- Integer smallest-units + explicit currency code, never floats
- Idempotency keys with `UNIQUE` constraints as last-line defense
- Sub-account partitioning for hot accounts (omnibus split into N rows)
- Outbox pattern for atomic publish-after-commit to Kafka
- Continuous reconciliation: chain ↔ ledger, bank ↔ ledger, drift alerts
- Cost basis tracking (FIFO/LIFO/HIFO selectable per user) for tax
- 5-7 year retention with tiered storage (hot Postgres, cold S3)
- Sharding by `user_id` when single Postgres can't carry the write load

### Blockchain Indexing and Ingestion

**How to frame it:** "Multi-chain ingestion is a derived-view problem with the chain as source of truth and a normalized event schema as the abstraction. The hardest subproblems are reorg handling, per-chain throughput specialization, and storage layering (raw immutable + derived re-buildable)."

- Per-chain pipelines (Solana I/O lesson) with normalized output schema
- Hybrid push (Geyser, ZMQ, Erigon stream) + poll (RPC) ingestion
- Reorg as a first-class state transition: `BLOCK_SEEN → PENDING → FINALIZED → REORGED`
- Per-chain Kafka clusters for isolation
- Storage layering: raw blocks immutable in S3 (ChainStorage pattern), derived indices in DynamoDB/Postgres/ES
- Re-derivation on schema change without re-ingesting from chain
- Snapchain for blue/green node deploys (EBS (Elastic Block Store -- AWS persistent disks) snapshots, 30-day max server life)
- NodeSmith for AI-driven node upgrades across 60+ chains
- Centralized confirmation policy table joined per asset

### Real-Time Market Data

**How to frame it:** "Market data is a fan-out problem with millions of concurrent slow consumers, a tiny set of fast authoritative producers, and asymmetric latency tolerance. The hardest subproblems are conflation, snapshot+diff protocol, multi-tier broker topology, and slow-consumer isolation."

- Two-path split from the matching engine
- LMAX-style ring buffer (38x improvement over Go channels)
- Multi-tier fan-out: matching engine → core fan-out → regional brokers → edge WebSocket → clients
- WebSocket protocol with subscribe/unsubscribe, snapshot + sequence number + diffs, gap detection, resume
- Conflation: drop-old-keep-new for ticker; kick-and-resnapshot for slow level2 consumers
- Per-pair ordering guaranteed; cross-pair ordering not
- Storage: in-memory ring (hot), Redis ZSET (trending), Timescale (K-line), S3 (cold archive)
- REST + CDN for initial page load, WS upgrade for live
- Multi-region with anycast routing; central matching engine is canonical
- Predictive autoscaling for 10x volatility bursts

### Fraud and Risk Scoring

**How to frame it:** "Real-time fraud detection is a streaming ML serving problem with regulatory explainability requirements. The hardest subproblems are online/offline parity, sub-250ms feature serving, multi-model orchestration, and adversarial robustness."

- Spark Real-Time Mode: stateless features 150ms, stateful aggregations 250ms
- RocksDB for streaming state, Lakebase Postgres for online prediction serving
- DynamoDB online feature store for sub-50ms hot lookups
- Sequence features (LSTM/Transformer) on user action streams
- Address risk via Node2Vec graph embedding on the chain address graph
- Score / Decide / Act layer separation
- Multi-model ensemble with shadow + A/B + ramp deployment
- Online/offline parity >98% via single-pipeline-two-sinks
- Adversarial defense: rate-limited feature lookups, no oracle attacks, response polymorphism
- Explainability via SHAP (SHapley Additive exPlanations) + feature snapshot + model version per decision
- Chainalysis / Elliptic (blockchain analytics vendors) integration for blockchain analytics
- Travel Rule, SAR auto-generation, OFAC screening built into the action layer

### Deposit / Withdrawal Pipeline

**How to frame it:** "The deposit/withdrawal pipeline is the operational seam between blockchain state and the internal ledger. The hardest subproblems are reorg handling, idempotent state transitions across many systems, mempool (a node's pool of unconfirmed transactions) dynamics (RBF, ETH nonce ordering, fee escalation), and reconciliation."

- Deposit state machine: `DETECTED → PENDING → CONFIRMED → CREDITED → SETTLED` with reorg branches
- Withdrawal state machine: `REQUESTED → DEBITED → RISK → POLICY → SIGN → BROADCAST → CONFIRM → SETTLE`
- Per-chain confirmation policy with amount-tiered thresholds
- Policy gates ordered cheap-first: 2FA → velocity → allowlist → OFAC → Travel Rule → address score → fraud score
- Signing dispatch by tier (HSM hot, MPC warm, multi-sig cold)
- RBF (Replace-By-Fee -- Bitcoin fee-bump protocol) strategy for stuck BTC, gas escalation for stuck ETH (with nonce ordering)
- Batch withdrawals (combine N customers' outputs into one ETH tx) with saga compensation
- Reconciliation: continuous + periodic + EOD, never auto-correct journal drift
- Operational tooling: dashboards, alerts, manual ops console, kill-switch

### KYC and Onboarding

**How to frame it:** "Account onboarding is a regulated workflow problem -- multi-step, multi-vendor, multi-jurisdiction, save-resume across sessions, with risk-based decisioning. The hardest subproblems are workflow durability, vendor abstraction, jurisdiction policy as data, and PII handling."

- Workflow orchestration (Temporal) for durable multi-step async
- Per-jurisdiction tier matrix as data, not code
- Vendor abstraction for document verification (Onfido / Persona / Jumio (identity verification vendors) interchangeable)
- Sanctions screening with partial-match handling, periodic re-screening
- Risk-based decisioning combining doc + sanctions + fraud + behavioral signals
- Manual review queue with case management, SLA, ownership, audit trail
- Save/resume via stable workflow IDs across sessions
- PII (Personally Identifiable Information) vault (S3 + KMS field-level encryption), strict access logs, redaction in non-prod
- Re-KYC: periodic + event-triggered (jurisdiction change, high volume)
- Anti-bot: device fingerprinting, IP reputation, velocity caps, captcha challenges

---

## Common Mistakes That Fail Candidates

The mistakes that recur most across the 8 exercises:

1. **Generic SaaS framing.** Treating Coinbase like Twitter or Uber. No nod to ledger correctness, custody tiers, blockchain finality, KYC/AML (Anti-Money Laundering), irreversibility of fund movement, 24/7 ops. *Failing to clarify constraints* and *copying generic templates without crypto-specific considerations* are flagged repeatedly.

2. **Mutable balance fields / floats for money.** `UPDATE accounts SET balance = balance - 100` is an instant signal of "doesn't understand financial systems." Same for IEEE 754 floats on amounts.

3. **Treating broadcast as "done".** A withdrawal isn't done until confirmed at N blocks. Mempool replacement, gas escalation, reorgs all happen between broadcast and finality. State machines must include all these states.

4. **No reorg handling.** Treating chain reorgs as exceptional rather than expected. Every chain reorgs at some depth.

5. **Mixing trading hot loop with market data fan-out.** One bus for both = slow consumers poison the matching engine. Two paths, two failure domains.

6. **Bolt-on security and compliance.** KYC, OFAC, audit log added at the end of the design. They go in the first diagram.

7. **Single global circuit breaker.** "Stripe is down" globally takes out healthy regions. Always scope (provider, region) or (chain, network).

8. **Fail-open for money paths.** Coinbase's fail-mode is the inverse of Shopify's. For money, fail-closed (halt withdrawals) beats fail-open (let them through with degraded checks).

9. **Same idempotency key across signing backends.** Failing over from one HSM to another with the same key produces two valid signatures. Always namespace per-backend, check status before failover.

10. **Multi-threaded matching engine.** Single-threaded per pair, sharded across pairs. Multithreading within a pair breaks deterministic replay from the WAL.

11. **One Kafka cluster across chains or pair tiers.** Single broker = bottleneck and blast radius. Per-chain clusters, multi-tier fan-out, per-tenant quotas.

12. **No online/offline ML feature parity.** Two pipelines drift silently. One pipeline, two sinks.

13. **Hardcoded jurisdiction logic.** `if state == "NY"` in app code can't survive a new state launch. Jurisdiction is a data table.

14. **Treating KYC as a one-time event.** Re-KYC on jurisdiction change, periodic refresh, event-triggered re-screen. Sanctions lists update; your screen must too.

15. **No double-entry, no reconciliation.** A single source of truth (the ledger) with no continuous diff against chain/bank state is audit-hostile.

16. **Wrong-with-confidence under pushback.** When the interviewer challenges a choice, defending it stubbornly is a negative signal. *"Being wrong with confidence is a negative signal; humility is a positive signal"* -- Coinbase's own words. The right move: react with curiosity, iterate.

17. **Overstating scope in behavioral.** Inflated "I led X" when you were a contributor. Bar raisers cross-check; this is an explicit veto trigger.

---

## Coinbase-Specific Vocabulary

Name-drop once to signal you've done your homework, then describe the underlying pattern:

### Trading and Market Data
| Term | Underlying pattern |
|---|---|
| **Aeron Cluster** | Low-latency messaging with RAFT-replicated state machine |
| **Sequencer** | Linearization point assigning monotonic per-pair sequence numbers |
| **LMAX Disruptor** | Lock-free fixed-size ring buffer for producer-consumer fan-out |
| **Level2 / level3** | Order book aggregation (price-aggregated qty vs full per-order detail) |
| **Conflation** | Drop intermediate ticks for slow consumers, deliver only the latest |
| **Coinbase Explore** | The market discovery surface; canonical "live prices" question target |

### Custody
| Term | Underlying pattern |
|---|---|
| **cb-mpc** | Open-sourced MPC library (March 2025) for ECDSA + EdDSA threshold signing |
| **TSS** | Threshold Signing Service with Shamir-shared HSM-bound key shares |
| **CDS** | Cross-domain solution; air-gap technology |
| **HSM** | Hardware Security Module; non-exportable keys |
| **Vault** | Institutional custody product with quorum approvers + cooling-off |
| **Smart Wallet** | ERC-4337 account abstraction with passkeys + bundler/paymaster |

### Blockchain Infrastructure
| Term | Underlying pattern |
|---|---|
| **ChainStorage** | Open-source data availability layer; raw immutable block storage |
| **Chainsformer** | Streaming/batch transformation adapter |
| **ChaIndex** | Low-latency derived index layer |
| **Solana I/O** | Per-chain dedicated pipeline; canonical "abandon chain-agnostic at scale" example |
| **Snapchain** | Blue/green node deploys via EBS snapshots; 30-day server lifespan |
| **NodeSmith** | AI agent automation for node upgrades across 60+ chains |

### Data Platform / ML
| Term | Underlying pattern |
|---|---|
| **Spark RTM** | Spark Real-Time Mode for sub-250ms streaming features |
| **RocksDB state** | Local durable state backing streaming aggregations |
| **Lakebase** | Databricks Postgres-compatible serving layer for online predictions |
| **Tecton** | Feature store with online/offline parity |
| **Node2Vec** | Graph embedding on the blockchain address graph for risk scoring |

### Compliance
| Term | Underlying pattern |
|---|---|
| **Travel Rule** | FinCEN: transfers >$3K require originator/beneficiary info |
| **SAR** | Suspicious Activity Report; auto-filed for >$10K daily aggregate |
| **OFAC SDN** | Sanctions list; address screen on every outbound |
| **BitLicense** | NY DFS license required for virtual currency operations in NY |
| **MiCA** | EU regulation Coinbase complies with for European operations |
| **KYC tier** | Coinbase's tiered identity verification (Basic → Tier 1/2/3) |

### Internal / Cultural
| Term | What it means |
|---|---|
| **FinHub-Ledger** | The team interviewing on double-entry ledger design |
| **Bar Raiser** | Trained interviewer with veto power on every panel |
| **"Hell yes or no"** | The hiring decision rule -- "maybe" rounds to "no" |
| **Project 10 Percent** | 10% of eng resources on speculative high-leverage bets |
| **Tough Feedback** | Cultural tenet -- expect direct pushback, react with curiosity |
| **Mission First** | Cultural tenet -- ground designs in the economic-freedom mission |
| **#SecurityFirst** | Engineering principle -- security woven through, not bolted on |
| **#ExplicitTradeoffs** | Engineering principle -- name the rejected alternative for every choice |
| **#BuildValue** | Engineering principle -- use OSS for non-differentiating; build only the unique parts |
| **#APIDriven** | Engineering principle -- services through clean contracts |

---

## The 60-Second Mental Model

When you sit down for a Coinbase system design round, run every design decision through these filters:

1. **Is money flowing?** If yes: double-entry append-only ledger, idempotency end-to-end, integer smallest-units, fail-closed for money paths, audit immutability.

2. **Is a chain involved?** If yes: per-chain confirmation policy, reorg as expected event, multi-tier custody for asset storage, address risk screening for outbound, immutable raw block tier with derived indices.

3. **Is this customer-fund-touching?** If yes: defense in depth (multiple gates, cheap-first), velocity limits, allowlist with cooling-off, KYC tier check, OFAC screen, Travel Rule for >$3K, SAR streaming for >$10K daily.

4. **Is this latency-sensitive?** If yes: split the hot loop from the fan-out path. Two failure domains, two SLAs. In-memory + WAL for hot, conflated multi-tier broker for fan-out.

5. **Is this volatility-sensitive?** If yes: predictive autoscaling with 60-min lead time, circuit breakers for the long tail, per-tier capacity headroom, halt-paths for trading.

6. **Is this multi-step async?** If yes: workflow orchestration (Temporal), durable state machine with idempotent activities, saga compensation across services, observable workflow IDs.

7. **Is ML involved?** If yes: online/offline feature parity, single pipeline two sinks, score/decide/act separation, explainability per decision, shadow + A/B + ramp deployment.

8. **What's the worst-case adversary?** If you don't have an answer, redesign. Custody must survive insider threat, supply-chain compromise, $5 wrench coercion. Money paths must survive credential theft and idempotency-key reuse.

9. **What does the auditor see?** If you don't have an answer, redesign. Append-only journal, immutable audit log with hash-chained externalized roots, retention policy aligned to jurisdiction, explainability for every automated decision.

10. **How do you say it?** Lead with the rejected alternative for every choice. *"I picked X over Y because Z; the cost is W; mitigated by V."* Pair every architectural claim with a number (latency, throughput, cost, blast radius). When pushed back on, react with curiosity.

Frame everything in customer impact: *"during a Bitcoin pump, a customer placing a market order experiences sub-millisecond fills with halt-protected price discovery, while their balance update is applied via a double-entry journal entry that's reconciled against the chain within 30 seconds"* is better than *"the system handles 100K TPS (Transactions Per Second)."*

---

## Related Resources

**Exercises in this knowledge base:**
- [[01-trading-engine/PROMPT|Order Matching Engine]]
- [[02-wallet-custody/PROMPT|Wallet Custody Architecture]]
- [[03-financial-ledger/PROMPT|Financial Ledger Service]]
- [[04-blockchain-indexer/PROMPT|Multi-Chain Blockchain Indexer]]
- [[05-market-data-feed/PROMPT|Real-Time Market Data Feed]]
- [[06-fraud-risk-scoring/PROMPT|Fraud / Risk Scoring]]
- [[07-deposit-withdrawal/PROMPT|Deposit / Withdrawal Pipeline]]
- [[08-kyc-onboarding/PROMPT|KYC / Account Opening]]

**Cross-cutting reference:**
- [[coinbase-patterns|Cross-Cutting Patterns and Gotchas]]
- [[shopify-crash-course|Shopify Crash Course]] (the contrast case for "fail-open vs fail-closed")

**High-signal external watching/reading list (~10 hours):**
1. AWS re:Invent 2023 FSI309 -- Coinbase ultra-low-latency exchange architecture (~50 min)
2. SREcon23 Americas -- The making of an ultra low latency trading system with Go and Java (~30 min)
3. ByteByteGo -- Low Latency Stock Exchange Design Deep Dive (~30 min)
4. ByteByteGo -- Digital Wallet System Design (Vol.2 Ch12) (~30 min)
5. Frank Yu QCon SF 2025 -- How to Build an Exchange (~50 min) + Hello Interview "Design a Crypto Exchange" community thread
6. Coinbase blog: Optimizing Producer-Consumer Architecture for Market Data (Aug 2025)
7. Coinbase blog: Scaling Identity to 1.5M Reads/Second
8. Coinbase blog: A Dedicated Architecture for Solana
9. Coinbase blog: The Standard in Crypto Custody + Open Source MPC Library
10. Coinbase blog: Oct 2025 AWS Outage Retrospective (operational discipline narrative)
