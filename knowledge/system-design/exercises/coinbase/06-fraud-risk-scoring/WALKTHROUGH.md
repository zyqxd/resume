# Walkthrough: Design a Real-Time Fraud Detection / Transaction Risk Scoring System (Coinbase)

## Step 1: Clarify Requirements and Scope

Before drawing anything, pin down the shape of the problem with the interviewer:
- What action classes need scoring? (Deposit, withdrawal, trade, account action -- each with a different latency budget and consequence profile)
- What is the latency budget per class? (Withdrawal can tolerate 250ms; trade hot path closer to 100ms; account action depends on whether it is interactive)
- What does "decision" mean here? (Allow, hold for review, rate-limit, block, challenge with step-up auth -- the score itself is not the decision)
- What is the regulatory regime? (Bank Secrecy Act (BSA — primary US AML statute), OFAC (Office of Foreign Assets Control — US Treasury sanctions body) sanctions, FinCEN (Financial Crimes Enforcement Network) Travel Rule (FinCEN/FATF rule requiring originator/beneficiary info above ~$3000) >$3K, SAR (Suspicious Activity Report — required filing for suspected illicit activity) filing >$10K aggregate daily, MSB licensing per state)
- What is the false-positive cost vs false-negative cost? (False positive = customer abandons, support cost, churn. False negative = direct loss, compliance breach, regulatory fine, reputational damage)
- Are we training models, serving them, or both? (This design covers ingest, feature serving, scoring, decisioning, action -- training infrastructure is separate)

This scoping is critical because risk scoring is not one system, it is a pipeline of decoupled stages. Conflating any two of them in the design is a signal of inexperience. **Score is what the model says. Decision is what policy says. Action is what the platform does.** Keep them separate or the system cannot evolve.

**Primary design constraint:** Online / offline feature parity. If the features computed in batch for training disagree with the features computed in streaming for serving, the model silently degrades and no one knows until the labeled outcomes come back weeks later. Every architectural choice filters through this lens.

### Decision-Point Latency Budget

| Action class | End-to-end p99 (99th percentile latency) | Feature lookup | Model inference | Tolerable degradation |
|---|---|---|---|---|
| Deposit (fiat or crypto) | 250ms | 50ms | 50ms | Hold for 1-30s allowed |
| Withdrawal | 250ms | 50ms | 80ms | Hold or queue allowed |
| Trade (spot) | 100ms | 30ms | 30ms | Must not block hot trade loop |
| Account action (login, 2FA (Two-Factor Authentication)) | 150ms | 30ms | 50ms | Step-up challenge instead of block |
| Address book add | 500ms | 50ms | 200ms | Async warning acceptable |

The trade path is the tightest. We will see later why trade scoring uses a thinner feature set and a smaller model (or rules-only with a periodic ML-derived rule update).

---

## Step 2: High-Level Architecture

```
Action Sources (Trade Engine, Wallet, Auth, Onboarding, Address Book)
        |
        | action events
        v
+--------------------+
| Kafka Action Stream|  topic per action class
+----------+---------+
           |
   +-------+-------+-----------------+
   |               |                 |
   v               v                 v
+----------+   +----------+    +------------+
| Feature  |   | Scoring  |--->| Audit /    |
| Pipeline |   | Service  |    | Feedback   |
| (Spark   |   | (gRPC)   |    +-----+------+
|  RTM)    |   |          |          |
+----+-----+   +----+-----+          v
     |              |          +-----------+
     v              v          | Label     |
+----------+   +----------+    | Store     |
| DynamoDB |<--| Decision |    +-----+-----+
| Online   |   | Layer    |          |
| Feature  |   | (rules+  |          |
| Store    |   |  score)  |          v
+----+-----+   +----+-----+    +-----------+
     |              |          | Compliance|
     v              v          | SAR/OFAC/ |
+----------+   +----------+    | Travel    |
| Lakebase |   | Action   |--->| Rule /    |
| Postgres |   | Layer    |    | Chainalys |
+----------+   +----+-----+    +-----------+
                    |
                    v
              +-----------+
              | Manual    |
              | Review    |
              | Queue     |
              +-----------+
```

### Core Components

