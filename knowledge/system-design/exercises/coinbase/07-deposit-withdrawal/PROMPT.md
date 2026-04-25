# Exercise: Design the Deposit and Withdrawal Pipeline (Coinbase)

## Prompt

Design the deposit and withdrawal pipeline for a crypto exchange like Coinbase. This is the operational seam between blockchain state and the internal ledger -- the system that detects user deposits across many chains, credits accounts at the right confirmation count, and executes withdrawals safely (sign, broadcast, confirm, settle). It must handle reorgs, RBF (replace-by-fee), mempool stalls, signer outages, and every other operational pathology that comes from interfacing with a permissionless network. This is where most production incidents at a crypto exchange happen.

## Requirements

### Functional Requirements
- Multi-chain deposit detection: Bitcoin, Ethereum, Solana, Polygon, plus a long tail of EVM and non-EVM chains
- Deposit state machine: detected -> pending_confirmations -> confirmed -> credited -> settled, with explicit reorg states
- Per-chain (and per-amount) confirmation policy, configurable per asset
- Withdrawal state machine: requested -> debited -> risk_passed -> policy_passed -> unsigned -> signed -> broadcast -> confirmed -> settled, with failure and recovery branches
- Policy gates as a separate stage: balance, withdrawal allowlist (48-hour wait), velocity limits, 2FA, OFAC sanctions, Travel Rule (>$3K originator/beneficiary info), fraud score
- Signing service interaction across hot (HSM), warm (MPC -- Multi-Party Computation), and cold tiers (multi-sig ceremony)
- Mempool management: RBF (Bitcoin replace-by-fee), ETH gas escalation, stuck-tx detection, nonce ordering
- Batch withdrawals: combine multiple users' outputs into a single on-chain tx to save fees, with fairness and partial-failure handling
- Cold-tier replenishment when hot wallet drops below threshold
- End-to-end idempotency: client request_id -> internal correlation_id -> chain txid, replay-safe at every stage
- Continuous reconciliation: chain state vs ledger; drift detection with auto-remediation thresholds
- Operational tooling: dashboards, manual ops console, kill-switch for withdrawals

### Non-Functional Requirements
- Zero double-credits and zero double-debits under any failure mode
- Reorg-safe: a confirmed deposit that gets reorged must be reversed without leaving phantom credits or duplicate credits on re-emit
- Withdrawal exactly-once on chain: never sign two transactions for the same withdrawal request
- Deposit detection latency target: under 30 seconds from block ingestion to "pending" state for the user
- Crediting latency: at the per-chain confirmation count (e.g., 3 blocks BTC small, 12 blocks ETH, finality on Solana)
- Withdrawal acknowledgment under 5 seconds; broadcast under 60 seconds for hot-tier requests
- 99.99% pipeline availability; chain RPC failover with no observable user impact
- Audit trail: every signing decision, broadcast attempt, and confirmation event is immutable

### Out of Scope (clarify with interviewer)
- The financial ledger itself (separate system; this pipeline writes journal entries via the ledger API)
- Custody key management internals (this system calls signing as a service)
- KYC / onboarding (the user is already verified before reaching this pipeline)
- Trading and matching (separate system)
- Tax reporting (downstream consumer of settled events)
- The mobile / web client UI

## Constraints
- Blockchains are eventually consistent and adversarial; reorgs are normal events, not exceptions
- Signers are external systems with their own SLAs and failure modes
- Mempool state is non-deterministic and can drop transactions; rebroadcast and replacement are required
- Hot wallets are size-capped (e.g., $10K-equivalent per BTC hot tier) to limit blast radius
- Floats are forbidden; all amounts are integer smallest-units (satoshi, wei, lamport) with explicit asset code

## Key Topics Tested
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- saga pattern, idempotency keys, exactly-once via state machines
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- reorg handling, partial-state recovery, signer failover
- [[../../../05-async-processing/index|Async Processing]] -- pipeline orchestration, outbox relay, mempool watchers, confirmation tailers
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- append-only state-transition log, ACID for ledger writes
- [[../../../03-scaling-writes/index|Scaling Writes]] -- nonce sequencing per hot wallet, batched withdrawals, hot-row contention
