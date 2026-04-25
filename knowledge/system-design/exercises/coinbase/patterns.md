# Coinbase System Design: Cross-Cutting Patterns and Gotchas

These patterns and gotchas are distilled from the 8 Coinbase system design exercises (12-19). They represent the recurring architectural decisions and failure modes that Coinbase staff interviewers care about. Weave these into any Coinbase system design answer -- they signal that you understand how regulated, custody-grade, 24/7 financial systems actually work.

The mental model is different from Shopify's. Shopify optimizes for surviving BFCM (Black Friday / Cyber Monday — Shopify's peak-traffic design target). **Coinbase optimizes for the worst-case adversary, the worst-case auditor, and the worst-case customer-fund outcome.** Every pattern below is downstream of that.

---

## Recurring Architecture Patterns

### 1. Two-Path Architecture: Latency-Sensitive Hot Loop vs. Throughput Fan-Out

**Appears in:** Trading Engine, Market Data Feed, Deposit/Withdrawal

The signature Coinbase trading pattern. Split the system into two completely separate failure domains:

- **Hot loop:** sub-millisecond, single-threaded, in-memory, deterministic, WAL (Write-Ahead Log — append-only durability log)-backed. Examples: matching engine, signing service.
- **Fan-out path:** throughput-optimized, lossy at the edge, conflated, multi-tier. Examples: WebSocket market data, settlement event distribution.

**Why it matters:** Mixing them poisons the hot loop. A slow WebSocket consumer must never apply backpressure to the matching engine. State this split *up front* -- it is the highest-leverage move in any trading or market-data round.

**Interview signal:** "We split the trading hot loop from the market data fan-out path. Different SLAs (Service Level Agreements), different replication models, different failure domains. The matching engine writes to a WAL and emits to a ring-buffer-fronted bus; the WebSocket fleet conflates and drops slow consumers without ever touching the engine."

### 2. Double-Entry, Append-Only Ledger

**Appears in:** Financial Ledger, Trading Engine (settlement), Deposit/Withdrawal, Wallet Custody

Every value transfer is two equal-and-opposite journal entries. Balances are *derived* from the journal, never mutable fields. Corrections are reversing entries, not updates.

