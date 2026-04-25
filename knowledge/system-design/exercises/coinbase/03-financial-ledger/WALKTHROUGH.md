# Walkthrough: Design a Financial Ledger Service (Coinbase)

## Step 1: Clarify Requirements and Scope

Before drawing anything, lock down the scope with the interviewer:
- Is the ledger authoritative for balances, or is it a projection of an upstream source? (Authoritative. There is no other balance store. The ledger is the system of record.)
- Are we covering fiat, crypto, or both? (Both. Same journal model, different account types and reconciliation feeds.)
- How many users and assets? (Tens of millions of users, hundreds of supported assets, thousands of asset pairs. Not all users hold all assets.)
- What throughput should I size for? (Low tens of thousands of journal-entry pairs per second steady-state, 10x bursts during market events. Coinbase's identity tier sees 1.5M req/s; the ledger sees a fraction of that, but the writes are bursty around price moves.)
- What are the consistency requirements? (Strong. Every transaction is two equal-and-opposite entries committed atomically. No mutable balance fields. No floats.)
- What is the retention requirement? (7 years minimum, immutable, queryable for SAR (Suspicious Activity Report — required filing for suspected illicit activity) and IRS.)
- Who else writes to balances? (No one. Other services produce intent -- a trade, a withdrawal request -- and the ledger records the postings. The ledger is the only place that mints entries.)

This last point is the most important one. The ledger is a chokepoint by design. Trying to optimize for "many writers, eventually consistent" breaks the entire premise -- you cannot reconcile a ledger that has multiple authors writing in parallel without a coordinator.

**Primary design constraint:** Two sources of truth must always reconcile. Internal journal vs blockchain (crypto) and internal journal vs bank statement (fiat). Every other architectural decision filters through "does this make reconciliation possible, or harder?"

---

## Step 2: High-Level Architecture

```
Trade Engine    Custody Service   Payments Service   Admin Console
     |                |                  |                |
     |                |                  |                |
     +----------------+--------+---------+----------------+
                               |
                               v
                +--------------+--------------+
                |    Ledger API Gateway       |  (auth, idempotency check, schema)
                +--------------+--------------+
                               |
                               v
                +--------------+--------------+
                |    Ledger Service           |  (postings, validation, sagas)
                |    (stateless workers)      |
                +--------------+--------------+
                               |
              +----------------+----------------+
              |                                 |
              v                                 v
      +-------+--------+              +---------+---------+
      | Postgres       |              | Idempotency Store |
      | (sharded by    |              | (Postgres or DDB) |
      |  user_id)      |              +-------------------+
      | journal +      |
      | accounts +     |
      | outbox         |
      +-------+--------+
              |
              v
      +-------+--------+      +---------------------+
      | Outbox Relay   | ---> | Kafka (event bus)   |
      +----------------+      +----------+----------+
                                         |
              +--------------------------+--------------------------+
              |                |                  |                 |
              v                v                  v                 v
       +------+------+  +------+------+   +-------+-------+  +------+------+
       | Reconciler  |  | Tax / Cost  |   | Compliance /  |  | Analytics / |
       | (chain+bank | |  Basis      |   | SAR / Audit   |  | Notifications|
       |  diff)      |  | Engine      |   | Pipeline      |  +-------------+
       +------+------+  +-------------+   +---------------+
              |
              v
       +------+------+
       | Drift Alert |
       | + Auto-Heal |
       +-------------+
```

### Core Components

1. **Ledger API Gateway** -- enforces authn/authz, validates the `idempotency_key` is present, schema-checks every posting request before forwarding.
2. **Ledger Service** -- stateless workers that build journal entry pairs from a posting request, validate balance invariants, and commit to Postgres in a single transaction.
3. **Postgres (sharded by `user_id`)** -- the system of record. Holds journal entries, account metadata, idempotency rows, and the outbox. ACID (Atomicity, Consistency, Isolation, Durability — classic transactional database guarantees) transactions are non-negotiable here.
4. **Idempotency Store** -- a per-key uniqueness barrier. Can be a Postgres table on the same shard or a separate DynamoDB-style store. Keyed by `(operation_key, namespace)`.
5. **Outbox Relay** -- tails the outbox table inside each shard and publishes events to Kafka exactly-once-effectively. Closes the dual-write gap.
6. **Reconciler** -- a continuously-running job that diffs ledger state against the chain (for crypto) and bank statements (for fiat). Emits drift alerts and, where safe, files reversing entries.
7. **Tax / Cost Basis Engine** -- consumes journal events and maintains per-user lot tables (FIFO/LIFO/HIFO — First-In-First-Out / Last-In-First-Out / Highest-In-First-Out tax cost-basis selection methods).
8. **Compliance / Audit Pipeline** -- long-term archival, SAR query support, IRS reporting.

---

## Step 3: Data Model -- Journal Entries and Accounts

This is the part to lead with in the interview. Everything else flows from the schema.

### Account Hierarchy

Accounts are typed and partitioned. Every dollar and every satoshi lives in exactly one account at any moment.

```sql
-- Accounts: every "place money can be" gets a row here.
-- Internal accounts (fees, omnibus, suspense) plus per-user accounts.
accounts (
  id              BIGINT PRIMARY KEY,
  account_type    VARCHAR(40) NOT NULL,    -- 'user_funding','user_holdings','exchange_omnibus',
                                           -- 'trading_fees','custody_fees','deposit_pending',
                                           -- 'withdrawal_outbound','suspense'
  owner_id        BIGINT,                  -- user_id for user accounts; NULL for internal
  asset           VARCHAR(20) NOT NULL,    -- 'USD','USDC','BTC','ETH', ...
  normal_side     CHAR(1) NOT NULL,        -- 'D' (debit-normal) or 'C' (credit-normal)
  currency_decimals SMALLINT NOT NULL,     -- 2 for USD, 8 for BTC, 18 for ETH
  status          VARCHAR(20) NOT NULL,    -- 'open','frozen','closed'
  created_at      TIMESTAMP NOT NULL,
  UNIQUE (account_type, owner_id, asset)
);

-- Transactions: the unit-of-work envelope. Wraps one or more entry pairs.
transactions (
  id              UUID PRIMARY KEY,
  operation_key   VARCHAR(120) NOT NULL,   -- caller-supplied idempotency key
  operation_type  VARCHAR(40)  NOT NULL,   -- 'deposit','withdrawal','trade','fee','transfer','reversal'
  status          VARCHAR(20)  NOT NULL,   -- 'posted','reversed' (transactions themselves are immutable;
                                           -- a reversal is a new transaction that points back)
  reverses_id     UUID,                    -- for reversing entries: link to the transaction being undone
  metadata        JSONB,                   -- order_id, blockchain_tx_hash, bank_ref, fee_tier, etc.
  posted_at       TIMESTAMP NOT NULL,
  UNIQUE (operation_key, operation_type)
);

-- Entries: the rows that actually move money. Append-only. Never updated.
entries (
  id              BIGINT PRIMARY KEY,         -- monotonic per-shard
  transaction_id  UUID    NOT NULL REFERENCES transactions(id),
  account_id      BIGINT  NOT NULL REFERENCES accounts(id),
  direction       CHAR(1) NOT NULL,           -- 'D' or 'C'
  amount          NUMERIC(38, 0) NOT NULL,    -- integer smallest-units; never float
  asset           VARCHAR(20) NOT NULL,       -- denormalized for partition pruning
  sequence_no     BIGINT  NOT NULL,           -- per-account monotonic; gap-detectable
  posted_at       TIMESTAMP NOT NULL,
  CHECK (amount > 0),
  CHECK (direction IN ('D','C')),
  UNIQUE (account_id, sequence_no)
);

-- Idempotency barrier. Stops duplicates at the door.
idempotency_keys (
  operation_key   VARCHAR(120) NOT NULL,
  namespace       VARCHAR(40)  NOT NULL,      -- 'deposit','withdrawal','trade',...
  transaction_id  UUID         NOT NULL,
  request_hash    BYTEA        NOT NULL,      -- SHA-256 of canonicalized request body
  created_at      TIMESTAMP    NOT NULL,
  PRIMARY KEY (namespace, operation_key)
);

-- Outbox for at-least-once event publication.
outbox (
  id              BIGSERIAL PRIMARY KEY,
  topic           VARCHAR(80) NOT NULL,
  partition_key   VARCHAR(80) NOT NULL,        -- usually user_id
  payload         JSONB       NOT NULL,
  created_at      TIMESTAMP   NOT NULL,
  published_at    TIMESTAMP                    -- NULL until relay marks it
);
```

### Key Schema Decisions

**No `balance` column on accounts.** Balance is a derivation: `SUM(CASE WHEN direction = normal_side THEN amount ELSE -amount END)` over the entries table for that account. A mutable balance column is the single most common ledger bug. The first thing to reject in this interview is anyone who proposes one. We can cache balance views, but the cache is never the source of truth.

**Integer amounts, explicit asset.** `NUMERIC(38, 0)` holds 38 digits of integer smallest-units, enough for `1e38` -- which is far more wei than will ever exist. The asset column tells you the denomination. Floats are banned, full stop. IEEE 754 rounding has ended ledgers before.

**`direction` plus `normal_side`.** A user funding account is debit-normal -- a deposit (a credit to the user's funding account from the user's perspective, a debit on the books because we owe them more) increases its balance. We track absolute amount and direction separately so an entry is unambiguous regardless of which side of the books you're reading.

**`sequence_no` per account.** Every account has its own monotonic counter. We can detect gaps -- a reconciliation job that sees `sequence_no` jump from 1024 to 1026 with no 1025 has uncovered a torn write or a corruption event, and that fires a page.

**`transactions` envelope.** Every business operation is one transaction containing N >= 2 entries. The transaction is the unit of "did this thing happen." A trade settlement is one transaction with four to six entries.

**Reversals, not updates.** A correction never updates the original transaction. It posts a new `transactions` row with `reverses_id` pointing back, and entries that flip the direction of every original entry. The journal stays immutable.

---

## Step 4: Core Operations -- Entries by Operation

Every operation is a small fixed pattern. Memorize these.

### Operation Matrix

| Operation | Debit | Credit | Notes |
|---|---|---|---|
| Crypto deposit (pending) | `deposit_pending[BTC]` | `user_holdings[user, BTC]` | Posted on first-confirmation; user balance is locked but visible |
| Crypto deposit (confirmed) | `exchange_omnibus[BTC]` | `deposit_pending[BTC]` | Posted when chain confirmations reach threshold; funds are now spendable |
| Fiat deposit (ACH initiated) | `deposit_pending[USD]` | `user_funding[user, USD]` | Provisional credit |
| Fiat deposit (ACH cleared) | `bank_omnibus[USD]` | `deposit_pending[USD]` | Bank settlement; funds spendable |
| Withdrawal (debited) | `user_funding[user, USD]` | `withdrawal_outbound[USD]` | Funds removed from user, queued for broadcast |
| Withdrawal (broadcasted) | `withdrawal_outbound[USD]` | `bank_omnibus[USD]` | Wire sent / chain tx broadcast; awaiting external confirmation |
| Trade settlement (taker buys BTC with USD) | `user_funding[buyer, USD]` | `exchange_omnibus[USD]` | Buyer pays fiat |
|  | `exchange_omnibus[BTC]` | `user_holdings[buyer, BTC]` | Buyer receives crypto |
|  | `exchange_omnibus[USD]` | `user_funding[seller, USD]` | Seller receives fiat |
|  | `user_holdings[seller, BTC]` | `exchange_omnibus[BTC]` | Seller delivers crypto |
|  | `user_funding[buyer, USD]` | `trading_fees[USD]` | Taker fee |
| Internal user-to-user transfer | `user_funding[from, USD]` | `user_funding[to, USD]` | Single transaction, two entries; instant |
| Fee accrual | `user_funding[user, USD]` | `trading_fees[USD]` or `custody_fees[USD]` | One pair per fee event |
| Reversal | mirror of original | mirror of original | New transaction, `reverses_id` set |

### Worked Example: Trade Settlement

Buyer `U1` matches with seller `U2` for 0.5 BTC at $30,000/BTC, with a $15 taker fee. The trade engine sends one posting request to the ledger:

```json
{
  "operation_key": "trade-1729800000-0001a",
  "operation_type": "trade",
  "metadata": { "trade_id": "T-9001", "pair": "BTC-USD", "price": "30000.00", "qty": "0.5" },
  "entries": [
    { "account": "user_funding/U1/USD",    "direction": "D", "amount": 1500000 },
    { "account": "exchange_omnibus/USD",   "direction": "C", "amount": 1500000 },
    { "account": "exchange_omnibus/BTC",   "direction": "D", "amount": 50000000 },
    { "account": "user_holdings/U1/BTC",   "direction": "C", "amount": 50000000 },
    { "account": "exchange_omnibus/USD",   "direction": "D", "amount": 1500000 },
    { "account": "user_funding/U2/USD",    "direction": "C", "amount": 1500000 },
    { "account": "user_holdings/U2/BTC",   "direction": "D", "amount": 50000000 },
    { "account": "exchange_omnibus/BTC",   "direction": "C", "amount": 50000000 },
    { "account": "user_funding/U1/USD",    "direction": "D", "amount": 1500 },
    { "account": "trading_fees/USD",       "direction": "C", "amount": 1500 }
  ]
}
```

The ledger validates: every asset's debits equal its credits within the transaction. USD debits = `1500000 + 1500000 + 1500 = 3001500`. USD credits = `1500000 + 1500000 + 1500 = 3001500`. BTC debits = `50000000 + 50000000`. BTC credits = `50000000 + 50000000`. Balanced. Commit.

Note that all amounts are integer smallest-units: USD in cents (`1500000` = $15,000), BTC in satoshis (`50000000` = 0.5 BTC). This is non-negotiable.

---

## Step 5: Idempotency and Retries

Every mutation request carries an `operation_key`. This is the most important interface contract in the system.

### Key Propagation

The key is generated at the source (the trade engine, the deposit poller, the withdrawal API) and propagated through every layer:

```
Client / upstream -> sets operation_key
        |
        v
Ledger API Gateway -> reads idempotency_keys table; on hit, returns the existing transaction without re-posting
        |
        v
Ledger Service -> wraps entire posting in one transaction; the INSERT into idempotency_keys uses ON CONFLICT DO NOTHING
        |
        v
Outbox -> the published event includes operation_key so downstream consumers also dedupe
        |
        v
External system (bank, chain, custody) -> uses operation_key as its own client-reference for the call
```

### Duplicate Detection Logic

```sql
BEGIN;

-- Step 1: Try to claim the key.
INSERT INTO idempotency_keys (namespace, operation_key, transaction_id, request_hash, created_at)
VALUES ('trade', :key, :new_tx_id, :hash, now())
ON CONFLICT (namespace, operation_key) DO NOTHING
RETURNING transaction_id;

-- Step 2: If RETURNING is empty, this is a duplicate. Look up the existing record.
-- Step 3: Compare request_hash. If different, the caller is misusing the key -> reject 409.
-- Step 4: If same, fetch and return the existing transaction without re-posting.

COMMIT;
```

The `request_hash` check is the part most people skip. If a caller reuses a key for a different request body, you must not silently overwrite or re-execute. You return a 409 and let the caller fix the bug.

### Replay Safety

Because the entire posting -- including the idempotency row, all entries, and the outbox row -- happens in one Postgres transaction, there is no window where the system can be in a half-applied state. Either the row in `idempotency_keys` exists and the entries exist and the outbox row exists, or none of them do.

The relay between outbox and Kafka is at-least-once: a message can be published twice if the relay crashes after publishing but before marking `published_at`. Downstream consumers handle this by deduping on `operation_key`. This is the right tradeoff -- exactly-once durability inside the database, at-least-once across the bus, with idempotent consumers.

---

## Step 6: Concurrency on Hot Accounts

This is the part that separates senior from staff. The exchange omnibus accounts are touched by every trade. A naive design serializes every trade in the system through one row, and you cap at maybe a few hundred TPS (Transactions Per Second).

### The Problem

```
Trade 1: UPDATE balance WHERE account_id = omnibus_USD ...
Trade 2: UPDATE balance WHERE account_id = omnibus_USD ...   -- waits
Trade 3: UPDATE balance WHERE account_id = omnibus_USD ...   -- waits
... 10K trades/sec all queued on one row.
```

But notice we do not actually update a balance row -- we insert entry rows. So row-level lock contention is on `accounts.id` only if we hold a `SELECT FOR UPDATE` against it. We need to ask: do we?

### Why You Need Some Lock

You need to enforce balance invariants. For user accounts, you must guarantee `balance >= 0` (or `>= -credit_limit`) before approving a withdrawal. For omnibus accounts, you usually do not -- the omnibus is internal-only, can transiently go negative on a saga step and rebalance, and is reconciled against the chain. So:

- **User accounts:** lock the user's row, compute the running balance from entries, validate, then write entries. Or maintain a `balance_snapshot` row protected by row lock that gets updated in the same transaction (denormalized but useful).
- **Omnibus accounts:** do not lock. Just append entries. Periodic reconciliation against the chain is the truth check.

### Sub-Account Partitioning

For the cases where you do need a lock on a hot account (rare but real -- e.g., a fee account with a daily cap), you partition the logical account into N shards:

```sql
-- Logical account: trading_fees[USD]
-- Physical accounts: trading_fees[USD][shard_0] ... trading_fees[USD][shard_63]
-- Each posting picks a shard via hash(transaction_id) % 64.
-- Aggregated balance is sum across shards.
```

This is the standard sharded-counter pattern. Sixty-four shards turns a single hot row into 64 cooler rows. The aggregate balance query becomes a `SUM` across shards, which is acceptable because fees are read on a daily/hourly cadence, not per-trade.

Sub-accounts must be invisible to the user-facing balance API: the API queries the logical account, the engine queries a shard.

### Why Not Just Use Optimistic Concurrency?

Optimistic concurrency works for low-contention rows -- `SELECT version, UPDATE WHERE version = :v`. On the omnibus account during a price move, every trade reads the same version, all but one fail, all retry, and you have a thundering herd. That is the same retry-storm pattern from inventory systems. You fix it by either (a) not requiring serialization on that row at all, or (b) sharding the row into N pieces so the contention drops by Nx. Both apply here, in different places.

---

## Step 7: Saga / Distributed Transactions

A trade settlement is local to the ledger -- one Postgres transaction, done. But a withdrawal touches the ledger, the custody service (which holds the keys and broadcasts), and possibly a fraud check. That is a saga.

### Saga Shape for a Crypto Withdrawal

```
Step 1: Ledger -- debit user_funding[user, BTC], credit withdrawal_outbound[BTC]
        Compensation: reverse if any later step fails before broadcast
Step 2: Fraud check -- async risk scoring on the withdrawal request
        Compensation: cancel the withdrawal, post reversal
Step 3: Custody -- sign and broadcast the chain transaction
        Compensation: if signing fails, post reversal. If broadcast fails, post reversal.
        After successful broadcast: the chain is now the source of truth; cannot reverse without on-chain action.
Step 4: Ledger -- on broadcast confirmation, debit withdrawal_outbound, credit exchange_omnibus
        (the user's funds have left the omnibus)
Step 5: Wait for N chain confirmations. Once confirmed, mark transaction status = 'settled'.
        At this point the operation is final. No compensation possible.
```

Each step is a separate transaction in the ledger, each with its own `operation_key` derived from the parent withdrawal_id. The orchestrator (a workflow engine like Temporal (workflow orchestration platform for durable async state machines), or a hand-rolled state machine) drives the steps.

### Compensating Entries

A compensation is not an UPDATE. It is a new transaction with `reverses_id` pointing to the transaction it undoes, and entries that flip the direction of every original entry. The original stays in the journal forever -- it happened, even though it was rolled back.

```
Original tx T1: D user_funding[U1, BTC] 50000000 / C withdrawal_outbound[BTC] 50000000
Reversal  T2: D withdrawal_outbound[BTC] 50000000 / C user_funding[U1, BTC] 50000000
              reverses_id = T1
              metadata = { reason: "fraud_check_blocked", original_op: "withdraw-..." }
```

Now `SELECT SUM(...) FROM entries WHERE account_id = user_funding[U1, BTC]` returns the user's balance correctly, and the journal is auditable: anyone can see we debited the user, then reversed because of fraud, with the reason recorded.

### When the Ledger Is the Coordinator vs a Participant

For trades, the matching engine is the coordinator and the ledger is one participant. The matching engine generates the `operation_key`, and the ledger's job is to commit-or-reject. For withdrawals, the withdrawal service is the coordinator. The ledger is rarely the coordinator -- it is the durable record of what each step did.

---

## Step 8: Reconciliation Subsystem

This is the part most candidates either skip or undersell. Coinbase's FinHub team (FinHub-Ledger — Coinbase's ledger team that interviews on this exact problem) treats reconciliation as a first-class subsystem, not a script that runs at midnight.

