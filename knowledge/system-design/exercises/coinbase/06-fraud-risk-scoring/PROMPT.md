# Exercise: Design a Real-Time Fraud Detection / Transaction Risk Scoring System (Coinbase)

## Prompt

Design Coinbase's real-time risk scoring platform -- the system that scores every deposit, withdrawal, trade, and account action for fraud, AML, and sanctions risk before the action is permitted to proceed. Score must return in under 250ms end-to-end so the user-facing path is not blocked. Outputs feed an action layer that decides whether to allow, hold, rate-limit, or queue for manual review. The system must learn continuously from labeled outcomes (chargebacks, confirmed account takeovers, SAR filings, customer disputes) and stay defensible under regulator audit.

## Requirements

### Functional Requirements
- Real-time risk scoring for four action classes: deposit, withdrawal, trade, account-action (login, 2FA change, password reset, address book add)
- Streaming feature pipeline that materializes user, device, address, and behavioral features
- Online feature store for sub-50ms feature lookup at decision time
- Sequence features (recent action history) feeding LSTM / Transformer behavior models
- Address risk scoring on the blockchain address graph (Node2Vec or GNN) for outbound destinations
- AML / sanctions integration: OFAC screening, Chainalysis / Elliptic blockchain analytics
- Decision layer that combines model score with policy rules and produces an action
- Manual review queue with case management for ambiguous cases
- Audit trail: every score, decision, and action recorded immutably with model version and feature snapshot
- Feedback loop: labeled outcomes flow back into training data and online metrics

### Non-Functional Requirements
- Sub-250ms p99 end-to-end (event ingest to decision returned)
- Sub-150ms p99 for stateless feature lookup; sub-250ms for stateful streaming features
- Sub-50ms feature store read latency
- Online / offline feature parity above 98% (training-serving skew bounded)
- 99.99% availability on the scoring path; degrade to rule-based fallback on model service outage
- Explainability: SHAP-style attribution for any score that triggers a block or hold
- Regulatory retention: 7 years for SAR-relevant decisions, immutable audit log

### Out of Scope (clarify with interviewer)
- Model training infrastructure (separate ML platform; this design consumes the trained artifact)
- Identity verification / KYC document review (separate onboarding system; consumed as a feature)
- Customer support tooling for dispute resolution beyond the manual review queue
- Long-form financial crime investigation workflow (separate compliance team tooling)
- Tax reporting and 1099 generation

## Constraints
- Action volume: tens of thousands of trades per second peak, hundreds of thousands of account actions per second
- Decisions affect billions of dollars in flow; false positives cause customer pain, false negatives cause compliance breach and direct loss
- Adversarial environment: attackers actively probe the system, including timing and rate-based oracle attacks
- Regulatory regime: BSA, OFAC, FinCEN Travel Rule (>$3K), SAR threshold ($10K aggregate daily), MSB licensing per jurisdiction
- Multi-region: US, EU, UK, APAC each have local data residency and reporting requirements
- Feature recency: stateful features must reflect events from the last few seconds, not the last few minutes

## Key Topics Tested
- [[../../../07-real-time-systems/index|Real-Time Systems]] -- streaming feature pipelines, RocksDB-backed state, Spark RTM / Flink
- [[../../../02-scaling-reads/index|Scaling Reads]] -- online feature store hot lookups, tiered caching for address features
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- model service degradation, fail-open vs fail-closed policy
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- training-serving skew, dual-write feature pipelines, exactly-once feedback
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- DynamoDB online store, Lakebase Postgres serving layer, immutable audit log
- [[../../../05-async-processing/index|Async Processing]] -- label feedback, batch graph embedding refresh, manual review queue
