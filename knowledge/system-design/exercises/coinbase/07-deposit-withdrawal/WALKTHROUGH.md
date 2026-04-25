# Walkthrough: Design the Deposit and Withdrawal Pipeline (Coinbase)

## Step 1: Clarify Requirements and Scope

Before drawing anything, confirm the scope with the interviewer:
- Which chains in scope? (BTC, ETH, Solana, Polygon as the core; long tail of EVM chains as a "pluggable" path -- not the focus)
- Retail flow only, or institutional / Prime as well? (Retail is the primary path; institutional has higher limits, manual review for large withdrawals, and a separate signing flow -- mention as differences)
- What latency targets per phase? (Deposit detection sub-30s, crediting at the per-chain confirmation count, withdrawal broadcast under 60s)
- Is this the ledger or the pipeline that calls the ledger? (The pipeline; the ledger is a downstream service we write journal entries to)
- Is custody / signing in scope? (No -- treated as a service with its own SLA (Service Level Agreement))
- What does "settled" mean? (User-visible balance is final; tax-eligible; cannot be reversed)

This scoping matters because it separates two orthogonal hard problems: blockchain ingestion (deposits) and on-chain execution (withdrawals). They share the same operational surface (idempotency, reorgs, reconciliation) but have opposite shapes -- deposits are reactive and wait for confirmations; withdrawals are proactive and must drive transactions to confirmation. The whole architecture bends around the asymmetry.

**Primary design constraint:** No double-credit, no double-spend, no lost transaction. A deposit must credit the user exactly once (even on reorg or retry). A withdrawal must broadcast exactly one signed transaction (even on signer retry, mempool replacement, or service crash). Every architectural choice filters through this lens.

---

## Step 2: High-Level Architecture

```
                       DEPOSIT PATH
+---------+      +-----------+      +-----------+      +----------+
| Chain   | ---> | Block     | ---> | Indexer / | ---> | Deposit  |
| Node /  |      | Scanner   |      | Address   |      | Detector |
| RPC     |      | (per ch.) |      | Resolver  |      | (FSM)    |
+---------+      +-----+-----+      +-----+-----+      +----+-----+
                       |                   |                |
                       v                   v                v
                 +-----+-----+       +-----+-----+    +-----+------+
                 | Reorg     |       | Address   |    | Confirma-  |
                 | Tracker   |       | Registry  |    | tion Watch |
                 +-----------+       +-----------+    +-----+------+
                                                            |
                                                            v
                                                   +--------+--------+
                                                   |  Ledger Writer  |
                                                   |  (journal +     |
                                                   |  outbox)        |
                                                   +--------+--------+
                                                            |
                                                            v
                                                       Kafka events
                                              (notifications, fraud, tax)


                       WITHDRAWAL PATH
+--------+    +-----------+    +---------+    +---------+    +----------+
| User   | -> | Withdraw  | -> | Policy  | -> | Risk /  | -> | Tx       |
| (API)  |    | Orchestr. |    | Gates   |    | Fraud   |    | Builder  |
+--------+    +-----+-----+    +---------+    +---------+    +-----+----+
                    |                                              |
                    | (debit ledger -- hold)                       v
                    v                                       +------+------+
              +-----+------+                                | Signer      |
              | Ledger     |                                | (HSM / MPC) |
              +------------+                                +------+------+
                                                                   |
                                                                   v
                                                            +------+------+
                                                            | Broadcaster |
                                                            | + Mempool   |
                                                            | Watcher     |
                                                            +------+------+
                                                                   |
                                                                   v
                                                          +--------+--------+
                                                          | Confirmation    |
                                                          | Watch + Settle  |
                                                          +-----------------+
```

### Core Components