### The Two Reconciliation Loops

```
Loop A (continuous): chain vs ledger
  Every N seconds:
    For each crypto asset:
      ledger_omnibus_balance = SUM(entries) for exchange_omnibus[asset]
      chain_balance          = sum of UTXOs (Unspent Transaction Outputs — Bitcoin's accounting model) / account state held by our hot+cold wallets
      drift = chain_balance - ledger_omnibus_balance
      if abs(drift) > tolerance: page on-call, freeze withdrawals for that asset

Loop B (daily): bank vs ledger
  At end-of-day:
    For each fiat currency, each bank:
      ledger_bank_omnibus = SUM(entries) for bank_omnibus[currency, bank_id]
      bank_statement      = parsed feed from the bank
      drift = bank_statement - ledger_bank_omnibus
      log every line item; manual investigation on >$0.01 drift
```

### Drift Sources and Remediation

| Drift Source | Detection | Remediation |
|---|---|---|
| Confirmed deposit not yet credited (in-flight) | Tx hash present on chain, no `deposit_confirmed` entry | Wait one cycle; auto-credit if the deposit pipeline is just slow |
| Stuck pending state | `deposit_pending` entry > 24h with confirmed chain tx | Page on-call; force-credit via reversing the pending and posting a confirmed entry |
| Lost outbox event | Outbox row published, downstream missed | Replay from outbox |
| Chain reorg | Tx that was confirmed is no longer on the canonical chain | Reverse the deposit-confirmed entry; re-pend the deposit |
| Bank reversal (NACHA return) | Bank statement shows a reversal of an ACH credit we already gave the user | Reverse the deposit; if user already withdrew, we have a real loss event for risk to handle |
| Operator error | Manual entry posted incorrectly | Manual reversing transaction by treasury operator with audit trail |

