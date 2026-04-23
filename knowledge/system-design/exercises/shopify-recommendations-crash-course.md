# Recommendations & Personalization: Infrastructure Crash Course

Focused on systems and infrastructure, not ML algorithms. For Staff-level interviews where the question is "how do you *serve* personalized recommendations for 100M users at low latency" — not "how does collaborative filtering work."

---

## The Problem at Scale

- ~100M daily active shoppers
- Each expecting personalized recommendations on multiple surfaces (homepage, PDP, cart, Shop app feed)
- **Billions of recommendation slots served per day**
- Each slot must be:
  - **Personalized** (user-specific)
  - **Fresh** (reflect recent behavior)
  - **Fast** (< 100ms serving latency)
  - **Consistent** (same query → same result, for debugging)

**The core infrastructure question:** do you compute everyone's recommendations ahead of time, or at request time? **Answer: hybrid.** Most heavy compute happens offline; serving is cheap lookup + lightweight adjustment.

---

## Three-Layer Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ LAYER 1 — TRAINING (offline, weekly/daily)                   │
│  Warehouse data → feature engineering → model training       │
│  → Model registry                                            │
└─────────────────────────────────────────────────────────────┘
                         ↓ (new model artifacts)
┌─────────────────────────────────────────────────────────────┐
│ LAYER 2 — PRECOMPUTATION (offline, nightly/hourly)           │
│  For each user: generate top-N candidates using latest model │
│  → Write to online KV store                                  │
└─────────────────────────────────────────────────────────────┘
                         ↓ (precomputed candidates)
┌─────────────────────────────────────────────────────────────┐
│ LAYER 3 — ONLINE SERVING (real-time, per request)            │
│  KV lookup → real-time features → re-rank → post-process     │
│  → Return top-20 in <100ms                                   │
└─────────────────────────────────────────────────────────────┘
```

---

## Layer 1: Training Pipeline

**Cadence:** weekly full retrain, daily incremental. Not on the hot path — nothing here affects live latency.

**Where compute happens:** GPU cluster. Shopify uses **SkyPilot** to schedule across multiple cloud providers (GCP, Nebius, etc.) for GPU capacity.

**Data sources:** the data warehouse (Snowflake or BigQuery). Months of historical events: orders, views, clicks, add-to-carts, across all merchants (with tenant-level separation where needed).

**Output:** a model artifact (weights + architecture) pushed to a **model registry** (MLFlow, S3 + metadata, or custom). Models are versioned and staged — validated offline before promoting to production precomputation.

**Infra components:**
- Orchestrator (Airflow, Kubeflow, Temporal)
- GPU compute fleet
- Model registry
- Experiment tracking (Weights & Biases, MLFlow)

**Key property:** training is decoupled from serving. A training failure doesn't affect live recommendations (last-known-good model keeps serving).

---

## Layer 2: Precomputation Pipeline

**This is how "for every customer" is solved.**

**Cadence:** nightly batch for all DAU (~100M). More frequent for the hottest users.

### Scale math

- 100M users × top-100 candidates each = **10B user-item pairs**
- Each pair: ~200 bytes (product ID + score + metadata)
- **Total storage: ~2 TB**
- Parallelize across a worker fleet:
  - 1000 workers × 100K users per worker = 100M total
  - With GPU batch inference (~100 users/sec per worker): ~20 minutes per worker
  - Batch completes in ~20 min of wall time

### How it works

```
Precomputation job (runs nightly)
  ↓ loads latest model from registry
  ↓ reads user list from warehouse (DAU from last 30 days)
  ↓ partitions users across N workers
  ↓ each worker:
    - loads model into GPU memory
    - batch-infers candidates for its partition
    - writes results to online KV store (Redis / DynamoDB)
  ↓ emits completion event → monitoring → A/B test framework
```

### Storage tiering (cost optimization)

- **Hot users (DAU):** fresh recommendations in **Redis** → sub-ms lookup
- **Warm users (weekly active):** **DynamoDB / Cassandra** → 5-10ms lookup, cheaper per GB
- **Cold users (monthly/rare):** compute on demand or use popularity fallback
- **Anonymous:** popularity lists only (no per-user precomputation)

### The "what about new users / new items / fresh behavior" problem

Precomputation is always stale (yesterday's data, today's serving). Solutions:
- **New users in today's batch:** on-demand compute during their first session
- **New items:** Layer 3 re-ranking injects them via real-time features
- **Fresh behavior (just viewed a product):** Layer 3 re-ranking adjusts ordering

So precomputation doesn't have to be perfect — Layer 3 absorbs the deltas.

---

## Layer 3: Online Serving (the request path)

```
GET /recommendations?user_id=42&surface=homepage
  ↓
1. KV lookup: get precomputed candidates for user_id=42
   → [p1, p2, ..., p100]                          ~5ms
  ↓
2. Online feature fetch (parallel batch):
   - user session features (recently viewed, cart contents)
   - item features (price, inventory, recency) for all 100 candidates
                                                  ~20ms
  ↓