1. **Block Scanner** -- one process per chain. Tails new blocks via the chain node's RPC (e.g., `eth_getBlockByNumber`, BTC ZMQ + REST). Emits `BlockIngested` events to Kafka.
2. **Indexer / Address Resolver** -- consumes blocks, decodes transactions, and matches outputs/recipients against the address registry (Coinbase-owned addresses).
3. **Deposit Detector** -- the deposit-side state machine. Owns the `deposit_request` row and walks it through detected -> pending_confirmations -> confirmed -> credited -> settled.
4. **Confirmation Watcher** -- per-chain process that compares current head height to deposit block height; advances state when N confirmations reached.
5. **Reorg Tracker** -- watches for block hash changes at heights where we have pending or recently-credited deposits; emits reorg events that the deposit FSM consumes.
6. **Withdrawal Orchestrator** -- the withdrawal-side state machine. Owns `withdrawal_request`, drives it through every stage.
7. **Policy Gates** -- separate stateless service that evaluates limits, allowlist, 2FA (Two-Factor Authentication), OFAC (Office of Foreign Assets Control -- US Treasury sanctions body), Travel Rule (FinCEN/FATF rule requiring originator/beneficiary info above ~$3000). Returns pass/fail/hold.
8. **Tx Builder** -- chain-specific module that constructs unsigned transactions (UTXO (Unspent Transaction Output -- Bitcoin's accounting model) selection for BTC, nonce assignment for ETH, etc.).
9. **Signer (HSM (Hardware Security Module -- tamper-resistant device that holds keys and signs without exposing them) / MPC (Multi-Party Computation -- multiple parties jointly compute over secret inputs without revealing them) / Multi-sig)** -- external service. Idempotent: same `signing_request_id` returns the same signature.
10. **Broadcaster + Mempool (a node's pool of unconfirmed transactions waiting to be mined) Watcher** -- pushes signed transactions to chain RPC; monitors mempool acceptance; handles RBF (Replace-By-Fee -- Bitcoin protocol that lets a sender bump a stuck transaction's fee) and rebroadcast.
11. **Ledger Writer** -- the only component that writes journal entries to the ledger service. All deposit credits and withdrawal debits go through here.
12. **Reconciler** -- offline process that compares chain state with ledger state and flags drift.
13. **Solana I/O** (Coinbase's per-chain dedicated Solana ingestion pipeline) -- Coinbase's name (per their 2025 engineering blog) for the Solana-specific deposit fast path; achieves 20% deposit-latency reduction over the chain-agnostic pipeline by exploiting Solana's fast finality.

---

## Step 3: Data Model

### Core Tables

```sql
-- Top-level deposit lifecycle row.
deposit_requests (
  id              BIGINT PRIMARY KEY,
  user_id         BIGINT NOT NULL,
  asset           VARCHAR(16) NOT NULL,        -- 'BTC', 'ETH', 'USDC-ETH', 'SOL'
  chain           VARCHAR(16) NOT NULL,
  deposit_address VARCHAR(128) NOT NULL,
  amount          NUMERIC(78, 0) NOT NULL,     -- integer smallest-units
  txid            VARCHAR(128) NOT NULL,
  vout            INT,                          -- UTXO index (BTC); null for account chains
  block_hash      VARCHAR(128),
  block_height    BIGINT,
  state           VARCHAR(32) NOT NULL,         -- see deposit FSM
  confirmations   INT NOT NULL DEFAULT 0,
  required_confs  INT NOT NULL,                 -- per-chain, per-amount-tier policy
  detected_at     TIMESTAMP NOT NULL,
  credited_at     TIMESTAMP,
  ledger_tx_id    BIGINT,                       -- FK into ledger journal
  idempotency_key VARCHAR(128) NOT NULL UNIQUE, -- = (chain, txid, vout) hash
  version         INT NOT NULL DEFAULT 0,
  UNIQUE (chain, txid, vout)
);

-- Top-level withdrawal lifecycle row.
withdrawal_requests (
  id              BIGINT PRIMARY KEY,
  user_id         BIGINT NOT NULL,
  asset           VARCHAR(16) NOT NULL,
  chain           VARCHAR(16) NOT NULL,
  destination     VARCHAR(128) NOT NULL,
  amount          NUMERIC(78, 0) NOT NULL,
  fee_amount      NUMERIC(78, 0),
  state           VARCHAR(32) NOT NULL,         -- see withdrawal FSM
  policy_decision JSONB,                        -- pass/fail/hold from each gate
  ledger_hold_id  BIGINT,                       -- ledger entry holding the debit
  signing_request_id VARCHAR(128),
  current_txid    VARCHAR(128),                 -- mutable: RBF/replacement updates this
  broadcast_at    TIMESTAMP,
  confirmed_at    TIMESTAMP,
  settled_at      TIMESTAMP,
  idempotency_key VARCHAR(128) NOT NULL UNIQUE, -- = (user_id, client_request_id)
  version         INT NOT NULL DEFAULT 0,
  created_at      TIMESTAMP NOT NULL
);

-- One row per signing attempt. Idempotent by signing_request_id.
signing_requests (
  id              VARCHAR(128) PRIMARY KEY,     -- = withdrawal_id + nonce/utxo set
  withdrawal_id   BIGINT NOT NULL REFERENCES withdrawal_requests(id),
  unsigned_tx     BYTEA NOT NULL,
  signed_tx       BYTEA,
  signer_tier     VARCHAR(16) NOT NULL,         -- 'hot_hsm', 'warm_mpc', 'cold_multisig'
  status          VARCHAR(32) NOT NULL,         -- 'requested', 'signed', 'failed'
  created_at      TIMESTAMP NOT NULL,
  signed_at       TIMESTAMP
);

-- Append-only log of every broadcast attempt.
broadcast_attempts (
  id              BIGINT PRIMARY KEY,
  withdrawal_id   BIGINT NOT NULL REFERENCES withdrawal_requests(id),
  txid            VARCHAR(128) NOT NULL,
  raw_tx          BYTEA NOT NULL,
  rpc_endpoint    VARCHAR(255) NOT NULL,
  fee_rate        NUMERIC(38, 18),
  reason          VARCHAR(64) NOT NULL,         -- 'initial', 'rbf_bump', 'rebroadcast'
  result          VARCHAR(32) NOT NULL,         -- 'accepted', 'rejected', 'replaced'
  attempted_at    TIMESTAMP NOT NULL
);

-- Per-block confirmation observation (for both deposits and withdrawals).
confirmation_events (
  id              BIGINT PRIMARY KEY,
  chain           VARCHAR(16) NOT NULL,
  txid            VARCHAR(128) NOT NULL,
  block_hash      VARCHAR(128) NOT NULL,
  block_height    BIGINT NOT NULL,
  confirmations   INT NOT NULL,
  observed_at     TIMESTAMP NOT NULL,
  INDEX (chain, txid)
);

-- Address registry: every Coinbase-owned receive address.
deposit_addresses (
  address         VARCHAR(128) PRIMARY KEY,
  chain           VARCHAR(16) NOT NULL,
  user_id         BIGINT,                       -- null for omnibus/sweep addresses
  derivation_path VARCHAR(255),
  active          BOOLEAN NOT NULL DEFAULT true,
  created_at      TIMESTAMP NOT NULL
);
```

### Key Design Decisions in the Schema

**`idempotency_key UNIQUE` on both deposit and withdrawal:** This is the foundation. For deposits, the key is derived from `(chain, txid, vout)` -- the chain itself provides natural uniqueness. For withdrawals, the key is derived from `(user_id, client_request_id)` -- the client provides it, and the same retry returns the same row. The unique index makes duplicate insertion fail at the database level, not the application level.

**`state` column with versioned rows:** The state machine is encoded as a string column with a `version` for optimistic concurrency. Every transition is `UPDATE ... WHERE state = :expected_state AND version = :expected_version`. If the row moved underneath us (concurrent worker, race), the update affects zero rows and we restart from the current state.

**Separate `signing_requests` and `broadcast_attempts` tables:** A withdrawal can have multiple signing attempts (rare -- usually only on signer retry) and multiple broadcast attempts (common -- RBF, rebroadcast, fee bump). Modeling them as append-only sub-tables preserves the audit trail. The withdrawal's `current_txid` points to the latest attempt; the history lives in `broadcast_attempts`.

**`amount NUMERIC(78, 0)`:** Largest BTC amount fits in 64 bits, but ETH wei needs more (256-bit). `NUMERIC(78, 0)` covers any 256-bit unsigned integer with room to spare. Floats are forbidden (IEEE 754 rounding bugs cost real money).

---

## Step 4: Deposit State Machine

The deposit FSM is the heart of the deposit pipeline. Every transition is a journal entry; recovery from any partial state is by walking the FSM forward.

```
              +-------------+
              |  DETECTED   |  block scanner saw a tx to a known address
              +------+------+
                     |
                     v
              +-------------------+
              | PENDING_CONFIRMS  |  waiting for N confirmations
              +------+------------+
                     |
                     | (N confirmations reached, no reorg)
                     v
              +-------------+
              |  CONFIRMED  |  ready to credit; not yet credited
              +------+------+
                     |
                     | (ledger journal entry written)
                     v
              +-------------+
              |  CREDITED   |  user balance updated
              +------+------+
                     |
                     | (downstream events emitted, eligible for withdrawal)
                     v
              +-------------+
              |   SETTLED   |  terminal: visible to user, withdrawable
              +-------------+

   Reorg branches (entered from PENDING_CONFIRMS, CONFIRMED, or CREDITED):

         REORG_PENDING  --(reorged tx not in new chain)--> REORG_REVERSED
              |                                                  ^
              | (reorg resolved; tx still in canonical chain)    |
              v                                                  |
         back to PENDING_CONFIRMS / CONFIRMED                    |
                                                                 |
   CREDITED --reorged--> REVERSAL_PENDING --ledger reversed--> REORG_REVERSED
```

### Why an Explicit FSM

Without an explicit state column and version-checked transitions, the system races itself. Two workers reading the same deposit can both decide "this needs crediting" and double-credit the user. The FSM with `UPDATE ... WHERE state = :expected_state AND version = :v` makes every transition atomic and exactly-once.

### Crediting Transition (the Critical One)

```
PENDING_CONFIRMS --> CONFIRMED:
  1. Confirmation watcher observes confirmations >= required_confs
  2. UPDATE deposit_requests
       SET state = 'CONFIRMED',
           confirmations = :n,
           version = version + 1
       WHERE id = :id AND state = 'PENDING_CONFIRMS' AND version = :v
  3. If 0 rows affected, retry (someone else moved the row)

CONFIRMED --> CREDITED:
  1. BEGIN TRANSACTION
       Call ledger.credit(user_id, asset, amount,
                          idempotency_key = deposit.idempotency_key)
       UPDATE deposit_requests
         SET state = 'CREDITED',
             ledger_tx_id = :returned_id,
             credited_at = NOW(),
             version = version + 1
         WHERE id = :id AND state = 'CONFIRMED' AND version = :v
  2. COMMIT
  3. Publish 'deposit.credited' to outbox in same transaction
```

The ledger call is idempotent (same `idempotency_key` returns the same `ledger_tx_id`), so a crash between the ledger call and the FSM update is recoverable: the next worker calls the ledger again, gets the same id, and the FSM update succeeds (or is already done).

---

## Step 5: Per-Chain Confirmation Policy

Different chains have different security models. A one-size-fits-all confirmation count is wrong on both axes -- too few and you credit reorged transactions; too many and deposits feel slow.

| Chain | Small (<$1K) | Medium ($1K-$10K) | Large (>$10K) | Notes |
|---|---|---|---|---|
| Bitcoin | 1 conf | 3 confs | 6 confs | ~10-min blocks; published Coinbase numbers |
| Ethereum | 12 confs | 12 confs | 12 confs | ~13s blocks; ~2.5 min; uniform |
| Polygon | 128 blocks | 256 blocks | 256 blocks | ~2s blocks; long-tail reorgs known |
| Solana | finalized | finalized | finalized | finality is single-slot definition; ~13s for "rooted" |
| Arbitrum / Optimism (L2 -- Layer 2, rollups and other scaling solutions on top of an L1 blockchain) | L1 settlement | L1 settlement | L1 settlement | wait for L1 (Ethereum) inclusion |
| USDC-ETH (ERC-20) | 12 confs | 12 confs | 12 confs | inherits ETH security model |

### How to Choose N

Two factors:
1. **Chain reorg distribution.** What's the depth of the deepest observed reorg in the last 6 months? Confirmation count must exceed it with margin. Polygon has a long-known tail of deep reorgs (hence ~256), Ethereum deep reorgs are vanishingly rare past 12.
2. **Economic risk of reorg vs UX cost of waiting.** A $50 deposit reorged is annoying; a $50K deposit reorged is a real loss. Hence amount-tiered confirmations on Bitcoin -- small deposits credit fast, large deposits wait.

### Why Solana Is Different

Solana doesn't have a "confirmations" concept in the Bitcoin sense. It has `processed`, `confirmed`, `finalized`. We wait for `finalized` (rooted by supermajority). This is fundamentally faster than 12 ETH blocks, which is why Coinbase's Solana I/O pipeline (per their 2025 engineering blog) hits a 20% deposit-latency reduction over the chain-agnostic path -- Solana finality is single-shot, no block-counting required.

---

## Step 6: Reorg Handling

A reorg is a normal event, not an exception. Treat it as such.

### What Triggers Reversal

The Reorg Tracker keeps a sliding window of the last K blocks per chain (K = required_confs + safety margin). For each block in the window, it stores `(height, block_hash, txids_to_us)`. Each new block ingestion checks: does the new block at height H match the hash we previously recorded for H? If not, the chain reorged.

When a reorg is detected:

1. **Compute the reorg depth.** How far back does the divergence go?
2. **For each affected deposit** (by querying `deposit_requests WHERE block_height >= reorg_start`):
   - If still in `PENDING_CONFIRMS` and the txid is now in the new canonical chain at a different height, update `block_hash` and `block_height` and reset `confirmations`. No reversal needed.
   - If still in `PENDING_CONFIRMS` and the txid is **not** in the new canonical chain, transition to `REORG_REVERSED`. No ledger reversal needed (we never credited).
   - If in `CONFIRMED` or `CREDITED` and the txid disappeared, transition to `REVERSAL_PENDING`. Call `ledger.reverse(ledger_tx_id, idempotency_key = original_key + ":reversal")`. On success, transition to `REORG_REVERSED`.
3. **Re-emit transactions** that are in the new canonical chain but were not in the old. These are net-new deposits; they enter `DETECTED` with their own idempotency key derived from `(chain, txid, vout)`. The unique constraint guarantees no double-detection.

### Idempotency on Re-Emit

The deposit `idempotency_key` is `hash(chain, txid, vout)`. If the same tx reappears in the canonical chain at a different block height (common during shallow reorgs), the key is still the same -- so the unique index prevents creating a second deposit row. We just update the existing row's `block_hash` and `block_height`.

### Alerting on Deep Reorgs

Reorg depth > required_confs (e.g., 12 blocks on ETH) is anomalous and indicates either a real chain split, a node sync issue, or an attack. Alert on-call. Pause the deposit pipeline for that chain. Wait for chain to stabilize. Resume manually.

### Why You Cannot Just "Reverse the Credit and Move On"

If the user already withdrew the credited deposit, the reversal cannot just decrement balance -- it would go negative. Policy options:
- Refuse to honor the withdrawal until the deposit is N+M confirmations (stronger lockout for high-value)
- Insure deposits below N confirmations against reorg loss (Coinbase's instant-deposit feature is roughly this)
- Block reorg-vulnerable deposits from withdrawal until settlement

---

## Step 7: Withdrawal State Machine

Mirror image of the deposit FSM, but with more stages because the system is the active party.

```
+-----------+     +----------+     +-------------+     +---------------+
| REQUESTED | --> | DEBITED  | --> | RISK_PASSED | --> | POLICY_PASSED |
+-----------+     +----------+     +-------------+     +-------+-------+
                                                               |
+----------+    +----------+    +---------+    +----------+    |
| SETTLED  |<-- | CONFIRMED|<-- |BROADCAST|<-- |  SIGNED  |<---+
+----------+    +----------+    +---------+    +----------+    |
                                                               |
                                                       +-------v-------+
                                                       |   UNSIGNED    |
                                                       +---------------+

   Failure branches:
     RISK_PASSED   --risk_fail-->     RISK_REJECTED   (refund debit)
     POLICY_PASSED --policy_fail-->   POLICY_REJECTED (refund debit, hold for review)
     UNSIGNED      --signer_unavail-> SIGNING_QUEUED  (retry with backoff)
     SIGNED        --rbf_replace-->   SIGNED          (new txid; old replaced)
     BROADCAST     --reorged-->       BROADCAST       (rebroadcast)
     BROADCAST     --stuck-->         RBF_BUMPED      (replace with higher fee)
```

### Stage-by-Stage

1. **REQUESTED** -- API received the request, validated shape, deduped on idempotency key.
2. **DEBITED** -- ledger has placed a hold on the user's balance. This is the single point of "money committed". A failure after this stage refunds the hold.
3. **RISK_PASSED** -- fraud / behavioral score below threshold. (Hook into the [fraud risk scoring](../17-coinbase-fraud-risk-scoring/) service.)
4. **POLICY_PASSED** -- velocity, allowlist, OFAC, Travel Rule all green. See Step 8.
5. **UNSIGNED** -- transaction has been built. Inputs selected (UTXO selection on BTC, nonce assigned on ETH, etc.).
6. **SIGNED** -- signer returned a signature. Idempotent by `signing_request_id`.
7. **BROADCAST** -- the signed tx is in the mempool; a node accepted it.
8. **CONFIRMED** -- N confirmations on chain (per-chain policy, similar to deposit but typically lower because we control the inputs).
9. **SETTLED** -- terminal. User notified, ledger hold converted to debit, audit logs sealed.

### Why DEBITED Comes Before Policy / Risk

Debit first, then evaluate policy. If we evaluated policy first and the user has a stale balance, two concurrent withdrawals could both pass policy and overdraw. By debiting (placing a hold) first, the balance check is atomic via the ledger, and policy evaluates against an already-reserved amount. If policy fails, we refund the hold -- a small price for correctness.

This is the same pattern as Shopify's reservation-then-confirm: the resource is held early; the rest of the gates run against the held resource; failure paths release the hold.

---

## Step 8: Policy Gates

Policy is separate from execution. Policy is a pure function `(withdrawal_request, user_state, market_state) -> {pass, fail, hold}`. Execution is signing and broadcasting. Don't entangle them.

| Gate | What | Failure mode | Order |
|---|---|---|---|
| Balance check | Sufficient funds (already done by DEBITED) | Reject with insufficient funds | 1 |
| Velocity limit | Per-day cap per asset (e.g., $10K/day default) | Hold for higher-tier 2FA, or reject | 2 |
| Withdrawal allowlist | Destination is on the user's pre-registered allowlist (48-hour wait for newly added addresses) | Hold until 48h elapses | 3 |
| 2FA | Recent 2FA proof present and bound to this withdrawal | Send 2FA challenge; wait for response | 4 |
| OFAC sanctions | Destination address is not on a sanctioned list | Reject and report to compliance | 5 |
| Travel Rule | Withdrawals >$3K must include originator/beneficiary info if to a regulated VASP | Hold until info collected | 6 |
| Fraud score | ML model output below threshold | Hold for manual review | 7 |

### Why Order Matters

Cheap gates first, expensive gates last. Balance is a single ledger read. Velocity is a Redis counter lookup. Allowlist is a single row read. OFAC requires a sanctions-list lookup (cached in Redis from a daily-pulled OFAC SDN list). Fraud score requires a model inference call. Failing fast on cheap gates saves load on expensive ones.

OFAC must come before Travel Rule because if the destination is sanctioned, we don't even want to collect originator/beneficiary info -- we want to block immediately and report.

### Idempotency on Gate Re-evaluation

A withdrawal can re-enter the policy stage (e.g., after a 2FA hold is satisfied). Each gate's decision is recorded in `policy_decision JSONB` keyed by gate name with a timestamp. Re-evaluation only re-runs gates that haven't already passed, or whose pass is older than a TTL (Time To Live; 5 minutes for fraud, 24h for allowlist).

### Policy as a Separate Service

Policy gates are a separate service from the orchestrator. This isolates them: a fraud model deploy that breaks doesn't take down the withdrawal pipeline; the orchestrator can fall back to a more conservative policy (manual review for everything) if the fraud service is unavailable. **Fail closed on policy** -- a stuck policy service blocks withdrawals; it does not pass them through.

---

## Step 9: Signing Service Interaction

Signing is an external service with three tiers, used based on amount and destination risk.

| Tier | Backend | Use case | Latency | Idempotency |
|---|---|---|---|---|
| Hot | HSM (Hardware Security Module) | Small withdrawals, high volume | < 1s | `signing_request_id` |
| Warm | MPC (Multi-Party Computation -- threshold signing across nodes) | Medium withdrawals; default tier for most flows | 2-10s | `signing_request_id` |
| Cold | Multi-sig + ceremony (offline, multiple signers, audited) | Large withdrawals; cold-tier replenishment to hot wallets | hours to a day | `signing_request_id` |

### The Sign-Once Guarantee

The single most important property: **never produce two valid signatures for the same withdrawal**. If we sign twice with different inputs (different fees, different nonces, different UTXOs), we now have two transactions that can both broadcast and confirm -- one of which is unauthorized.

The guarantee comes from the `signing_requests` table: `signing_request_id` is the primary key, derived from `withdrawal_id + tx_inputs_hash`. The signer is itself idempotent: it stores past signing decisions and returns the same signature for the same id. If we want to sign with different inputs (e.g., RBF with higher fee), we generate a **new** `signing_request_id`. The original is recorded as superseded; the new one signs fresh.

### Signer Unavailability

If the signer is down (HSM cluster failover, MPC node offline, ceremony delayed):
- Don't fail the withdrawal. It's already DEBITED and POLICY_PASSED. We owe the user this transaction.
- Stay in `UNSIGNED` state; queue for retry with backoff.
- If outage exceeds threshold (e.g., 30 min on hot tier), failover to next-warmer tier (hot -> warm with manual op approval).
- If all tiers are out, emit alert and pause withdrawal acceptance at the API edge. The pipeline can drain its current backlog without taking new requests.

---

## Step 10: Broadcast and Mempool Management

Broadcasting is not "done". A signed transaction in the mempool can be dropped, replaced, or stuck for hours. The Mempool Watcher and Broadcaster work together to drive each withdrawal to confirmation.

### The Mempool Lifecycle

```
SIGNED --> [broadcast to RPC node 1, 2, 3 (redundant)] --> in mempool
   |
   v
[poll mempool / chain every 10-30s]
   |
   +-- accepted, in next block      --> CONFIRMED (1 conf)
   +-- still in mempool, low fee    --> consider RBF if older than threshold
   +-- evicted from mempool         --> rebroadcast
   +-- replaced by another tx (RBF) --> verify replacement is ours; update current_txid
   +-- competing tx confirmed       --> alert (potential double-spend attempt)
```

### Bitcoin RBF (Replace-By-Fee)

If a BTC transaction is stuck for more than ~30 minutes due to insufficient fee:
1. Build a replacement tx with the same inputs but higher fee.
2. Generate a new `signing_request_id`. Sign it.
3. Broadcast. Bitcoin's RBF rules require the new fee to be higher and to pay for the bandwidth of the replacement.
4. Update `withdrawal_requests.current_txid`. The old tx is recorded in `broadcast_attempts` with `result = 'replaced'`.

**The trap:** if you broadcast the replacement before the original fully clears, the network may have either tx confirm. Both are signed and valid. By re-using the same input set, only one can confirm (it's a double-spend by design); the other is naturally invalidated. **Never RBF with different inputs** -- that creates two parallel valid transactions.

### Ethereum Nonce Ordering

Each ETH account has a strict nonce sequence. If we broadcast nonce 5 and it gets stuck, broadcasting nonce 6 won't confirm until 5 lands. So:
- Each hot wallet has a per-wallet nonce sequencer (a Redis counter, fenced by a database transaction for the assignment).
- Broadcast in nonce order.
- If a nonce is stuck, the bump strategy is "replace the stuck nonce with higher gas price for the same nonce". Same nonce = same slot in the sequence; replacing it unblocks the queue.
- Alternative: send a self-transfer at the stuck nonce with very high gas to clear it, then re-issue the original at a fresh nonce. (Ugly but sometimes necessary if you don't have the original signed tx anymore.)

### Fee Estimation

Per chain:
- BTC: estimate via mempool histogram + percentile target (e.g., 50th percentile of last 6 blocks for "next 6 blocks" target).
- ETH: EIP-1559 (Ethereum's fee market upgrade introducing base + priority fee) base fee + priority fee; priority fee from recent inclusion data.
- Re-estimate on every rebroadcast or RBF.

### Stuck-Tx Detection

Per chain, define "stuck" -- a tx in mempool past expected inclusion time. Examples:
- BTC: > 30 min in mempool with fee below current next-block-target.
- ETH: > 5 min past nonce when chain has progressed but our nonce hasn't.

The Mempool Watcher emits `withdrawal.stuck` events; the orchestrator decides whether to RBF.

---

## Step 11: Batch Withdrawals

Combining many users' withdrawals into one on-chain tx is a major fee win, especially on ETH where each output is cheap relative to per-tx overhead.

### When to Batch

- All outputs go on the same chain
- Outputs going to the same chain segment (Coinbase batches every ~5 minutes by default; can be more frequent under load)
- Total batch size capped to bound the fee impact and the blast radius of partial failure
- Skip batching if a withdrawal is high-priority (institutional flow, urgent, or large enough that single-tx makes sense)

### Building a Batch

```
1. Pull all withdrawal_requests in state SIGNED-pending-batch for chain X
2. Sort by created_at (FIFO fairness)
3. While batch.size < max and total_outputs < chain_limit:
     append next withdrawal
4. Build a single unsigned tx with all outputs
5. signing_request_id = hash(batch_id + outputs_hash)
6. Sign once; broadcast once
7. On confirmation, mark every withdrawal in the batch as CONFIRMED
```

### Partial Failure

A batch is one signed transaction -- it either confirms or it doesn't. There's no per-output partial confirmation. So:
- If the batch tx is rejected at broadcast (e.g., one output is to a now-sanctioned address), we cannot just drop that one output. We rebuild the batch without it, generate a new signing_request_id, sign again.
- If the batch is replaced (RBF), the new tx covers the same outputs. All withdrawals in the batch update `current_txid`.
- If we discover during build that one withdrawal in the candidate batch should be excluded (e.g., user just had 2FA fail), drop it before signing and re-evaluate.

### Saga + Compensation

The batch is a saga: each withdrawal contributes one output. If the batch ultimately fails to broadcast permanently, every withdrawal in the batch reverts to UNSIGNED, gets re-queued, and eventually goes into a smaller batch or single-tx. The ledger holds remain in place; nothing is refunded until permanent failure (e.g., destination sanctioned), at which point each withdrawal's compensation runs (refund hold, mark POLICY_REJECTED).

### Fairness

FIFO by `created_at` for the candidate set. Within a batch, on-chain output order does not matter functionally, but for ETH the gas cost can vary slightly by output position (bytecode-level effects). For BTC, order is irrelevant.

### Dust Handling

Some withdrawal amounts are below the chain's dust threshold (e.g., < 546 sat on BTC). Two options:
- Reject at policy stage with "below minimum"
- Accumulate and pay user out periodically when the sum crosses the threshold (rare; usually we just reject)

---

## Step 12: Reconciliation

Reconciliation is the safety net. The pipeline can have bugs; the chain can have anomalies. Reconciliation catches drift before it becomes a customer-visible incident.

### What's Reconciled

For every (chain, asset, hot/warm wallet) tuple:
1. **Sum of on-chain balance** at current head height
2. **Sum of ledger balances** for users custodied by that wallet
3. **Sum of in-flight withdrawals** (DEBITED but not yet CONFIRMED, value held)
4. **Sum of in-flight deposits** (PENDING_CONFIRMS, value not yet credited)

The invariant: `chain_balance + in_flight_withdrawals - in_flight_deposits == sum_of_user_ledger_balances`.

If the equation is off by more than a tolerance (which can be zero for some pairings), flag drift.

### Cadence

- **Continuous (every 5-10 min)**: cheap delta reconciliation. Compare last-known totals to current totals. Any large delta that doesn't match a known pipeline event triggers alert.
- **Periodic full reconciliation (hourly to daily)**: re-derive balances from the journal and from chain state independently; compare totals.
- **End-of-day**: full reconciliation, snapshotted, archived for audit.

### Auto-Remediation

Most drift is small and explainable: a tx confirmed in the last block we haven't ingested yet, a hold on a pending withdrawal not yet broadcast. Auto-remediation: re-ingest the latest blocks, re-evaluate pending state, see if drift resolves. If drift persists past a tolerance, escalate.

**Auto-correct nothing financial.** Reconciliation flags drift; humans (with audit) make corrections via reversing journal entries. There is no automated "well, the chain says we have $50K so let's update the ledger to match" -- that is how exchanges lose money quietly.

---

## Step 13: Operational Tooling

### Dashboards

- **Pipeline health per chain:** deposit detection latency p50/p99, confirmation latency, withdrawal broadcast latency, mempool clearance rate.
- **State distribution:** how many deposits / withdrawals are in each state. Anomalies (e.g., 1000 stuck in UNSIGNED) jump out visually.
- **Stuck-tx counts:** how many withdrawals have been in BROADCAST > T minutes. Alert past threshold.
- **Reorg storm tracker:** rolling count of reorgs per chain. Spike means something is happening.
- **Reconciliation drift:** live drift number per (chain, asset). Should be small and oscillating around zero.

### Alerts

- Deposit detection latency p99 > 60s
- Withdrawal stuck in any state > stage SLA
- Signer unavailability > 5 min on hot tier
- Reorg depth > required_confs (deep reorg)
- Reconciliation drift > tolerance
- Hot wallet balance below replenishment threshold (kicks off cold-to-warm-to-hot ceremony pipeline)

### Manual Ops Console

For incidents, a small set of authenticated, audited operations:
- **Pause withdrawals on chain X.** Used during chain RPC outage or signer outage.
- **Force-fail a stuck withdrawal.** When all auto-remediation has been exhausted; manually marks the withdrawal as failed and refunds the hold. Audit trail records who, why, when.
- **Replay deposit detection from block H.** When a block was missed or processed incorrectly; idempotency keys ensure no double-credit.
- **Resume after pause.** Always paired with a pause; explicit op required.

### Kill Switch

A single command that pauses *all* withdrawals platform-wide. Used for severe incidents (signing key compromise suspected, chain attack underway, unknown discrepancy). Pause immediately; investigate; resume only with executive sign-off. Same pattern as Shopify's flash-sale circuit breakers but with much higher stakes -- a wrong withdrawal under attack is irrecoverable.

---

## Step 14: Failure Modes

### Failure: Signed-But-Not-Broadcast

Service crashes after `signing_requests.status = 'signed'` but before broadcast.
- **Problem:** if we naively roll back the withdrawal, we still have a valid signed tx that someone with access could broadcast.
- **Solution:** roll forward, never back. The orchestrator's recovery loop finds withdrawals in SIGNED state and broadcasts them. The signing is durable; we just need to deliver it.
- **Storage:** signed_tx is stored in `signing_requests.signed_tx`. Encrypted at rest.

### Failure: Broadcast-But-Replaced (Mempool Replacement)

Mempool dropped our tx; another tx with the same nonce or same UTXOs confirmed instead.
- **Detection:** Mempool Watcher sees a confirmed tx with our wallet as sender at the nonce we used, but with a different txid.
- **If the replacement is also ours (RBF we issued):** update `current_txid`, continue.
- **If the replacement is not ours:** this is a key compromise scenario. Pause the wallet. Page security. Audit the signing request log.

### Failure: Confirmed-But-Reorged

A withdrawal we marked CONFIRMED gets reorged out.
- **Detection:** Reorg Tracker emits reorg covering our tx height; our txid is no longer in the canonical chain.
- **Recovery:** rebroadcast the same signed tx (it's still valid -- nonces and UTXOs are unchanged). It will likely re-confirm in the new chain.
- **Edge case:** if a competing tx now occupies our nonce in the new chain (e.g., we re-issued during the reorg with a different nonce), we have to RBF or reissue. The audit trail tracks every attempt.

### Failure: Signer Unavailable

HSM cluster failover, MPC node down, multi-sig signer offline.
- **Hot tier (HSM):** automated failover to standby cluster within seconds.
- **Warm tier (MPC):** threshold scheme survives some node loss; if below threshold, queue and wait, alert on-call.
- **Cold tier:** ceremonies are scheduled; outage means delay, not failure. Withdrawals queue.

### Failure: Chain RPC Outage

Our node provider fails; we can't reach the chain.
- **Multiple providers per chain.** Rotate among Coinbase-operated nodes and external providers (Infura, QuickNode, Alchemy for ETH; private BTC nodes; Helius for Solana).
- **Health checks via known recent blocks:** a provider that returns an old head height is sick.
- **Fail closed on writes:** don't broadcast to a sick provider (might silently drop). Fail open on reads if degraded reads are acceptable (e.g., confirmation counts can lag a minute without harm).

### Failure: Fee Spike

Mempool congestion spikes; our transactions stuck.
- **Auto-RBF up to a configured maximum fee (e.g., 5x estimated).**
- **Beyond the cap:** hold withdrawal, alert. Don't burn user funds on fees during a black-swan congestion event.

### Failure-Recovery Matrix

| Failure | Detection | Recovery | Escalation |
|---|---|---|---|
| Signed-not-broadcast | Orch. recovery loop finds SIGNED rows | Re-broadcast | Page if > 5 min |
| Broadcast-replaced (own RBF) | Mempool watcher | Update current_txid | None |
| Broadcast-replaced (foreign) | Mempool watcher | Pause wallet, audit | Sec page immediate |
| Confirmed-reorged | Reorg Tracker | Rebroadcast same tx | Page if deep reorg |
| Signer down | Health check | Failover; queue | Page after threshold |
| Chain RPC down | Provider health check | Rotate provider | Page if all down |
| Reconciliation drift | Reconciler | Re-ingest blocks | Page if persistent |
| Fee spike | Stuck-tx detector | RBF up to cap | Page at cap |

---

## Step 15: Tradeoffs Summary

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Deposit credit timing | After N confirmations | Optimistic instant credit | Reorg risk on instant; instant only as opt-in user-facing feature |
| Confirmation count | Per-chain, amount-tiered | Global default | Reorg distribution and risk vary; one number is wrong on both axes |
| State machine vs implicit state | Explicit FSM with version checks | Implicit via column flags | Implicit races itself; FSM is exactly-once |
| Single tx vs batched withdrawal | Batch by default; single-tx override | Always single | Fee savings massive on ETH; batch is the right default |
| Sync vs async signing | Async, with idempotency | Sync inline | Signer latency variable; async lets the API respond fast |
| Hot wallet size | Capped low ($10K typical BTC) | Large for UX | Blast radius on key compromise; replenishment ceremony is acceptable cost |
| Policy gate ordering | Cheap-first, OFAC before Travel Rule | Arbitrary order | Save load; sanctioned destinations should not collect originator info |
| Reorg handling | Explicit reversal via FSM | Treat as exception | Reorgs are expected; handle them in the steady state |
| Idempotency key source | Chain-derived for deposits, client-derived for withdrawals | One source for both | Each direction has a natural unique identifier; use it |
| Reconciliation auto-correct | Flag only, no auto-fix on financial drift | Auto-correct small drifts | Auto-correcting is how exchanges lose money quietly |

---

## Step 16: Common Mistakes to Avoid

1. **Treating broadcast as "done".** A transaction in the mempool is not confirmed. It can be dropped, replaced, or stuck for hours. Withdrawal isn't done until N confirmations. Many failures come from emitting "withdrawal complete" events at broadcast time.

2. **No reorg handling.** Designing as if the chain is immutable. Reorgs happen on every chain. A system that doesn't anticipate them silently double-credits or fails to reverse.

3. **Nonce conflicts on ETH.** Treating each withdrawal as independent, racing them through the signer, and discovering at broadcast that nonces collide. The hot wallet must be a serial point: one nonce-sequencer per wallet, transactions broadcast in order.

4. **Mutable withdrawal state.** Updating columns in place rather than appending state-transition events. You lose the audit trail; recovery from partial state becomes guesswork. Always append; never overwrite history.

5. **No idempotency on retries.** Client retries the same withdrawal request and we issue two transactions. The fix is end-to-end: the client provides an idempotency key, the API dedupes on it, the orchestrator stores it, the signer is keyed by it, and the broadcast records it. Same key all the way through.

6. **Failing open on chain RPC.** RPC returns stale data; we credit a deposit that hasn't actually confirmed yet, or broadcast a transaction that fails. Health-check providers; fail closed when degraded.

7. **Entangling policy with execution.** Putting OFAC checks inside the signer, or fraud scoring inside the broadcaster. When you need to change a policy, you have to redeploy a sensitive component. Keep them separate; policy decides, execution acts.

8. **Auto-correcting financial drift.** Reconciler sees ledger says $X, chain says $Y, "let's just update the ledger to match." This is how exchanges quietly lose money to bugs. Reconciliation flags; humans correct via reversing journal entries with audit.

9. **One signer tier for all amounts.** Hot HSM signing a $10M withdrawal is a blast-radius accident waiting to happen. Tier the signing by amount; cold-tier ceremonies for large or unusual flows.

10. **No kill switch.** When something goes wrong, you need to pause. A platform with no kill switch means an incident becomes a multi-million-dollar loss before anyone can intervene.

---

## Step 17: Follow-up Questions

### How would you add a new chain in a sprint?

The chain-specific layer is the Block Scanner, Tx Builder, and confirmation policy. Everything else (deposit FSM, withdrawal FSM, ledger writer, policy gates) is chain-agnostic. To add a chain:
1. Implement `BlockScanner<Chain>` -- tail blocks, decode, emit indexer events.
2. Implement `TxBuilder<Chain>` -- build unsigned tx from inputs/outputs.
3. Implement `ConfirmationPolicy<Chain>` -- amount-to-N mapping.
4. Add chain to the address registry's derivation logic.
5. Onboard the chain to the signer (chain-specific key types, signing schemes).
6. Smoke test on testnet with reorg simulation.

The reason this can be a sprint is that the orchestrator, FSM, ledger, and policy are reusable -- chain abstractions sit at the edges. Coinbase's approach to chain-agnostic vs chain-specific (the Solana I/O example -- 20% latency reduction by writing a chain-specific fast path -- shows you'll occasionally exit the abstraction for performance) is a real engineering decision.

### How does Account Abstraction (ERC-4337) change the flow?

ERC-4337 (Ethereum standard for account abstraction with bundlers and paymasters) introduces UserOperations, bundlers, and paymasters. Withdrawals to AA wallets are still standard from our side (we send to an address). Deposits *from* AA wallets are interesting because the originator looks like a bundler, not the actual user. For Travel Rule, we need to identify the actual originator -- which requires parsing the UserOperation, not just the on-chain tx. This affects the indexer's decoding logic. Paymaster sponsorship (where a third party pays gas) means the gas-payer address differs from the value-mover address; the deposit detector must look at the value transfer, not the gas sponsor.

### Cross-chain bridges -- what changes?

Bridges deposit on chain A and withdraw on chain B for the same user. The deposit pipeline detects on chain A as normal. The "withdrawal" on chain B is initiated by the bridge protocol (often a relay network or oracle), not by Coinbase. Coinbase as a bridge user is the depositor. As a bridge operator (rare for Coinbase) we'd run bonded relays. The complication: bridge withdrawals can be reverted by the bridge protocol, separate from chain reorgs. Add a "bridge confirmation" stage: chain confirmations + bridge protocol finality.

### Lightning Network deposits/withdrawals?

Lightning Network (Bitcoin payment channel network for off-chain micropayments) is off-chain channels with on-chain settlement. Deposits via Lightning are HTLC (Hash Time-Locked Contract -- Lightning Network atomic-payment primitive) payments to a Coinbase-owned channel; settlement is instant once the payment hash matches. Confirmation count is irrelevant (no on-chain tx for Lightning payments themselves). Withdrawals are payments out via channels; the "broadcast" stage becomes "send Lightning payment", and confirmation is the receipt of the preimage. Reorg handling does not apply (Lightning is not subject to reorgs once settled). Channel rebalancing and liquidity management replace nonce ordering and UTXO selection. The FSM stays largely the same; the chain-specific layers are entirely different. This is a good case for a separate pipeline rather than shoehorning Lightning into the on-chain flow.

---

## Related Topics

- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- saga pattern, idempotency keys, exactly-once via state machines
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- reorg handling, partial-state recovery, signer failover
- [[../../../05-async-processing/index|Async Processing]] -- pipeline orchestration, outbox relay, mempool watchers, confirmation tailers
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- append-only state-transition log, ACID for ledger writes
- [[../../../03-scaling-writes/index|Scaling Writes]] -- nonce sequencing per hot wallet, batched withdrawals, hot-row contention
- [[../14-coinbase-financial-ledger/PROMPT|Coinbase Financial Ledger]] -- this pipeline writes journal entries through the ledger service
- [[../15-coinbase-blockchain-indexer/PROMPT|Coinbase Blockchain Indexer]] -- the indexer the deposit pipeline consumes from
- [[../17-coinbase-fraud-risk-scoring/PROMPT|Coinbase Fraud Risk Scoring]] -- the risk gate the withdrawal pipeline calls