### Why Reconciliation Has to Be Continuous

If reconciliation runs only at end-of-day, drift accumulates for hours. By the time you find a discrepancy, you may have credited dozens of deposits that did not actually arrive, and users have already traded those phantom funds. Continuous reconciliation -- every few minutes -- bounds the blast radius. The faster you detect drift, the smaller the window of bad behavior you have to clean up.

### Auto-Heal vs Manual Heal

Auto-healing is acceptable for known-safe drift patterns (in-flight deposits being slow). Auto-healing is not acceptable for unknown drift -- if you do not know why the chain says you have less than the ledger says you do, you do not paper over it with an adjusting entry. You freeze and investigate. The safest default is "alert humans, freeze withdrawals for the affected asset." Reckless auto-heal is how you launder a bug into a balance sheet.

---

## Step 9: State Machines for Pending Operations

Long-running operations like deposits and withdrawals do not have a single "happens" moment. They have a pipeline. Each transition is one journal transaction.

### Crypto Deposit Pipeline

```
[detected on chain, 0 confs]
        |
        v
[1 conf]  -- post pending entry  (D deposit_pending / C user_holdings)
        |   user sees a pending balance, cannot withdraw or trade with it
        v
[N confs] -- post confirmation entry (D exchange_omnibus / C deposit_pending)
        |   funds are spendable
        v
[settled]
```