**Why it matters:** Reconciliation, audit, replay, and tax all depend on an immutable journal. Every Coinbase research source says this is the highest-signal staff-level move when money is in scope. The FinHub-Ledger (Coinbase's ledger team) interviews on exactly this.

**Interview signal:** Open any money-touching design with "The first principle here is double-entry, append-only. We don't store balances; we store journal entries. Balances are a materialized view." If the interviewer doesn't push back, you've established staff-level credibility in one sentence.

### 3. End-to-End Idempotency Keys

**Appears in:** All 8 exercises

Idempotency keys propagate from client → API → ledger → external systems (signing, broadcasting, payment provider, KYC (Know Your Customer) vendor). Each layer dedupes by key. The key is deterministic when possible -- derived from `(user_id, intent_id)` for client requests, `(chain, txid)` for chain events, `(event_id, subscription_id)` for fan-out.

**Key nuance:** Idempotency keys are scoped to a single backend. The same withdrawal key sent to two different signers can produce two different signatures; namespace per-backend and check status before failover. This is the same trap as Shopify's Stripe-vs-Adyen idempotency-during-failover gotcha, applied to crypto rails.

### 4. State Machines for High-Stakes Operations

**Appears in:** Deposit/Withdrawal, Wallet Custody, KYC Onboarding, Trading Engine (orders)

Every multi-step operation that touches money or compliance is a durable state machine. Each transition is an idempotent journal entry. Recovery from partial state is by *walking the state machine*, never by ad-hoc rollback.

Examples:
- Deposit: `DETECTED → PENDING_CONFIRMATIONS → CONFIRMED → CREDITED → SETTLED` plus `REORGED` branches.
- Withdrawal: `REQUESTED → DEBITED → RISK_PASSED → POLICY_PASSED → UNSIGNED → SIGNED → BROADCAST → CONFIRMED → SETTLED`.
- KYC: `STARTED → SUBMITTED → DOC_VERIFIED → SANCTIONS_CHECKED → SCORED → DECIDED` with manual-review and resume branches.

**Why it matters:** If you can't draw the state machine, you can't reason about partial-failure recovery. Coinbase interviewers explicitly probe "what happens if the process dies between step N and N+1?"

### 5. Per-Chain Confirmation Policy and Reorg Awareness

**Appears in:** Blockchain Indexer, Deposit/Withdrawal, Wallet Custody

Each chain has a different finality model: BTC=3-6 confirmations (amount-tiered), ETH=12, Solana fast-finality (~12.8s), Polygon=256 blocks. The indexer treats reorg as an *expected* state transition, not an exception. Credits made before finality are reversible journal entries.

**Why it matters:** Treating broadcast as "done" or treating reorg as an exception is one of the top three reject patterns in the Coinbase research corpus. Every research source flags this.

**Interview signal:** Cite a specific number. "We don't credit BTC deposits until 3 confirmations for amounts under $X, 6 for amounts above." Then walk through what happens on a deep reorg.

### 6. Multi-Tier Custody (Hot / Warm / Cold + MPC / HSM / Multi-sig)

**Appears in:** Wallet Custody, Deposit/Withdrawal, Trading Engine (balance holds)

The signature Coinbase security pattern. ~2-5% in HSM (Hardware Security Module — tamper-resistant device that holds keys and signs without exposing them)-backed hot wallet (operational liquidity), 5-20% in MPC (Multi-Party Computation — multiple parties jointly compute over secret inputs without revealing them)/TSS (Threshold Signing Scheme — k-of-n parties produce one signature) warm tier (institutional withdrawals), 75-98% in air-gapped cold storage with multi-sig and CDS (Cross-Domain Solution — military-grade air-gap technology).

Funds move *down* the tiers continuously (deposits hit warm, sweep to cold). Funds move *up* only via slow, multi-sig, human-reviewed ceremonies. No automated cold-to-hot path exists.

**Why it matters:** Custody is the differentiator. Coinbase is the qualified custodian for 9 of 11 spot BTC ETFs (Exchange-Traded Funds). Your design must show you understand that hot wallet exposure is bounded by insurance limits, that MPC keys are never reconstructed, and that HSM-backed keys cannot be exported.

### 7. Online / Offline Feature Parity (the ML training-serving skew problem)

**Appears in:** Fraud Risk Scoring, Market Data (price aggregation)

ML features are computed in *both* a streaming pipeline (for serving) and a batch pipeline (for training). They must produce identical values. Coinbase's published target: >98% online/offline parity, achieved via Spark RTM (Spark Real-Time Mode — Databricks' sub-second streaming mode) + RocksDB (embedded key-value store) streaming state + Databricks Lakebase (Databricks' Postgres-compatible online prediction serving layer) Postgres for serving, with Tecton (feature platform with online/offline parity)-style feature store for offline materialization.

**Why it matters:** Drift between training and serving is silent model degradation. Staff candidates are expected to lead with "single feature pipeline, two sinks" rather than two separate pipelines that drift.

### 8. Workflow Orchestration (Temporal) for Durable Multi-Step Async

**Appears in:** KYC Onboarding, Deposit/Withdrawal, Wallet Custody (signing ceremonies)

Coinbase publicly uses Temporal (workflow orchestration platform) for long-running, multi-step async workflows. Why: durable state across retries and process crashes, replay-safe activity execution, observable workflow IDs that survive client disconnect.

**Pattern:** Workflow == business process; activities == idempotent side effects; saga compensation for cross-service rollback. Workflow IDs are stable and propagated to the client (so save/resume across sessions just works).

**Interview signal:** When designing any multi-step async pipeline, propose a workflow orchestrator (Temporal/Cadence (workflow orchestration platform)/Step Functions) rather than ad-hoc service calls + a database state column. Justify: durable retries, observability, replay.

### 9. Reconciliation as a First-Class Subsystem

**Appears in:** Financial Ledger, Deposit/Withdrawal, Wallet Custody, Fraud Risk Scoring

Two sources of truth must continuously agree:
- **Internal ledger ↔ blockchain state** (for crypto)
- **Internal ledger ↔ bank statements** (for fiat)
- **Online feature store ↔ offline batch** (for ML)
- **Hot wallet ↔ chain wallet** (for operational ops)

Reconciliation is not a one-time job. It runs continuously, flags drift above thresholds, and *never auto-corrects financial drift*. Auto-remediation is acceptable for cache/state drift, never for the journal.

**Why it matters:** This is what separates a system that "works" from one that's audit-ready. The reconciler exists because every distributed system drifts; the question is how fast you detect and how loudly you escalate.

### 10. Fail-Closed for Money, Fail-Open for UX

**Appears in:** All 8 exercises

The opposite default of Shopify. When infrastructure degrades, money paths *halt* (consistency > availability), while non-money paths fail-open with degraded UX.

| Component down | Money path response | UX path response |
|---|---|---|
| Risk scoring service | Halt withdrawals | Fall back to rule-based score |
| HSM unavailable | No new signatures | Show last-known balance |
| Block scanner | Pause new deposits | Show pending UI |
| OFAC (Office of Foreign Assets Control — US Treasury sanctions body) API | Block transfers | Allow read-only browse |
| Ledger primary failover | Pause writes (~5s) | Continue serving cached reads |

**Why it matters:** Shopify says "fail-open beats blocking checkout." Coinbase says "fail-closed beats letting funds escape." If you propose Shopify-style fail-open on a withdrawal path, you fail. Customer complaints recover; lost funds and regulatory action don't.

### 11. Predictive Autoscaling for Volatility (60-min ML Lead Time)

**Appears in:** Trading Engine, Market Data Feed, Identity Service, Blockchain Indexer

Coinbase's published autoscaler classifies upcoming traffic spikes from upstream features (price moves, social signals, scheduled events) and pre-warms infrastructure 60 minutes ahead. Reactive scaling is too late -- by the time the metric crosses threshold, the spike has already started.

**Why it matters:** 10x volume spikes during BTC pumps are routine, not exceptional. Static capacity wastes money; reactive scaling causes outages. Predictive is the staff-level answer.

**Interview signal:** When asked "how does this handle a BTC pump," don't just say "auto-scale" -- say "predictive autoscaling with 60-min lead time, plus per-tier capacity headroom, plus circuit breakers for the unforecasted long tail."

### 12. Score / Decide / Act Layer Separation

**Appears in:** Fraud Risk Scoring, KYC Onboarding, Deposit/Withdrawal (policy gates)

Three layers, one direction:
- **Score:** ML model output (a number).
- **Decide:** versioned policy bundle (rules + thresholds) producing an action class.
- **Act:** plumbing that executes (block, hold, queue for review, allow, challenge with 2FA (Two-Factor Authentication)).

Each is independently observable, versioned, replayable. Adding a new fraud signal adds a feature; tuning a threshold ships a policy bundle; adding a new enforcement type ships an action.

**Why it matters:** Conflating these makes the system unmaintainable -- you can't roll back a threshold without re-deploying the model, or shadow-test a new model without affecting users.

### 13. Defense in Depth on Money Movements

**Appears in:** Wallet Custody, Deposit/Withdrawal, Fraud Risk Scoring

Withdrawals pass through *multiple independent gates* in cheap-first order:
1. Authentication / 2FA
2. Velocity limits (per-asset, per-day)
3. Withdrawal address allowlist (48-hour wait on new addresses)
4. OFAC sanctions screening
5. Travel Rule (FinCEN/FATF rule requiring originator/beneficiary info above ~$3000) data (>$3K)
6. Address risk score (Node2Vec (graph-embedding algorithm) graph embedding on chain)
7. ML fraud score on the action
8. Policy gate (jurisdiction, tier eligibility)
9. Hot tier capacity check
10. Sign + broadcast + N-confirmation

Each gate is independent; compromising one (e.g., a stolen 2FA) doesn't bypass the others. Cheapest gates first to fail fast.

**Why it matters:** Single-layer security fails the threat model. Coinbase's $320M crime insurance is contingent on this defense-in-depth posture.

### 14. Compliance as Architecture (Not Sidecar)

**Appears in:** All 8 exercises

KYC tiering, OFAC screening, Travel Rule, SAR (Suspicious Activity Report) generation, audit trail immutability, data retention, jurisdiction policy -- these are first-class services with versioned policies, drawn into the *first* architecture diagram. Not added at the end.

| Compliance concern | Architectural primitive |
|---|---|
| Audit immutability | Append-only journal + hash-chained audit log |
| KYC tier gating | Tier engine queried on every fund-touching action |
| Travel Rule (>$3K) | Withdrawal pipeline gate, originator/beneficiary metadata |
| SAR (>$10K daily) | Streaming aggregation, auto-generated case for filing |
| OFAC sanctions | Address screen on every outbound, periodic re-screen |
| Jurisdiction policy | Policy table joined on user.jurisdiction at decision time |
| Data retention (5-7yr) | Tiered storage with cold-archive lifecycle |
| Explainability | Feature snapshot + model version stored per decision |

**Why it matters:** "Bolt-on compliance" is one of the explicit reject patterns in the Coinbase research corpus. Showing it in the first diagram is what staff candidates do.

### 15. Per-Chain Pipelines Beat Chain-Agnostic at Scale

**Appears in:** Blockchain Indexer, Deposit/Withdrawal

Coinbase's Solana I/O (Coinbase's per-chain dedicated Solana ingestion pipeline) blog (2025) is the canonical lesson: a chain-agnostic ingestion pipeline buckles when one chain (Solana) has 10x the throughput of others. The fix is per-chain dedicated pipelines (Geyser (Solana's push-based stream interface) push + RPC backfill, dedicated Kafka cluster, one transaction per Kafka message). Result: 12x throughput, 20% deposit-latency reduction.

**Why it matters:** "Generalize too early" is a common staff anti-pattern. The Coinbase answer is: abstract over chains at the *event schema* layer, but specialize the pipeline per chain.

---

## Top Gotchas Across All Exercises

These are the mistakes that recur most frequently across the 8 exercises. If you avoid these, you are already ahead of most candidates.

### 1. Treating broadcast as "done"

**Exercises:** Deposit/Withdrawal, Wallet Custody

A withdrawal isn't done at broadcast -- it's done at N confirmations. Mempool replacement (RBF (Replace-By-Fee — Bitcoin protocol for bumping stuck-transaction fees)), gas escalation, stuck txns, and chain reorgs all happen between broadcast and finality. Your state machine must include `BROADCAST → CONFIRMED → SETTLED` as distinct states, with reorg-handling that reverses credits made before finality.

### 2. No reorg handling

**Exercises:** Blockchain Indexer, Deposit/Withdrawal, Wallet Custody

Treating chain reorgs as exceptional is a top reject pattern. Every chain reorgs, just at different depths. Your indexer state machine has `REORGED` as a normal transition. Deep reorgs (above your confirmation threshold) should *page on-call*, not silently corrupt state.

### 3. Mixing the trading hot loop with market data fan-out

**Exercises:** Trading Engine, Market Data Feed

The slowest WebSocket consumer must never apply backpressure to the matching engine. If you draw one bus that handles both, you've failed the round. Two paths, two failure domains, two replication models.

### 4. Mutable balance fields

**Exercises:** Financial Ledger, Trading Engine, Deposit/Withdrawal

`UPDATE accounts SET balance = balance - 100` is a reject signal in any Coinbase money round. Balances are derived from the journal. Period. The first thing you draw is `INSERT INTO journal_entries (account_id, debit, credit, ...)`.

### 5. Floats for money

**Exercises:** Financial Ledger, all money paths

IEEE 754 rounding bugs eat your reconciliation. Use integer smallest-units (satoshis for BTC, wei for ETH, cents for USD) plus an explicit currency code. Never assume currency.

### 6. Generic SaaS framing on a Coinbase question

**Exercises:** All

If your design for "design Coinbase Explore (Coinbase's market discovery surface)" looks identical to "design Twitter," you've failed. The differentiators are: 24/7 ops, 10x volatility spikes, double-entry ledger if money flows, custody tiers if assets flow, KYC/AML (Anti-Money Laundering) gates everywhere, audit immutability, regulatory jurisdiction.

### 7. Bolt-on security and compliance

**Exercises:** All

Adding KMS, KYC tier check, audit log, OFAC screen at the *end* of your design is a top reject pattern. They go in the first diagram, on the hot path, with clear ownership. Coinbase's #SecurityFirst engineering principle is graded explicitly.

### 8. One global circuit breaker / fail-closed for money paths

**Exercises:** Trading Engine, Deposit/Withdrawal, Wallet Custody, Fraud Risk Scoring

Two related mistakes:
- A single global "Stripe is down" circuit breaker takes out healthy regions. Always scope (provider, region) or (chain, network).
- For money paths, fail-closed is the correct default (Shopify's fail-open instinct is wrong here). But fail-closed must be granular: "halt new withdrawals" not "shut down the API."

### 9. Same idempotency key across signing backends or chain RPCs during failover

**Exercises:** Wallet Custody, Deposit/Withdrawal

Failing over from one HSM to another with the same idempotency key can produce two signatures of the same nonce -- a chain double-spend. Always namespace per-backend and check status before failover.

### 10. Treating the matching engine as multi-threaded for parallelism

**Exercises:** Trading Engine

The matching engine is single-threaded *per pair*. Parallelism comes from sharding pairs across instances, not from multithreading within a pair. Multi-threaded matching introduces nondeterminism that breaks deterministic replay from the WAL.

### 11. Single Kafka cluster / single broker for cross-chain or cross-tenant fan-out

**Exercises:** Blockchain Indexer, Market Data Feed, Trading Engine

A single broker becomes the bottleneck and blast radius. Per-chain Kafka clusters, multi-tier fan-out (core → regional → edge), and per-tenant resource quotas isolate failure.

### 12. No online/offline feature parity for ML

**Exercises:** Fraud Risk Scoring

Two pipelines (one for training, one for serving) drift silently. The model that scored 95% in offline eval scores 60% in production because features are subtly different. One pipeline, two sinks (online store + feature warehouse) is the staff answer.

### 13. Hardcoded jurisdiction logic

**Exercises:** KYC Onboarding, Wallet Custody, Deposit/Withdrawal, Fraud Risk Scoring

`if user.country == "US" and user.state == "NY"` baked into application code can't survive a new state launch. Jurisdiction is a data table joined at decision time, with versioned policy.

### 14. Re-deriving views instead of indexing

**Exercises:** Blockchain Indexer

Every consumer running its own block ingestion is wasteful and inconsistent. Centralize raw block storage (ChainStorage (Coinbase's open-source data-availability layer for raw blocks) pattern), let consumers subscribe to derived streams or build their own indexes from the immutable raw layer.

### 15. Treating KYC as a one-time event

**Exercises:** KYC Onboarding, Fraud Risk Scoring

KYC is continuous: re-screen on jurisdiction change, periodic re-KYC every 2-3 years, event-triggered re-KYC on high-volume activity, OFAC re-screening as sanctions lists update. Static KYC fails real-world compliance.

---

## Coinbase-Specific Vocabulary to Use in Interviews

Using Coinbase's own terminology and citing their published architecture shows you've done your homework. Name-drop once to signal recognition, then describe the underlying pattern.

### Trading and Market Data
| Term | Meaning |
|---|---|
| **Aeron Cluster** | Open-source low-latency messaging library Coinbase uses with RAFT for replication of compute (not data) in the matching engine |
| **Sequencer** | The component that assigns monotonic per-pair sequence numbers; the linearization point of the trading engine |
| **LMAX Disruptor / ring buffer** | Lock-free fixed-size ring buffer pattern; replaced Go channels in market-data fan-out for 38x latency improvement (Aug 2025 blog) |
| **Level2 / level3** | Order book aggregation depths -- L2 is per-price aggregated quantity, L3 is full per-order detail |
| **Conflation** | Dropping intermediate ticks to deliver only the latest to slow consumers |
| **Coinbase Explore** | Coinbase's market-discovery surface; the canonical "design real-time crypto prices" question target |

### Custody and Signing
| Term | Meaning |
|---|---|
| **cb-mpc** | Coinbase's open-sourced MPC cryptography library (March 2025); two-party and multi-party signing for ECDSA + EdDSA |
| **TSS** | Threshold Signing Service; Shamir-shared keys with HSM-bound shares, partial signatures combined off-HSM |
| **CDS** | Cross-domain solution; air-gap technology used to bridge cold storage to signing systems |
| **HSM** | Hardware Security Module; keys generated on-device and never exportable |
| **Vault** | Coinbase's institutional custody product with quorum approvers and 48-hour cooling-off |
| **Smart Wallet** | Coinbase's ERC-4337 account-abstraction wallet with passkeys (secp256r1) and bundler/paymaster |
| **Address risk score** | Node2Vec graph-embedding-based risk score (0-1) on blockchain destination addresses |

### Blockchain Infrastructure
| Term | Meaning |
|---|---|
| **ChainStorage** | Coinbase's open-source data availability layer; serves up to 1500 blocks/sec |
| **Chainsformer** | Streaming + batch transformation adapter on top of ChainStorage |
| **ChaIndex** | Low-latency index layer over ChainStorage |
| **Solana I/O** | Per-chain dedicated pipeline for Solana (12x throughput, 20% deposit latency cut) -- the canonical example of "abandon chain-agnostic at scale" |
| **Snapchain** | Blue/green blockchain node deploys via EBS snapshots; 30-day max server lifespan |
| **NodeSmith** | AI-driven (LLM agent) automation for node upgrades across 60+ chains |
| **Geyser** | Solana's push-based stream interface used for low-latency ingestion |

### Data Platform and ML
| Term | Meaning |
|---|---|
| **Spark RTM** | Spark Real-Time Mode; Coinbase migrated fraud features to it (stateless 150ms, stateful aggregations 250ms) |
| **RocksDB state** | Local state store backing streaming aggregations |
| **Lakebase** | Databricks' Postgres-compatible serving layer Coinbase uses for online predictions |
| **Tecton** | Feature platform for offline materialization with online-feature parity guarantees |
| **Node2Vec** | Graph-embedding algorithm Coinbase uses on the blockchain address graph for risk scoring |

### Compliance and Regulation
| Term | Meaning |
|---|---|
| **Travel Rule** | FinCEN rule: transfers >$3K require originator/beneficiary info |
| **SAR** | Suspicious Activity Report; auto-filed for >$10K daily aggregate or pattern matches |
| **OFAC SDN** | Office of Foreign Assets Control Specially Designated Nationals list; sanctions screening |
| **BitLicense** | NY DFS license required to operate as a virtual currency business in NY |
| **KYC tier** | Coinbase's tiered identity verification (Basic → Tier 1/2/3); each unlocks more features |
| **MiCA** | Markets in Crypto-Assets; EU regulation Coinbase complies with for European operations |

### Internal / Cultural
| Term | Meaning |
|---|---|
| **FinHub-Ledger** | Coinbase's ledger team -- the team interviewing on double-entry ledger design |
| **Bar Raiser** | Coinbase's hiring construct: every panel includes a trained bar raiser with veto power |
| **"Hell yes or no"** | Coinbase's hiring decision rule -- a "maybe" rounds to "no" |
| **Project 10 Percent** | 10% of eng resources on speculative bets (70/20/10 work split) |
| **Tough Feedback** | One of the 10 cultural tenets -- expect direct pushback in design rounds, react with curiosity |
| **Coinbase Prime** | The institutional brokerage platform (custody + financing + execution as separable systems) |
| **Coinbase International** | Bermuda-regulated derivatives exchange; 24/7, $15B+ traded, 100K msgs/sec target |
| **Base** | Coinbase's L2 (Ethereum-aligned); recently moved to base/base unified architecture |
| **x402** | Coinbase's HTTP 402 micropayment protocol for AI agents; multi-chain via facilitator |

---

## How Coinbase Patterns Differ from Shopify Patterns

A useful comparison if you've already prepped Shopify:

| Dimension | Shopify | Coinbase |
|---|---|---|
| Peak event | BFCM (Black Friday / Cyber Monday) | BTC pump / ETF approval / volatility spike |
| Top priority | Merchant revenue (checkout) | Customer fund safety (custody) |
| Failure default | Fail-open (let traffic through) | Fail-closed for money, fail-open for browse |
| Tenant model | Pod-based (cellular shards) | Account-based with shared infra; pods exist but tenant != customer |
| Money pattern | Order-then-charge | Reservation-then-settle, double-entry |
| Latency target | Sub-200ms checkout p99 | Sub-millisecond matching, sub-250ms risk |
| Compliance | PCI for cards | PCI + SOC2 (Service Organization Controls Type 2 audit framework) + KYC/AML + sanctions + Travel Rule + state-by-state |
| Ledger | Order-level state | Double-entry append-only journal everywhere |
| Hot data | Inventory in Redis | Order book in-memory + WAL; balances in ACID (Atomicity, Consistency, Isolation, Durability) DB |
| Edge | Sorting Hat (OpenResty/Lua) routing | Multi-region anycast + L7 (OSI Layer 7, the application layer) with rate limit + WAF (Web Application Firewall) |
| Signature pattern | Cellular pod isolation | Multi-tier custody + double-entry ledger |
| ML usage | Fraud, search relevance | Fraud (Spark RTM), address risk (Node2Vec), traffic prediction (60-min lead) |

The core mental shift: **Shopify protects the revenue path. Coinbase protects against the worst-case adversary, the worst-case auditor, and the worst-case fund-loss event.** Different optimization target, different first-diagram pattern.

---

## Related Exercises

- [[01-trading-engine/PROMPT|Exercise 12: Order Matching Engine]]
- [[02-wallet-custody/PROMPT|Exercise 13: Wallet Custody Architecture]]
- [[03-financial-ledger/PROMPT|Exercise 14: Financial Ledger Service]]
- [[04-blockchain-indexer/PROMPT|Exercise 15: Multi-Chain Blockchain Indexer]]
- [[05-market-data-feed/PROMPT|Exercise 16: Real-Time Market Data Feed]]
- [[06-fraud-risk-scoring/PROMPT|Exercise 17: Fraud / Risk Scoring]]
- [[07-deposit-withdrawal/PROMPT|Exercise 18: Deposit / Withdrawal Pipeline]]
- [[08-kyc-onboarding/PROMPT|Exercise 19: KYC / Account Opening]]