3. Lightweight re-rank:
   - Small model (LightGBM, linear model, or shallow neural net)
   - Input: candidates + features
   - Output: top-50 ordered                       ~20ms
  ↓
4. Post-processing:
   - Filter OOS items (inventory cache)
   - Filter already-purchased
   - Diversity injection (no more than 3 of same category)
   - Apply merchant business rules (new arrivals boost, etc.)
   - Respect ad vs organic slots                  ~10ms
  ↓
5. Serialize + return top-20                      ~10ms
                                                 ────────
                                            Total: ~65ms
```

### Why it's fast

- **No full-model inference at serving time.** Heavy compute happened offline.
- **Re-ranking model is tiny** — runs on the 100-candidate set, not millions.
- **Parallel feature fetches** — feature store supports batch `mget` over many keys.
- **Aggressive caching of item features** — product metadata rarely changes; cache generously.

### Latency budget breakdown (typical targets)

| Stage | Budget |
|---|---|
| KV lookup | 5ms |
| Feature fetches (parallel) | 20ms |
| Re-rank inference | 20ms |
| Post-processing | 10ms |
| Serialization + net | 10ms |
| Headroom | 35ms |
| **Total** | **100ms** |

---

## Core Infrastructure Components

### Online KV Store (precomputed candidates)

Holds: `user_id → list of (product_id, score) candidates`.

Options:
- **Redis:** sub-ms lookups. 2 TB dataset sharded across Redis Cluster nodes. Good for DAU.
- **DynamoDB / Cassandra:** larger datasets, cheaper per GB, 5-10ms. Good for cold tier.
- **Custom serving stacks** (Shopify likely has bespoke infra for hot paths)

Schema (Redis hash or DynamoDB item):
```
user_id: 42
  generated_at: 2026-04-23T03:00:00Z
  model_version: "reco_v142"
  candidates: [
    {product_id: "p_123", score: 0.89, source: "hstu"},
    {product_id: "p_456", score: 0.81, source: "cf"},
    ...
  ]
```

### Online Feature Store

Real-time features fetched during serving.

Tools: **Feast** (open source), Redis, DynamoDB. Shopify has **Pano** (their Feast-based online store).

Features served:
- **User session:** recently viewed, cart items, device, location, session start time
- **Item real-time:** current price (merchants change prices), in-stock boolean, recency
- **Interaction:** has user viewed this before, last interaction timestamp

**Critical:** same feature definition in the offline store (warehouse, for training) and online store (for serving). "Training-serving skew" is the #1 production ML bug.

### Behavior Ingestion Pipeline

```
Client event (click, view, purchase)
  → Frontend SDK batches events every ~1s
  → Kafka topic: user_events (partitioned by user_id)
  → Multiple consumers:
    1. Warehouse loader — appends to training data (30-day lag OK)
    2. Online feature updater — updates session features in Redis (seconds of lag)
    3. Real-time analytics — merchant dashboards
    4. Anomaly detection — fraud / abuse monitoring