The "user_holdings" account is credited at the pending stage, but a flag on the account or a check at withdrawal time prevents withdrawal of unsettled funds. Some teams instead use a separate `user_holdings_pending` account; either works. The key is the user balance display includes pending, but the spend invariant excludes pending.

### Withdrawal Pipeline

```
[user submits withdrawal]
        |
        v
[risk check + balance check + spending limit check]  -- if any fail, reject. No journal entry.
        |
        v
[debited]  -- D user_funding / C withdrawal_outbound
        |   funds removed from user, in our internal "to-broadcast" bucket
        v
[signed]   -- no journal change; custody state machine update
        |
        v
[broadcasted]  -- D withdrawal_outbound / C exchange_omnibus
        |   we have a tx hash; chain is now responsible
        v
[N confs]  -- mark settled in metadata; no balance change
```

The withdrawal pipeline is slow on purpose -- between debited and broadcasted, the funds are in a "no man's land" account (`withdrawal_outbound`) so reconciliation knows we are mid-broadcast. If the system crashes, recovery looks at `withdrawal_outbound` entries with no matching broadcast, retries the broadcast (idempotent on the operation_key), and either completes the cycle or reverses if final-failure.

### Spending Limit Enforcement

Spending limits are checked at the ledger boundary inside the same transaction that posts the debit. This is the only correct place. Checking in the API layer leaves a TOCTOU race; a user could open two browser tabs, hit submit on both, and bypass the check.

