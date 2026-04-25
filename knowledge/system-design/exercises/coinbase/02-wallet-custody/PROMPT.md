# Exercise: Design Coinbase's Wallet Custody Architecture

## Prompt

Design the wallet custody architecture for a regulated crypto exchange like Coinbase that holds tens of billions of dollars of customer assets. The system must keep ~98% of customer crypto in air-gapped cold storage, support fast retail withdrawals from a hot tier, and pass institutional-grade audits. No single human -- including a compromised insider -- should be able to move customer funds.

## Requirements

### Functional Requirements
- Three-tier custody model: hot (operational liquidity), warm (programmatic withdrawals), cold (long-term storage)
- Per-asset address generation for deposits (BTC, ETH, ERC-20, Solana, others)
- Withdrawal request pipeline: request -> risk -> policy -> sign -> broadcast -> confirm
- HSM-backed signing for hot tier; MPC threshold signing for warm tier; multi-sig + air-gap for cold tier
- Deposit pipeline: block scan -> confirmation watcher -> credit ledger
- Address screening (OFAC, sanctions, on-chain risk) on every outbound transfer
- Quorum-based promotion ceremonies for cold-to-warm refills
- Audit log for every key operation, immutable and time-locked

### Non-Functional Requirements
- Zero loss of customer funds across any single point of compromise
- ~98% of assets in cold storage at any given time (regulatory and insurance requirement)
- Hot withdrawals settle within minutes; cold withdrawals within hours-to-days
- Per-withdrawal limits ($10K) and daily velocity caps enforced server-side
- Defense-in-depth: a hot-key compromise alone must not produce loss
- Insider-resistant: no single human can move funds; quorum + cooling-off
- Reorg-aware deposits: do not credit until confirmation thresholds are met
- SOC 2, NYDFS BitLicense, and qualified-custodian audit posture

### Out of Scope (clarify with interviewer)
- Trading engine and order matching ([[../12-coinbase-trading-engine/PROMPT|exercise 12]])
- Financial ledger / double-entry accounting ([[../14-coinbase-financial-ledger/PROMPT|exercise 14]])
- KYC onboarding flow ([[../19-coinbase-kyc-onboarding/PROMPT|exercise 19]])
- DeFi staking, lending, governance
- Smart contract auditing for listed tokens
- Tax reporting and 1099 generation

## Constraints
- Mixed retail and institutional customer base; institutions have separate Vaults and signing policies
- 200+ supported assets across 30+ chains with different finality models
- Regulated as a money services business; SAR / Travel Rule / OFAC compliance is non-negotiable
- $320M crime insurance policy bounds the underwriter's tolerance for any single loss event
- Qualified custodian for spot BTC and ETH ETFs -- audit failure has existential business impact
- Adversaries include external attackers, insiders, supply-chain implants, and "$5 wrench" coercion of a single signer

## Key Topics Tested
- [[../../../security-and-compliance/index|Security & Compliance]] -- HSM, MPC, multi-sig, segregation of duties, OFAC
- [[../../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- threshold recovery, HSM lifecycle, key rotation
- [[../../../distributed-systems-fundamentals/index|Distributed Systems]] -- threshold signing, consensus across signers
- [[../../../scaling-writes/index|Scaling Writes]] -- idempotent withdrawals, exactly-once broadcast
- [[../../../async-processing/index|Async Processing]] -- block scanners, confirmation watchers, ceremony queues