```

Same event stream feeds both training (for next batch) and serving (for current session re-ranking). Closed loop.

### Inventory Sync for Serving

Serving needs "is this product in stock *right now*" to filter OOS. Options:
- **Redis cache** with `in_stock:{sku_id}` boolean, updated via inventory service events
- **Batch included in item features** during serving-time feature fetch

Shopify pattern: inventory service emits events via Kafka → Redis cache updated → recommendation serving reads the cache at request time.

### Model Registry & A/B Testing

- **Registry** tracks every model version, its training data, offline metrics, deployment stage (staging/canary/prod)
- **A/B framework** assigns a % of users to new-model precomputation, monitors online metrics (CTR, conversion, revenue/session) before full rollout
- **Attribution:** every served recommendation logs its `model_version` so you can tie outcomes back to the model that generated them

---

## Specific Infrastructure Problems & Answers

### "How do we serve 100M personalized users?"

**Hybrid: batch precompute + online adjust.** Most compute is overnight. Serving is KV lookup + lightweight re-rank. No full-model inference in the request path.

### "What if a user's behavior changes mid-session?"

**Layer 3 re-ranking.** Real-time session features (just-viewed items, cart contents) flow into Redis within seconds via Kafka → online feature store. Re-ranker picks them up at next request.

### "What about new users who weren't in last night's batch?"

**Tiered fallback:**
1. Known cookie/fingerprint → use precomputed candidates from prior session
2. Returning user with light history → on-demand lightweight compute during session
3. Fully anonymous → popularity + context (location, device, referrer)

### "How do we keep up with inventory changes?"

**Don't rewrite precomputed lists.** Filter OOS at serving time using Redis inventory cache. Tomorrow's batch regenerates with fresh inventory state. Write amplification of in-place updates is not worth it.

### "How do we roll out a new model safely?"

**Independent of serving:**
1. Train and validate new model offline
2. A/B test: 1% of users get new-model candidates in their precompute
3. Monitor online metrics (CTR, conversion, revenue/session)
4. Gradually ramp to 100% if metrics improve; instant rollback if they regress
5. Keep the old model's precomputed candidates live during rollout for instant fallback

### "What's the failure mode if Layer 2 (precomputation) fails?"

**Serve yesterday's candidates.** Precomputation failures are not user-visible for 24h. Alert on SLA miss, fix the batch, run off-hours. This is why you don't want candidates to have a hard TTL — stale is better than empty.

### "What if the KV store is down?"

**Fall back to popularity lists.** Each surface has a cached "globally popular for this context" list (cached in Redis / CDN). If user-specific candidates are unavailable, serve popularity. Brief precision loss, but service stays up.

### "How big are the datasets actually?"

- Precomputed candidates: ~2 TB total (100M users × 100 items × 200 bytes)
- Online feature store: depends, but typically hundreds of GB
- Behavior event stream: ~10-100 GB/day sinking to warehouse

Per pod this is manageable. Globally, Redis Cluster + DynamoDB for tiering.

---

## Multi-Tenancy at Shopify (infrastructure view)

### Storefront recommendations (one merchant's store)

Two viable architectures:

**Option A — precompute per (user, merchant) pair:**
- Storage: 100M users × 5M merchants = infeasible. Ruled out.

**Option B — global candidates, filter at serving:**
- Precompute candidates across ALL products the user might buy
- At serving: filter candidate list to current merchant's `shop_id` only
- Apply per-merchant re-ranking rules (boost new arrivals, etc.) on top

Shopify uses Option B. Storage linear in user count, not user × merchant.

### Shop app recommendations (cross-merchant)

No merchant filter at serving. Global candidates, global ranking. Data isolation only applies in "don't leak which specific stores user visited" — anonymized at aggregate level.

---

## Summary: What You Need to Know for the Interview

| Component | What it does | Latency / Scale |
|---|---|---|
| **Training cluster** | Model retraining | Hours, offline |
| **Model registry** | Version models, stage rollouts | N/A, metadata |
| **Batch inference** | Generate per-user candidates | Hours, nightly |
| **Online KV store** | Serve precomputed candidates | <5ms, 2TB |
| **Online feature store** | Real-time features at serving | <10ms |
| **Event ingestion (Kafka)** | Capture user behavior | Seconds of lag |
| **Inventory cache (Redis)** | Filter OOS at serving | <1ms |
| **Serving API** | Stitch it all together | <100ms budget |
| **A/B testing framework** | Validate new models online | Separate path |

---

## One-Liner for the Interview

> "Personalized recommendations at 100M-user scale is a hybrid batch + online problem. Nightly batch precomputes per-user candidate lists using the latest model from a registry, writes them to a tiered KV store (Redis for DAU, DynamoDB for cold tier). The online serving layer does cheap KV lookup, fetches real-time session features from an online feature store, runs a lightweight re-ranking model on the candidate set, applies business rules (OOS filter, diversity, merchant boosts), and returns top-20 in under 100ms. The heavy compute is offline; serving is a lookup plus a small re-rank. Multi-tenancy is enforced at the serving layer via merchant_id filters on global candidates, not by precomputing per-(user, merchant) pairs."

---

## Follow-up Probes (with one-line answers)

- **"What's the precomputation cadence?"** Nightly for DAU; more frequent for hottest users. Aim to complete in a few-hour batch window.
- **"Serving latency target?"** <100ms total. KV lookup + feature fetch + re-rank + post-process.
- **"How do you handle cold users?"** On-demand compute for returning users with light history; popularity for fully anonymous.
- **"How do you handle inventory changes?"** Filter at serving via Redis inventory cache; don't rewrite precomputed lists in place.
- **"Failure modes?"** Precomputation failure → serve yesterday's candidates. KV store failure → fall back to popularity lists. Always gracefully degrade, never return empty.
- **"How do you roll out a new model?"** A/B test via precomputation: 1% → 10% → 100% based on online metrics; keep old model live for instant rollback.
- **"Scale numbers?"** 100M users × 100 candidates × 200 bytes = ~2TB KV store. Sharded Redis Cluster for hot tier, DynamoDB for cold.
- **"Multi-tenancy?"** Global candidates, merchant filter + re-rank at serving for storefront recs. No filter for Shop app (cross-merchant).
- **"Feature store design?"** Online (Redis/Feast) + offline (warehouse) split. Identical feature definitions both places. Training-serving skew is the #1 bug.
- **"Event ingestion?"** Kafka topic partitioned by user_id. Consumers: warehouse (training data), online feature updater (session features), analytics, monitoring.

---

## Companion Documents

- **[shopify-crash-course.md](shopify-crash-course.md)** — patterns, tech stack, vocabulary
- **[shopify-components-overview.md](shopify-components-overview.md)** — component-by-component walkthrough
- **[shopify-additional-problems.md](shopify-additional-problems.md)** — other post-core-8 interview problems