```sql
BEGIN;
  -- Lock user's withdrawal-limit aggregator row
  SELECT * FROM withdrawal_limits
  WHERE user_id = :u AND asset = 'BTC' AND day = current_date
  FOR UPDATE;

  -- Check
  IF withdrawn_today + :amount > daily_limit THEN
    ROLLBACK; -- caller gets 429 / limit_exceeded
  END IF;

  -- Post entries
  INSERT INTO entries ...;
  -- Update aggregator
  UPDATE withdrawal_limits SET withdrawn_today = withdrawn_today + :amount ...;
COMMIT;
```

The aggregator row is per-user-per-asset-per-day, so contention is bounded.

---

## Step 10: Sharding and Scaling

Single Postgres handles the early years. The forcing function for sharding is write throughput, not data size.

### When to Shard

A single tuned Postgres can handle ~10K writes/sec sustained, more in bursts. The ledger's write rate is `entries_per_second`, which for a busy trade settlement is 6-10 entries per trade. At 10K trades/sec, you are inserting 60K-100K entries/sec, which exceeds a single primary. So you shard.

### Shard Key

**Shard by `user_id`.** This is the right answer and the question is whether you can defend it.

Why `user_id`:
- All user-level invariants (balance >= 0, daily limits, cost basis) live within one shard. No cross-shard transactions needed for most operations.
- Reconciliation per user is local.
- Compliance queries ("show all activity for user X") are single-shard.

What breaks:
- Internal accounts (omnibus, fees) are touched by every shard. They must be replicated or housed in a system-shard that all writes coordinate with.
- Trade settlement involves two users on potentially different shards. This is now a cross-shard transaction.

### Cross-Shard Trade Settlement

Two options:

1. **Two-phase commit across shards.** Postgres supports prepared transactions (`PREPARE TRANSACTION` / `COMMIT PREPARED`). It is operationally painful (long-running prepared txns can lock resources) but tractable for a small number of shards.
2. **Saga with reversing entries.** Post the buyer-side entries on shard A, post the seller-side entries on shard B, both within the same `operation_key`. If shard B fails, reverse shard A. The saga orchestrator (the matching engine that drove the trade) handles the compensation. The trade's `operation_key` is the dedup boundary on both shards.

Saga is the better answer at scale. 2PC is fragile; sagas with idempotent posting and reversing entries are operationally clean.

### Internal Accounts in a Sharded World

The `exchange_omnibus`, `trading_fees`, `bank_omnibus` accounts cannot live on one shard if every shard's writes touch them. Two patterns:

1. **One shard per asset for omnibus.** Shard `omnibus_btc` is one Postgres; shard `omnibus_usd` is another. Each is hot for its asset but only its asset.
2. **Sub-account partitioning** (Step 6). The logical `exchange_omnibus[USD]` is N physical accounts spread across shards; balance is a sum across them. A trade picks a shard for its omnibus posting based on `hash(operation_key) % N`.