1. **Action Stream (Kafka)** -- every action emits an event keyed by `user_id`. Topics: `actions.deposit`, `actions.withdrawal`, `actions.trade`, `actions.account`. Per-user ordering preserved.
2. **Feature Pipeline (Spark Real-Time Mode (Spark RTM — Databricks' sub-second streaming mode, hits 150-250ms latency at Coinbase))** -- one logical pipeline, two sinks. Stateless transforms run at 150ms latency; stateful streaming aggregations run at 250ms latency with RocksDB (embedded key-value store, used as streaming state backend for Spark RTM)-backed state.
3. **Online Feature Store (DynamoDB)** -- hot lookups for user-level, device-level, address-level features. Sub-50ms reads.
4. **Lakebase (Databricks' Postgres-compatible online prediction serving layer) Postgres** -- Databricks Lakebase, used as the online serving cache for prediction artifacts and slowly-changing features that benefit from richer queries.
5. **Scoring Service** -- synchronous gRPC (Google's high-performance RPC framework) service that the calling action layer invokes. Reads features, calls models, returns score plus explanation.
6. **Decision Layer** -- combines model score with rule-based policy (sanctioned countries, velocity caps, hard blocks). Versioned policy bundle.
7. **Action Layer** -- enforces the decision (hold deposit, block withdrawal, rate-limit trade, queue for review, force step-up auth).
8. **Manual Review Queue + Case Manager** -- humans investigate ambiguous cases; outcomes feed labels.
9. **Compliance Module** -- generates SARs, runs OFAC screening, integrates Chainalysis / Elliptic (blockchain analytics vendors), files Travel Rule disclosures.
10. **Audit / Feedback** -- every decision logged immutably with feature snapshot, model version, policy version, and explanation. Labels stream back from disputes, chargebacks, manual reviewer outcomes, and downstream investigations.

---

## Step 3: Data Model

The schema separates events (immutable facts), features (derived state), scores (model outputs), decisions (policy outputs), cases (review state), and labels (ground truth).

### Action Events

```sql
-- Immutable. Single row per action attempted by any user.
action_events (
  event_id        UUID PRIMARY KEY,
  user_id         BIGINT NOT NULL,
  action_class    VARCHAR(32) NOT NULL,    -- 'deposit', 'withdrawal', 'trade', 'account'
  action_type     VARCHAR(64) NOT NULL,    -- 'deposit.crypto', 'withdrawal.fiat.ach', etc.
  amount_usd      NUMERIC(20, 8),          -- nullable for non-financial actions
  currency        VARCHAR(16),
  counterparty    VARCHAR(128),            -- destination address or wire account
  device_id       VARCHAR(128),
  ip_address      INET,
  geo             JSONB,
  payload         JSONB NOT NULL,          -- action-specific fields
  occurred_at     TIMESTAMP NOT NULL,
  ingested_at     TIMESTAMP NOT NULL
);
```

### Features

Features live in two stores. Online (DynamoDB) is keyed for sub-50ms lookups. Offline (Delta Lake on S3) is the training ground truth and lineage record.

```
DynamoDB online store -- table per feature group, single PK each.

feature_user    PK: user_id
                attrs: count_withdrawals_7d, sum_withdrawals_usd_7d,
                       distinct_destinations_30d, days_since_signup,
                       kyc_tier (KYC — Know Your Customer), velocity_zscore_24h, last_updated

feature_device  PK: device_id
                attrs: distinct_users_30d, first_seen, device_risk_score

feature_address PK: chain:address
                attrs: node2vec_embedding (Node2Vec — graph-embedding algorithm; binary, 64-dim float16),
                       chainalysis_category, chain_risk_score, sanctions_flag
```

### Scores

```sql
scores (
  score_id        UUID PRIMARY KEY,
  event_id        UUID NOT NULL,
  model_id        VARCHAR(128) NOT NULL,    -- 'wd_v23.1', 'login_v8.4'
  model_version   VARCHAR(32) NOT NULL,
  score           NUMERIC(8, 6) NOT NULL,   -- 0.0 to 1.0
  feature_hash    VARCHAR(64) NOT NULL,     -- hash of features used; for replay
  explanation     JSONB,                    -- top-K SHAP (SHapley Additive exPlanations — feature-attribution method for ML explainability) attributions
  scored_at       TIMESTAMP NOT NULL
);
```

### Decisions and Actions

```sql
decisions (
  decision_id     UUID PRIMARY KEY,
  event_id        UUID NOT NULL,
  score_id        UUID NOT NULL,
  policy_version  VARCHAR(32) NOT NULL,
  outcome         VARCHAR(32) NOT NULL,     -- 'allow', 'hold', 'block', 'review', 'challenge'
  reason_codes    TEXT[] NOT NULL,          -- ['velocity_24h', 'address_risk_high']
  decided_at      TIMESTAMP NOT NULL
);

actions (
  action_id       UUID PRIMARY KEY,
  decision_id     UUID NOT NULL,
  enforcement     VARCHAR(64) NOT NULL,     -- 'deposit_held', 'wd_blocked', 'login_challenged'
  metadata        JSONB,
  enforced_at     TIMESTAMP NOT NULL
);
```

### Cases and Labels

```sql
-- Manual review queue.
cases (
  case_id         UUID PRIMARY KEY,
  user_id         BIGINT NOT NULL,
  triggering_event UUID NOT NULL,
  priority        INT NOT NULL,
  status          VARCHAR(32) NOT NULL,     -- 'open', 'in_review', 'resolved'
  assignee_id     VARCHAR(128),
  resolution      VARCHAR(64),              -- 'true_positive', 'false_positive', 'inconclusive'
  notes           TEXT,
  opened_at       TIMESTAMP NOT NULL,
  resolved_at     TIMESTAMP
);

-- Ground truth labels for training.
labels (
  label_id        UUID PRIMARY KEY,
  event_id        UUID NOT NULL,
  user_id         BIGINT NOT NULL,
  label_type      VARCHAR(64) NOT NULL,     -- 'chargeback', 'ato_confirmed', 'sar_filed'
  label_value     BOOLEAN NOT NULL,
  source          VARCHAR(64) NOT NULL,     -- 'manual_review', 'chargeback_processor', 'sar_outcome'
  labeled_at      TIMESTAMP NOT NULL
);
```

### Key Design Decisions in the Schema

**Separating `scores`, `decisions`, and `actions` into distinct tables:** Each represents a different concern with its own version (model version, policy version, enforcement version). Joining them gives a full lineage for every audit query without coupling the model artifact to the policy logic.

**`feature_hash` on every score:** Lets us replay a historical decision with the exact features that were used. Required for regulator audit ("show me why you blocked this withdrawal in March").

**Reason codes as a string array:** Decision rationale is human-readable and machine-queryable. Enables "show me all decisions blocked for `velocity_24h` last week" without parsing JSON.

**Labels separate from cases:** A label can come from a chargeback processor, a manual reviewer, or downstream investigation. The label table is the union; the case table is one source.

---

## Step 4: Feature Pipeline

The feature pipeline is the heart of the system. Every feature must be computable identically in batch (training) and streaming (serving). One pipeline, two sinks.

### Stateless vs Stateful Features

| Feature type | Example | Latency target | State store | Materialization |
|---|---|---|---|---|
| Stateless (event-local) | `is_high_risk_country` from IP | 150ms | None | Inline transform |
| Stateless (lookup) | `kyc_tier` from user table | 150ms | DynamoDB | Pre-loaded |
| Stateful aggregation | `count_withdrawals_7d` | 250ms | RocksDB state | Streaming aggregation |
| Stateful sequence | `last_10_actions_embedding` | 250ms | RocksDB state | Sequence buffer |
| Heavy graph feature | `address_node2vec_embedding` | Async | Lakebase + DynamoDB | Batch refresh |

### Spark Real-Time Mode

Coinbase migrated their feature pipeline to Spark Real-Time Mode (RTM) -- the streaming execution model where micro-batches drop into millisecond-scale processing. End-to-end p99 dropped from 800+ms to under 100ms post-migration (Databricks case study).

```
Kafka (action_events) -> Spark RTM Job -> DynamoDB (online)
                              |        \-> Delta Lake (offline / training)
                              |
                       parse + validate
                       join user / device / address risk
                       stateful aggregations
                       sequence buffer
```

Same code path, two sinks. Training reads Delta Lake; serving reads DynamoDB. Because the transformation is one job, features in both stores agree by construction.

### State Store: RocksDB, Not Redis

Stateful aggregations need a state store:

- **Redis:** in-memory, fast, but state is bounded by RAM. Per-user aggregations across 100M+ users with 30-day windows blow past a single Redis cluster's RAM budget.
- **RocksDB-backed Spark state:** disk-spillable, durable to checkpoint, replays cleanly after restart. Coinbase uses this.

RocksDB is a couple of ms slower than Redis for hot reads, but the state lives next to the stream job rather than over the network, so the latency is absorbed into the streaming step. The materialized features land in DynamoDB, which is the fast path at decision time.

### Feature Definitions in Code

Tecton (feature platform with online/offline parity guarantees; Coinbase's chosen feature platform) defines a feature once and materializes it to both stores:

```python
@batch_feature_view(
    sources=[action_events],
    entities=[user],
    online=True,
    offline=True,
    aggregation_interval=timedelta(minutes=1),
    aggregations=[
        Aggregation(column="amount_usd", function="sum",   time_window=timedelta(days=7)),
        Aggregation(column="event_id",   function="count", time_window=timedelta(days=7)),
    ],
)
def withdrawal_velocity_7d(events):
    return events.filter(events.action_class == "withdrawal")
```

The same feature definition runs in batch for backfill (Spark on Delta Lake) and in streaming for online materialization (Spark RTM to DynamoDB). The training-serving skew problem is solved at the source: there is only one source.

### Cold Reads and New Users

A user signing up has no aggregation history. The pipeline emits zero or sentinel features. The model must be trained with explicit handling of missing values -- not by imputing zeros silently, but by carrying a `feature_present` flag alongside the value so the model can route differently for cold-start users.

---

## Step 5: Online Feature Store

The online store is read on every scoring call. The latency budget is sub-50ms p99. The data shape is mostly "given an entity ID, give me its feature vector."

### DynamoDB Design

DynamoDB fits this access pattern: single-digit ms reads, predictable throughput, Global Tables for multi-region, item TTL (Time To Live) for stale entities.

- `feature_user`: PK = `user_id`
- `feature_device`: PK = `device_id`
- `feature_address`: PK = `chain:address` (embedding + risk attrs)

Each scoring call does at most three GetItems in parallel via BatchGetItem -- a single round trip well under 50ms.

### Why Not Redis for the Online Store?

Redis is faster on average, but loses on the dimensions that matter at this scale:
- **Durability:** Redis state loss = silent scoring degradation until rewarm. DynamoDB is durable.
- **Operational ceiling:** hundreds of millions of users, dozens of features each. DynamoDB scales horizontally without operator intervention; Redis Cluster requires careful resharding.
- **Multi-region:** Global Tables are native; Redis cross-region is custom plumbing.

Redis still appears as a write-through cache in front of DynamoDB for the hottest 1% of entities -- mostly a cost optimization, not a latency one.

### Lakebase Postgres for Slow-Changing Features

Some features are query-heavy and update-light: KYC tier, account vintage, tax jurisdiction, individual-vs-business, pricing tier. These live in Lakebase Postgres (Databricks' managed Postgres for serving). Scoring reads them through a connection pool with per-request caching. Stale by a few seconds doesn't move the score.

### Feature Freshness vs Cost

| Feature freshness | Update cadence | Cost profile |
|---|---|---|
| Real-time (streaming) | Sub-second | Highest -- Spark RTM, DynamoDB writes |
| Near-real-time | 1-5 minutes | Moderate -- micro-batch Spark |
| Hourly | 1 hour | Low -- batch job, DynamoDB writes |
| Daily | 1 day | Lowest -- batch job, Lakebase writes |

The model uses real-time features for velocity signals and daily features for slow signals like account vintage. Training data mixes the same tiers.

---

## Step 6: Sequence Features for ML

Coinbase's behavior models (LSTM (Long Short-Term Memory — recurrent neural network variant for sequence modeling) and Transformer (neural network architecture using self-attention; foundation of GPT, BERT)) take a sequence of recent actions per user, not just point-in-time aggregations. The intuition: a user who just logged in from a new country, then changed their email, then initiated a large withdrawal looks different from any single-event signature.

### Sequence Pipeline

```
Kafka (action_events) -> Spark stream (conform schema, no aggregation)
                              -> DynamoDB sequence_user
                                  PK: user_id, SK: timestamp, TTL: 30d
```

Stateless conform-and-write -- no aggregation. At scoring time, the service queries `sequence_user where user_id = :u order by sk desc limit 100`. The 100 most recent actions become the input sequence to the LSTM / Transformer.

### Sequence Length Tradeoffs

| Length | Coverage | Latency | Model size | Use case |
|---|---|---|---|---|
| 10 events | Recent burst | 5ms | Small | Trade hot path |
| 100 events | Session + recent days | 20ms | Medium | Withdrawal scoring |
| 1000 events | Long-term pattern | 100ms | Large | Manual review enrichment |

Trade hot path: 10-event sequence, small model. Withdrawal: 100 events, larger model. Manual review (offline): full 1000-event horizon.

### Cold-Start Handling

A user with fewer than N events has no useful sequence embedding. Two approaches:
1. **Pad with sentinel events.** Model sees a padding token and learns to discount.
2. **Fall back to point-feature model.** Scoring service has a cold-user variant using only DynamoDB point features; the decision layer knows the model class used and tightens rules accordingly.

Critical at signup: a new user's first withdrawal has zero sequence. System uses tighter rule-based caps (small first-withdrawal limit, mandatory hold) until enough sequence accumulates.

---

## Step 7: Address Risk Scoring

Outbound transactions to crypto addresses need a destination risk score. This is a separate ML system from transaction-level scoring, but it feeds the transaction model as an input feature.

### Node2Vec on the Blockchain Address Graph

Coinbase publishes Node2Vec embeddings over the entire blockchain address graph. Each address gets a 64-dimensional vector capturing its position in the transaction graph. Addresses near known mixers, ransomware wallets, or exchange hot wallets cluster together in embedding space.

```
Chain raw data -> graph builder -> Node2Vec training -> risk classifier -> DynamoDB
                  (nodes=addrs    (random walks +       (embedding ->     feature_address
                   edges=txns)     skip-gram, 64-d)      [0,1] using
                                                         Chainalysis
                                                         labels)
```

### Refresh Cadence

- **Hot addresses (active 7d):** re-embedded daily.
- **Warm (active 90d):** re-embedded weekly.
- **Cold:** monthly.
- **Brand new (first seen):** seeded with neighbors' average embedding plus a freshness flag; full embedding next daily cycle. Until then, fall back to attribute-based scoring (chain, format, sanctions list match).

### Combining With Transaction-Level Scoring

The address risk score is one input to the transaction model alongside user, device, sequence, and amount features. A high address score doesn't automatically block; the model learns the joint distribution. A user with a long history of sending to the same exchange address shouldn't trigger on a moderately elevated address risk.

For very high address risk (>0.95, sanctioned, or matching a known stolen-funds cluster), policy short-circuits the model with a hard block before inference. That's rule territory, not model territory.

### Chainalysis and Elliptic Integration

Coinbase pays for blockchain analytics. Chainalysis and Elliptic provide address category labels (exchange, mixer, ransomware, sanctioned), cluster-to-entity mapping, and real-time risk feeds for outgoing transactions. Queried at decision time for high-value transactions, cached in DynamoDB. The Node2Vec embedding is the in-house supplement -- internal embeddings catch patterns the vendors haven't categorized yet.

---

## Step 8: Scoring Service

The scoring service is a synchronous gRPC endpoint. The action layer calls it, waits, and acts on the response.

### Request Flow

```
Action layer: ScoreRequest{event, user_id, action_class, ...}
    |
    v
Scoring service:
  1. Look up user features  | parallel
     Look up device features| parallel
     Look up address features (if applicable) | parallel
  2. Look up sequence (last N events)
  3. Select model (action_class -> model_id)
  4. Run inference
  5. Compute SHAP explanation if score > threshold
  6. Return ScoreResponse{score, explanation, model_version, feature_hash}
```

### Multi-Model Ensemble

A single global model is the most common mistake in this system. Different action classes have wildly different feature distributions:

| Model | Features | Architecture | Latency |
|---|---|---|---|
| `withdrawal_v23` | full sequence + address risk | Transformer | 80ms |
| `deposit_v15` | sequence + counterparty + chain analytics | LSTM | 50ms |
| `trade_v8` | recent velocity + position + market regime | gradient-boosted trees | 30ms |
| `login_v12` | device + geo + sequence | gradient-boosted trees | 40ms |
| `account_v6` | sequence + change-pattern | LSTM | 60ms |

Each model is trained, versioned, and deployed independently. The scoring service routes by `action_class`.

### Shadow Models and A/B (randomized controlled experiment comparing two versions)

A new model never replaces the old one directly. The pattern:
1. **Shadow:** new model runs in parallel for 100% of traffic; its score is logged but not used for decisions.
2. **A/B:** small percentage of traffic uses the new model; metrics compared with controls.
3. **Ramp:** traffic share increases as the new model proves out.
4. **Cutover:** old model remains in shadow for a quarter for regression detection.

Both models output through the same scoring service, just keyed by experiment assignment. The audit log records which model produced which decision.

### Latency Budget

Within the 100-250ms end-to-end budget, the scoring service has roughly:
- Feature lookup: 30-50ms (parallel DynamoDB GetItems)
- Sequence query: 10-20ms (DynamoDB Query)
- Inference: 30-80ms (depending on model)
- SHAP / explanation: 10-30ms (only for high-impact decisions)
- Network / serialization: 10-20ms

Total: 90-200ms inside the scoring service. Action layer adds another 30-50ms for the surrounding work.

The trade hot path skips SHAP -- explanation runs only when score crosses a decision threshold and the action layer requests it.

---

## Step 9: Decision Layer

The model gives a score. The decision layer turns score into action.

### Rules + Model

The decision is not `if score > 0.8 then block`. It is a layered policy:

```
def decide(event, score, user_features):
    # Hard rules (cannot be overridden by model)
    if event.counterparty in OFAC_SANCTIONS:
        return Decision("block", reasons=["ofac_sanctioned"])
    if user_features.kyc_tier == 0 and event.amount_usd > 1000:
        return Decision("block", reasons=["kyc_required"])

    # Model-driven thresholds (per action class)
    thresholds = policy.thresholds_for(event.action_class)
    if score > thresholds.block:
        return Decision("block",  reasons=score.top_reasons())
    if score > thresholds.review:
        return Decision("review", reasons=score.top_reasons())
    if score > thresholds.hold:
        return Decision("hold",   reasons=score.top_reasons())

    # Soft rules (velocity caps, etc.)
    if user_features.sum_withdrawals_24h > policy.daily_cap(user):
        return Decision("hold", reasons=["velocity_cap_exceeded"])

    return Decision("allow")
```

### Policy Versioning

The policy bundle (thresholds, rules, OFAC list snapshot) is versioned and deployed through a release process separate from model deployment. Every decision logs the policy version it used.

This separation matters because:
- Compliance officers update policy faster than ML engineers update models.
- Regulator inquiries ask "what was your policy on this date?" -- answerable from policy version history.
- A bad model push can be mitigated by tightening thresholds via policy rather than rolling back the model.

### Manual Review Queue

`review` and high-confidence `hold` decisions create cases. Case manager assigns priority, routes to reviewers, tracks resolution. Reviewer outcomes feed labels back into training. Queue prioritization weights high-value transactions, age (SLA (Service Level Agreement) on review time), and routes high-uncertainty cases to senior reviewers.

---

## Step 10: Action / Enforcement

The action layer is plumbing. It enforces the decision idempotently across the systems that own the resources.

### Action Patterns by Class

| Decision | Deposit | Withdrawal | Trade | Account |
|---|---|---|---|---|
| Allow | Pass through | Pass through | Pass through | Pass through |
| Hold | Funds held; user notified | Withdrawal queued; user notified | (rare) | N/A |
| Block | Reject with reason code | Reject; case opened | Cancel order | Force step-up auth |
| Review | Hold + open case | Hold + open case | Allow but flag | Allow + monitor |
| Challenge | N/A | N/A | N/A | 2FA / email / phone |

### Idempotency

Every action carries a `decision_id`. Enforcement is keyed by `decision_id` (`INSERT ... ON CONFLICT (decision_id) DO NOTHING`) so retries don't double-act. Required because calling services (wallet, trade engine) retry the score+decide cycle on transient failures.

### Cross-System Coordination

Holding a deposit coordinates with the wallet service; blocking a withdrawal coordinates with funds-out. Each call is idempotent with the action layer as orchestrator. Downstream failures retry with backoff and the original decision_id.

---

## Step 11: Compliance and Audit

Every block, hold, and review has a regulator audience. The system is built to answer audit questions years after the fact.

### Travel Rule (FinCEN)

Cryptocurrency transactions over $3,000 must include originator and beneficiary information transmitted between VASPs (Virtual Asset Service Providers). The action layer enriches outbound withdrawals with travel-rule metadata when the threshold is crossed:

```
withdrawal > $3000 to external VASP
    -> enrich with originator info (name, address, ID)
    -> request beneficiary info from receiving VASP
    -> if no Travel Rule compliance from receiver, hold and review
```

### SAR Generation (Suspicious Activity Reports)

A SAR must be filed for transactions or patterns that indicate suspected illicit activity. Aggregate threshold: $10K daily for cash-equivalent transactions.

The compliance module subscribes to the action stream and the case stream. When a pattern triggers a SAR-eligible signal (confirmed manual review as true positive, threshold crossed, structured deposits detected), it:
1. Generates a draft SAR with all relevant context (events, decisions, customer info).
2. Routes to the BSA officer for review.
3. On approval, files via FinCEN's BSA E-Filing.
4. Records filing reference back to the case.

### OFAC Screening

Every counterparty (deposit source, withdrawal destination, P2P recipient) is screened against OFAC SDN list. The list updates daily. A daily batch job re-screens active users' address books against the latest list and triggers alerts for new matches.

For real-time scoring, OFAC matches are a hard rule in the decision layer (block immediately, do not call the model). The model is for fuzzy signals, not for sanctions which require deterministic matching.

### Audit Log Immutability

The audit table is append-only:
- Postgres with no DELETE / UPDATE permission for application roles
- Hourly snapshots to S3 with versioning and object lock (WORM mode)
- Cryptographic chain: each row hashes the previous (Merkle-style)

For 7-year retention (BSA / FinCEN), data tiers from hot (Lakebase) to warm (S3 standard) to cold (Glacier). Audit queries hit Lakebase; archival queries restore from Glacier on demand.

### Explainability

Every blocking decision must be explainable to:
- The customer (in plain language: "Your withdrawal was held because of unusual activity. You can verify your identity to release it.")
- The compliance officer (in feature-level detail: "Score 0.87, top contributors: velocity_24h (+0.34), new_destination_address (+0.22), unusual_hour (+0.11)")
- The regulator (with feature snapshot, model version, policy version, full lineage)

SHAP values are computed at decision time for high-impact actions and stored in the decisions table. Customer-facing explanations are templated from reason codes; regulator explanations are the full SHAP attribution.

---

## Step 12: Online / Offline Parity

This is the section that separates a senior answer from a staff answer. Training-serving skew is the silent killer of ML systems.

### The Problem

Train on features computed in batch from historical data. Serve from features computed in streaming. The two computations are written by different teams in different languages with different definitions of "the last 7 days." A 5% drift looks like nothing -- until labeled outcomes come back and the model performance is ten points off the offline metric.

### The Solution

**One feature definition. Two sinks.**

This is what Tecton (and Coinbase's adoption of Spark RTM) gives us. The feature is defined once:

```python
@feature_view(
    online=True,
    offline=True,
    aggregations=[Aggregation("amount_usd", "sum", timedelta(days=7))]
)
def withdrawal_velocity_7d(events): ...
```

The runtime materializes both sinks from the same code. Coinbase reports that this lifted their online/offline parity from low-90s to 98%.

### Drift Detection

Even with one pipeline, drift creeps in:
- Schema changes upstream
- Late-arriving events
- Feature pipeline lag
- Model input distribution shift over time

A monitoring job samples scoring requests, recomputes the features from the offline pipeline, and compares. Any feature where the parity drops below 95% triggers an alert. Parity below 80% on a critical feature is a page.

### The Replay Path

When a model needs retraining, the training set is built from the offline feature store. The features used for any historical decision are exactly recoverable via the `feature_hash` on the score row. This means:
- Backtesting a new model on historical decisions produces a faithful comparison.
- Investigating a regulator complaint reproduces the exact features that drove the decision.

---

## Step 13: Adversarial Robustness

Risk scoring is not a passive system. Attackers actively probe.

### Common Adversarial Patterns

- **Threshold probing:** sending small transactions of varying amounts to learn where the system blocks.
- **Velocity oracle:** rapid-fire actions to learn the velocity windows.
- **Feature flooding:** generating fake activity from a compromised account to skew aggregations before the real attack.
- **Timing attacks:** measuring response latency to infer which path was taken (model called vs cache hit).

### Mitigations

- **Rate-limit feature lookups by attacker:** suspicious users get their feature lookups rate-limited at the feature store layer. Stops oracle-style probing.
- **Don't leak score thresholds:** the customer-facing message says "we held this for review" not "your score was 0.83 and the threshold is 0.80."
- **Response polymorphism:** add a small randomized delay to scoring responses so timing differences between cache hit and model call cannot be inferred.
- **Action explanations are public; scores are not:** customers see "address risk high" not "model output 0.87."
- **Model pessimism on novel patterns:** when the model encounters feature distributions far from training, it should output high uncertainty, and the decision layer should escalate to review rather than allow.

### Feedback Loop Poisoning

An attacker who can influence labels can degrade the model. Defenses:
- Multiple label sources (manual review, chargeback, downstream investigation) with weighted aggregation.
- Reviewer-level quality scoring; suspicious labels from compromised reviewer accounts get discounted.
- Time-decay on labels: a label from 2 years ago has less weight than a label from last week.
- Anomaly detection on the label stream itself: a sudden spike in "false positive" labels triggers a hold on training pipeline updates.

---

## Step 14: Failure Modes

### Failure: Model Service Down

Scoring service cannot reach the model server. **Default to rule-based fallback. Never down all transactions.** Fallback uses only point features and hard rules -- more conservative (more holds, fewer blocks), but the platform stays operating. Decision layer logs the fallback flag so analysts can investigate any spike in fallback usage.

### Failure: Feature Store Stale

Streaming pipeline lagging; served features are minutes behind reality. Detection via heartbeat lag metric. Mitigation: apply stale penalty in the decision layer (tighten thresholds) for known stale windows; fall back to rules-only with conservative caps for severe staleness; page on-call.

### Failure: Label Feedback Loop Poisoned

Detected via anomaly detection on the label stream. Response: freeze training, investigate label sources for the affected window, roll back model if a tainted run made it to prod, restore from last-known-good label snapshot.

### Failure: Action Backlog (Manual Review Queue Saturated)

Surge in `review` decisions saturates the queue. Mitigations: auto-promote SLA-breached cases to `hold` for the max allowed period; scoring service knows queue depth and biases away from `review` toward `allow`/`block` when saturated; surge staffing playbook including outsourced reviewers for low-stakes cases.

### Failure: False-Positive Surge

A model push causes a 10x spike in blocks. Detection: FPR by action class, auto-alert at 2x baseline. Response: auto-rollback if FPR doubles within 1 hour of a deploy; tighten policy bundle if surge is policy-driven; customer support escalation channel for affected users to bypass with manual verification.

---

## Step 15: Tradeoffs Summary

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Stream engine | Spark RTM | Flink | Coinbase's existing Spark / Databricks investment; RTM closes the latency gap to Flink for this use case |
| State store for streaming | RocksDB-backed | Redis | Disk-spillable for huge per-user state; durable across restarts; co-located with stream job |
| Online feature store | DynamoDB | Redis | Durability, multi-region replication, no operational ceiling at our scale |
| Model architecture | Multi-model ensemble | Single global model | Different action classes have different distributions; one model = compromise on every class |
| Decision logic | Rules + model | Pure model | Hard regulatory rules (OFAC) cannot be probabilistic; rules are auditable in ways models are not |
| Scoring failure mode | Fail open with rules | Fail closed | False negative on a few transactions is recoverable; downing the platform during an outage is not |
| Sequence feature length | 100 events (default) | 10 or 1000 | Balance latency, model size, signal coverage |
| Address graph model | Node2Vec | GNN (Graph Neural Network) | Node2Vec is mature, fast, embeddings cache well; GNN is a future evolution |
| Audit storage | Lakebase + S3 WORM | Postgres only | 7-year retention requires tiered storage; WORM satisfies regulator immutability |
| Online/offline parity | Single feature pipeline (Tecton) | Separate pipelines per environment | Drift between training and serving is the dominant ML failure mode |
| Manual review queue | Yes, with case management | Auto-decide everything | Some decisions need humans; cases produce labels |

---

## Common Mistakes to Avoid

1. **No online/offline parity.** Defining features in two places (offline notebook for training, streaming code for serving) almost guarantees drift. The model performs differently in production than in offline metrics, and root cause is invisible. Solution: one feature pipeline, two sinks.

2. **Single global model for all action classes.** A trade is not a withdrawal. A login is not a deposit. Modeling them with one architecture forces compromises that hurt every class. Solution: model per action class, routed by the scoring service.

3. **Scoring tied to action.** If the scoring service decides the action, you cannot change policy without redeploying the model. Solution: score, decide, act as three separate stages.

4. **No explainability.** "We blocked because the model said 0.87" is unacceptable to customers, support agents, and regulators. Solution: SHAP at decision time for high-impact actions; reason codes on every decision; full feature snapshot in the audit log.

5. **No human-in-the-loop.** Pure auto-decide systems cannot handle ambiguous cases, and they have no mechanism to produce new labels. Solution: manual review queue with case management; reviewer outcomes flow back as labels.

6. **Fail-closed on model outage.** When the model service goes down, blocking all transactions is worse than the underlying risk. Solution: rule-based fallback; the platform stays operating with conservative caps until the model is back.

7. **Storing scores without feature hashes.** Months later, when a regulator asks why a decision was made, you cannot reproduce the features. Solution: hash the feature vector and store the hash on the score row; offline store retains the features for replay.

8. **Real-time everything.** Refreshing every feature in streaming is operationally expensive and unnecessary. Solution: tiered freshness (real-time, near-real-time, hourly, daily) matched to the feature's actual update rate.

9. **Trusting label sources blindly.** A single label source can be poisoned (compromised reviewer, broken upstream signal). Solution: multiple label sources with weighted aggregation; anomaly detection on the label stream.

10. **No idempotency on the action layer.** Retries from upstream cause double-blocks, double-holds, double-cases. Solution: enforcement keyed by decision_id; ON CONFLICT DO NOTHING.

11. **Treating address risk as a binary.** "Is this address sanctioned?" is binary; "what is the address's risk profile?" is continuous. Solution: continuous score from Node2Vec embedding feeds the model; sanctioned matches are a separate hard rule.

12. **Not separating policy version from model version.** Compliance updates the policy bundle on its own cadence (sometimes weekly). If the policy is hardcoded in the model service, every policy change requires an ML release. Solution: versioned policy bundle, hot-reloaded by the decision layer.

---

## Follow-up Questions

**How would you add chain analytics for a new chain (e.g., Solana)?**
Chain-specific work: graph builder consuming Solana RPC, Node2Vec retraining on the new graph, address schema extended with `chain` discriminator. Reuse the rest of the pipeline. Cold-start period uses Chainalysis Solana coverage as the primary signal; in-house embedding takes over after data accumulates. Don't release scoring until parity tests pass on the chain-specific features.

**How do you handle a new fraud pattern with no labels?**
Three-stage rollout. (1) Rules-based detection: a human notices the pattern (usually via support escalation), writes a rule. Decision layer holds/blocks immediately. (2) Label generation: every rule trigger creates a case; reviewers confirm or refute; labels accumulate. (3) Model integration: at 1000+ labels, retrain with the pattern as a feature or new model variant. Rule carries the load until then.

**How would you scale to 10x transactions?**
Spark RTM scales horizontally by user_id partition. DynamoDB on-demand absorbs natively. Scoring service is stateless; scale out and pin hot model replicas per region. Extend Redis caching layer for top-1% hot keys. Predictive autoscaling (per the Coinbase blog) gives 60-minute lead time off market signals -- prep capacity ahead, don't react. Manual review: surge staffing plus auto-resolution of low-stakes queued cases.

**Can the action layer evolve to a generic policy engine?**
Yes, and this is the natural evolution. Today the action layer is hardcoded per action class. Tomorrow policy is expressed in a DSL (Open Policy Agent or Cedar) where rules, thresholds, and enforcement actions are declarative. Compliance updates policy without an engineering deploy. Benefits: faster policy changes, cleaner audit (policy diff is a regulator artifact), better testability. Risk: DSL grows too expressive and acquires its own bugs -- mitigated with review process and staged rollout.

**How do you know when to retire a model version?**
Monitoring on three signals. (1) Live performance: FPR, FNR, customer complaint rate per model version, watched against offline metrics. (2) Policy override rate: if rules consistently override the model's output, it's not earning its keep. (3) Feature drift: input distribution shift away from training. Retirement is staged: shadow, ramp-down, deprecation.

**What changes for institutional clients vs retail?**
Institutional has different distributions: huge transactions, sophisticated counterparties, OTC desks, regulatory tags. Train separate models on the institutional segment. Different policy bundle (higher caps, different review SLAs, dedicated reviewer pool). Same architecture, different model + policy versions. Don't let institutional patterns leak into the retail training set or vice versa.

---

## Related Topics

- [[../../../07-real-time-systems/index|Real-Time Systems]] -- Spark RTM, RocksDB state stores, streaming aggregations
- [[../../../02-scaling-reads/index|Scaling Reads]] -- DynamoDB design patterns, online feature store latency budgets
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- model service degradation, fail-open vs fail-closed
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- training-serving skew, single-pipeline-two-sinks pattern
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- DynamoDB vs Redis tradeoffs, Lakebase serving layer, immutable audit log
- [[../../../05-async-processing/index|Async Processing]] -- label feedback loops, batch graph embedding refresh, manual review queue management
