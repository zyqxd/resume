# Exercise: Design a Financial Ledger Service (Coinbase)

## Prompt

Design the financial ledger service for a crypto exchange like Coinbase. The system is the authoritative record of every cent and every satoshi the company holds on behalf of every user. It must record deposits, withdrawals, internal transfers, trade settlements, and fee accruals using strict double-entry bookkeeping, never lose a transaction, never permit balance drift between the internal books and the external sources of truth (banks for fiat, blockchains for crypto), and remain queryable for audit, compliance, and tax purposes for at least seven years.

This is the signature design question for the Coinbase FinHub-Ledger team.

## Requirements

### Functional Requirements
- Double-entry, append-only journal: every transaction is two equal-and-opposite entries; nothing is ever updated or deleted
- Multi-asset, multi-currency: USD, USDC, BTC, ETH, and hundreds of other assets, each tracked in integer smallest-units (cents, satoshis, wei)
- Operation coverage: fiat/crypto deposits, withdrawals, internal user-to-user transfers, trade settlements (debit funding, credit holdings, debit fees), fee accruals, rebates, and corrections via reversing entries
- State-machine-driven pending operations: deposit pipeline (pending -> confirmed -> credited), withdrawal pipeline (requested -> debited -> signing -> broadcasted -> confirmed -> settled)
- End-to-end idempotency: a single client-supplied operation key is propagated through API, ledger, and external systems so any retry is exact-once
- Reconciliation against external sources of truth: continuous diffs of ledger vs blockchain UTXO/account state and ledger vs bank statements; automated drift detection
- Spending controls enforced inline: per-user per-day per-asset withdrawal caps that fail closed
- Cost basis tracking: per-user lot accounting (FIFO/LIFO/HIFO selectable) for tax reporting (1099-MISC, 1099-B)
- Downstream event emission for analytics, tax, compliance, and notifications via outbox + event stream

### Non-Functional Requirements
- Strong consistency on the write path; ACID transactions for every journal entry pair
- Zero tolerance for unbalanced journals: sum of every transaction must be zero across all involved accounts
- Exactly-once semantics under retries (client retries, internal retries, message broker redelivery)
- Tens of thousands of journal-entry pairs per second steady-state, 10x bursts during market events
- Multi-region durability: synchronous replication within a region, asynchronous to a DR region, RPO measured in seconds
- 7-year immutable retention for every entry, queryable for SAR (Suspicious Activity Reports) and IRS audits
- Sub-100ms p99 for the user-visible balance read path
- Reconciliation drift detected within minutes for crypto, within one banking day for fiat

### Out of Scope (clarify with interviewer)
- The order matching engine (separate system; the ledger is downstream of the matcher)
- Custody / hot-and-cold wallet key management (separate system; the ledger sees signed-and-broadcasted as a state transition)
- KYC and onboarding (separate system; the ledger trusts the user_id is real)
- Pricing / mark-to-market and PnL calculation (the ledger records cost basis; PnL is a downstream view)
- Fraud scoring (a hook point on deposits and withdrawals)

## Constraints
- Two independent sources of truth must reconcile: the internal ledger, the blockchain (for crypto), and bank statements (for fiat)
- The exchange omnibus accounts (shared on-chain wallets holding many users' crypto) are the hottest write rows in the system
- Sagas span the ledger plus other services (custody, payments, trading); compensating entries must be possible
- 7-year retention with immutability is a regulatory requirement, not an option
- Floats are forbidden everywhere; all amounts are integer smallest-units plus a currency code

## Key Topics Tested
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- ACID, append-only design, partitioning vs sharding, replication
- [[../../../03-scaling-writes/index|Scaling Writes]] -- hot-account contention, sub-account partitioning, idempotent writes
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- saga pattern, exactly-once via idempotency keys, outbox pattern
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- failover, torn-write recovery, reconciliation as drift detection
- [[../../../05-async-processing/index|Async Processing]] -- pending-state pipelines, outbox relay, reconciliation jobs