Pattern 2 is what FinHub uses in practice. It composes with user-shard partitioning: the omnibus shards and the user shards are independent dimensions, and a trade settlement writes to one user-shard for the buyer, one for the seller, and one omnibus-shard each for USD and BTC.

### Vertical and Read Scaling

Before sharding, exhaust vertical scaling:
- Move to NVMe-backed storage for fsync latency
- Tune `wal_buffers`, `checkpoint_timeout`, `max_wal_size`
- Increase `shared_buffers` to 25-40% of RAM
- Pre-create partitions on the entries table by month

Read scaling: synchronous replicas in the same region, asynchronous replicas in DR. Most balance reads come from a recent-balance cache (Redis) backed by entries, with cache invalidation tied to outbox events.

---

## Step 11: Outbox Pattern and Event Stream

You cannot reliably do "DB commit, then publish to Kafka." Crash between the two and the event is lost; the system says the trade happened but no downstream knows. The fix is the outbox pattern.

### Mechanics

```
BEGIN;
  INSERT INTO transactions ...;
  INSERT INTO entries ...;
  INSERT INTO idempotency_keys ...;
  INSERT INTO outbox (topic, partition_key, payload) VALUES ('ledger.posted', :user_id, :json);
COMMIT;
```

A separate relay process (one per shard) tails the outbox table -- either by polling for `published_at IS NULL`, or via logical decoding (Postgres replication slot / Debezium (open-source CDC tool that tails MySQL binlog / Postgres WAL)). It publishes to Kafka, then sets `published_at`. If the relay crashes between publish and update, the event publishes again on restart. Downstream is idempotent on `operation_key`.

### CDC vs Explicit Outbox

CDC (Change Data Capture — turning DB row changes into an event stream) via Debezium reading the WAL (Write-Ahead Log — append-only durability log written before in-memory mutation) is cleaner -- no application code change, no extra table. But it locks you into "every committed row is an event," which is too noisy and leaks schema details. The explicit outbox lets you shape the event payload (denormalized, versioned) and emit only what downstream needs. For a ledger this matters because a trade is one logical event, not eight row inserts.

Use explicit outbox. If you want both, run Debezium for analytics-grade cold storage and explicit outbox for downstream services.

### Downstream Consumers

```
Topic: ledger.posted (partitioned by user_id)
  |
  +--- Tax / Cost Basis Engine: builds per-user lot tables
  |
  +--- Compliance Pipeline: SAR detection, sanctions screening
  |
  +--- Notifications: push notifications, emails on deposit/withdrawal
  |
  +--- Analytics Warehouse: hydrates the OLAP (Online Analytical Processing — analytics warehouse) store for revenue dashboards
  |
  +--- Search Indexer: per-user transaction search
```

Each consumer group reads at its own pace, can rewind for backfills, and cannot affect the ledger primary. Lag on any consumer is operational, not correctness-affecting.

---

## Step 12: Cost Basis and Tax Lots

The IRS requires tracking the cost basis of every crypto asset for capital gains. The ledger is the source of truth that the cost-basis engine consumes from.

### Lot Model

Every acquisition (buy, deposit-from-external) creates a lot:

```sql
tax_lots (
  id              BIGINT PRIMARY KEY,
  user_id         BIGINT NOT NULL,
  asset           VARCHAR(20) NOT NULL,
  acquired_at     TIMESTAMP NOT NULL,
  quantity_acquired NUMERIC(38, 0) NOT NULL,
  quantity_remaining NUMERIC(38, 0) NOT NULL,
  cost_basis_usd  NUMERIC(38, 8) NOT NULL,    -- in USD smallest-unit per asset smallest-unit
  source_transaction_id UUID NOT NULL REFERENCES transactions(id)
);

tax_lot_consumptions (
  id              BIGINT PRIMARY KEY,
  lot_id          BIGINT NOT NULL REFERENCES tax_lots(id),
  consuming_transaction_id UUID NOT NULL REFERENCES transactions(id),
  quantity_consumed NUMERIC(38, 0) NOT NULL,
  proceeds_usd    NUMERIC(38, 8) NOT NULL,
  realized_pnl_usd NUMERIC(38, 8) NOT NULL,
  consumed_at     TIMESTAMP NOT NULL
);
```

### Lot Selection Methods

A disposal (sale, withdrawal, transfer-out) consumes from existing lots. The user picks the strategy:

- **FIFO (default):** consume oldest lots first. Highest realized gains in a bull market.
- **LIFO:** consume newest first. Often lower realized gains in a bull market.
- **HIFO:** consume highest-cost-basis first. Minimizes realized gains. Tax-optimal.
- **Specific identification:** user picks specific lots per transaction.

The cost-basis engine processes ledger events in order and writes consumption records. It is always derivable from the journal -- you can rebuild lots from scratch by replaying the journal.

### Why Cost Basis Lives Downstream

The cost-basis engine is a projection consumer. It is not on the ledger write path because (a) the calculations are not balance-affecting, (b) users can change their selection method retroactively for unsold lots, and (c) keeping it separate means cost-basis bugs can be reprocessed without touching the journal. The journal is unconditionally correct; cost-basis is a derived view we can rebuild any time.

### 1099 Generation

End-of-year, the tax engine emits 1099-MISC and 1099-B (US IRS tax-reporting forms — miscellaneous income and brokerage proceeds, respectively) records per user. These are themselves immutable and stored in the compliance pipeline. Corrections issue amended 1099s rather than overwriting.

---

## Step 13: Audit, Compliance, Retention

Seven years of every entry, immutable, queryable. Non-negotiable.

### Storage Tiers

```
Hot (last 18 months):  Postgres primary + replicas. Sub-100ms queries.
Warm (1.5 - 3 years):  Postgres archive shards or S3-backed (with Athena/Trino for query).
Cold (3 - 7+ years):   Compressed Parquet in S3 Glacier. Queryable via batch jobs only.
```

The journal is partitioned by `posted_at` month. Old partitions move to warm storage, then to cold, on schedule. The schema is identical; it is just where the bytes live.

### Immutability Guarantees

Database-level: revoke UPDATE and DELETE on the entries and transactions tables for the application role. Only INSERT. Schema migrations and operational corrections require a separate role with audit logging and a four-eyes approval.

S3-level: object lock with retention policy. Once written, S3 will not allow deletion until the policy expires (7 years). This is what "immutable" means in cloud storage.

### Query Patterns for Audit

- **SAR (Suspicious Activity Report):** "Show all transactions for user X within date range Y" -- single user, single shard, time-range scan on the entries partitioned table.
- **IRS audit:** "Show all activity for asset Z across all users" -- cross-shard aggregation; runs on the warehouse, not the OLTP (Online Transaction Processing — live application database) store.
- **Internal investigation:** "Trace this $X drift in our reconciliation" -- joins entries with transactions and metadata; supported by indexes on `operation_key`, `metadata->>'order_id'`, etc.

### Replayability

A core property: any user's history can be recomputed from the journal. The balance, the lot list, every report -- all derivations of the entry stream. If the cost-basis engine has a bug, you wipe its state and replay. If the analytics pipeline goes wrong, you replay. The journal never replays; it is the source.

This is the whole point of append-only design. Mutability would forever break replay.

---

## Step 14: Failure Modes

What breaks, how you detect it, what you do.

### Primary Postgres Failover

- Synchronous replica in the same region acts as standby. Patroni or RDS Multi-AZ handles election.
- Failover is sub-30s. RPO (Recovery Point Objective — DR target for maximum acceptable data loss) = 0 because synchronous replication acks before the primary commits.
- During failover: writes 503. Clients retry with the same `operation_key`. On retry, the new primary either has the row already (idempotent, returns existing) or accepts the write fresh.

### Torn Write / Partial Commit

A torn write -- a row partially written before crash -- is impossible inside Postgres because the WAL is fsynced before commit ack. Torn writes only happen with weaker durability settings or non-ACID stores. This is one of the strongest reasons to keep Postgres for the ledger.

If you ever see a gap in `sequence_no` per account, that is corruption. The reconciliation job pages on-call. Recovery is a point-in-time restore from backup plus replay of subsequent traffic from the WAL or outbox.

### Partial Saga Completion

A saga that has done step 1 and step 2 of 3 when step 3 fails: the orchestrator fires compensation in reverse order. Each compensation is a reversing transaction with its own idempotency key. If the compensation itself fails, it retries. If it cannot succeed, the saga is in a manual-resolution state -- on-call gets paged, the operations team posts the reversing entries by hand with audit metadata.

The crucial property: the journal always reflects what actually happened, including failed sagas. There is no "this saga half-completed; balance is undefined" state -- every step that ran is recorded, every compensation is recorded.

### Outbox Relay Outage

The relay falls behind. Outbox rows accumulate. The DB does not slow down -- writes still commit, the outbox is just a table. Downstream consumers stop receiving events.

Mitigation: the relay is replicated with leader election. Lag is monitored; alert at >30 seconds. On extended outage, a backfill process can re-publish from the outbox after the relay recovers -- consumers dedupe.

### Kafka Outage

Outbox keeps growing until Kafka is back. Once Kafka recovers, the relay drains. Downstream consumers see a burst of events; they should be sized to handle this (consumer lag bounded by topic retention, typically 7 days).

### Replica Lag

Synchronous replica falls behind during a write burst -- this should not happen if sized correctly, but it does. Reads routed to the replica may return stale balances. Solution: route critical reads (balance check at withdrawal time) to the primary; route display reads (account history pagination) to the replica.

### Multi-Region

Synchronous replication within region (low-latency, RPO = 0). Asynchronous replication to DR region (RPO = seconds). For DR failover, write traffic moves to the new region. There is a small data loss window equal to the replication lag at the moment of the disaster. This is the standard tradeoff -- synchronous cross-region replication doubles write latency on every commit, which is unacceptable for ledger throughput.

Some teams build active-active with conflict resolution. For a financial ledger, active-active is a bad fit -- conflict resolution on monetary entries is dangerous. Active-passive with documented RPO is the right answer.

---

## Step 15: Tradeoffs Summary

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Storage engine | PostgreSQL | Custom log-structured DB; Cassandra; DynamoDB | ACID transactions are non-negotiable for journal pairs; Postgres delivers them with mature operational tooling |
| Balance representation | Derived from entries | Mutable balance column | Mutable balance is the #1 ledger bug source; immutability is the whole point |
| Money representation | Integer smallest-unit + asset code | Floats; decimal types | Floats round; mismatched-asset bugs hide in implicit currency |
| Sharding | By `user_id`, with sub-accounted internals | Sharding by transaction time; not sharding | User-level invariants stay local; internals are sharded separately to avoid hot rows |
| Cross-shard transactions | Saga with reversing entries | 2PC; single global shard | Saga is operationally clean; 2PC is fragile; single shard does not scale |
| Idempotency | Caller-supplied key + dedup table inside DB transaction | At-most-once with retries; consensus | Idempotency is the only design that survives every retry path simply |
| Event publication | Outbox + relay -> Kafka | Direct Kafka publish post-commit | Direct publish has a dual-write loss window; outbox is at-least-once with no loss |
| Reconciliation | Continuous, every minute | Daily batch | Bounds drift blast radius; catches issues before users transact on phantom funds |
| Replication | Sync intra-region, async cross-region | Sync cross-region; async intra-region | Sync intra-region gives RPO=0; async cross-region keeps write latency tolerable for DR |
| Cost basis | Downstream projection from journal | In-line on the write path | Replayable, evolvable, decoupled; ledger stays focused on correctness |
| Retention | Hot (Postgres) + warm (S3) + cold (Glacier) | Postgres forever | 7 years of journal in a single Postgres is operationally ruinous; tiering by age is standard |

---

## Step 16: Common Mistakes to Avoid

1. **Using a mutable `balance` column as the source of truth.** This is the most common ledger bug in the industry. The moment you write `UPDATE accounts SET balance = balance + :amount`, you have created a system where bugs silently produce wrong balances and you cannot reconcile because there is no audit of how the balance got there. The journal is the source; balance is a SUM. Reject this in any candidate's design.

2. **Floats for money.** IEEE 754 cannot represent 0.1 exactly. `0.1 + 0.2 != 0.3`. Every floating-point operation accumulates error. Banks have lost millions to this; crypto exchanges have too. Integer smallest-unit is the only correct representation, full stop.

3. **No idempotency keys, "we'll handle retries with at-most-once."** At-most-once means you sometimes lose transactions. In a financial ledger, "sometimes lose" is unacceptable. Idempotency keys + at-least-once delivery + dedup-on-receipt is the only safe combination.

4. **No reconciliation, "the ledger is authoritative so it must be right."** The ledger is authoritative for what we recorded. The chain and the bank are authoritative for what actually moved. If they disagree, something is wrong, and only continuous reconciliation finds it. Without recon, drift compounds invisibly until someone with $100K in phantom funds withdraws them.

5. **Event-sourcing the entire system because it sounds elegant.** Append-only journal is event-sourcing-adjacent, but full event sourcing -- where every state change everywhere is an event and current state is rebuilt from event replay -- is overkill for the user-facing balance lookup. Use it where it pays for itself (the journal). Do not use it for cached projections, configurations, or anywhere read latency matters.

6. **Locking the omnibus account on every trade.** Tens of thousands of trades serializing through one row caps your throughput. Either do not lock the omnibus (it is internal, reconciled against chain) or sub-account-partition it.

7. **Skipping the outbox.** "Commit, then publish" is dual-write. It loses events on crash. Use outbox + relay every time.

8. **Auto-healing unknown drift.** If reconciliation finds a discrepancy and you do not know why, posting an adjusting entry hides the bug. Freeze, page, investigate, then post a manual correction with an audit trail. Auto-heal is for known-safe patterns only.

9. **Sharding too early.** Single-Postgres works to many tens of thousands of writes/sec with NVMe. Premature sharding adds operational complexity and cross-shard sagas. Vertical scale first; shard when you have measured evidence.

10. **Treating compliance retention as an afterthought.** Seven years of immutable storage with query support has to be designed in -- table partitioning, S3 lifecycle, role-based access. Retrofitting it after launch is painful.

---

## Step 17: Follow-up Questions

These are the questions a Coinbase interviewer probes after the main design. Have an answer for each.

### How do you migrate the ledger to a new currency?

Adding a new asset (a new ERC-20 token, say) is straightforward: create the asset metadata row with its decimals, create the omnibus accounts, configure the deposit/withdrawal pipelines and the chain reconciler. No journal migration -- new entries reference the new asset code; existing entries are untouched.

The hard variant is changing the smallest-unit decimals of an existing asset. This should never happen on real assets. If it does -- e.g., a token contract changes -- you treat it as a token migration: the old asset is delisted, the new asset is listed, and a per-user migration transaction (with a new operation_type `asset_migration`) atomically debits the old asset and credits the new one.

### How do you handle a fork that retroactively splits an asset?

A hard fork (BTC -> BTC + BCH at a specific block height) creates a new asset for users who held the original at the snapshot moment. The ledger does not retroactively rewrite history -- the existing BTC entries stay BTC entries. Instead, at the fork height, a `fork_grant` transaction posts: D `fork_distribution_account[BCH]` / C `user_holdings[user, BCH]` for every user holding BTC at the snapshot. The fork_distribution_account is funded by the chain itself (the new asset exists out of thin air for holders).

### How do you re-derive a user's history from the journal?

Run a query: `SELECT * FROM entries WHERE account_id IN (user's accounts) ORDER BY posted_at, sequence_no`. Group by transaction_id; join to transactions for context. This returns every movement; the running balance is a cumulative sum. Cost basis lots are reconstructed by replaying the same stream through the cost-basis logic. This is the explicit goal of append-only -- the entire user state is derivable from the journal at any time, including for any historical date.

### How would the system support real-time balance subscriptions for the trading UI?

The outbox -> Kafka -> WebSocket fan-out pattern. A websocket service subscribes to the ledger.posted topic, filters by user_id, and pushes balance deltas to connected clients. The client maintains a balance counter starting from a snapshot fetched at connection time. This is eventually consistent with a small lag (sub-second), which is acceptable for UI; the actual write path remains the ledger.

### What about chargebacks and ACH returns?

A bank can reverse an ACH credit days after the fact. We get a NACHA return file. The ledger posts a reversing transaction: the original deposit-confirmed entry is reversed, plus a debit to a `chargeback_loss` account if the user has already withdrawn the funds. The user's balance can go negative; risk handles collection. The journal records the truth; recovery is a business problem, not a ledger problem.

---

## Closing Note

The Coinbase FinHub-Ledger team's mandate is correctness above all. In an interview for that team, the highest signals are: leading with double-entry and append-only, treating reconciliation as a first-class subsystem, naming idempotency keys explicitly across every boundary, and refusing to compromise ACID guarantees on the write path for throughput gains. If you find yourself proposing a design where balance is a mutable cell, where retries can double-credit, or where the chain and the books are reconciled "eventually" with no detection, stop and re-plan. A staff-level ledger design earns trust by being boring in all the right places: ACID, immutable, idempotent, reconciled.
