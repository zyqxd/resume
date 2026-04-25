# Exercise: Design an Account Opening and KYC/AML Onboarding Workflow (Coinbase)

## Prompt

Design Coinbase's account opening and KYC/AML onboarding workflow -- the system that takes a new applicant from email signup through identity verification, sanctions screening, risk-based decisioning, and tier assignment in 100+ jurisdictions. Millions of new applications per year, half-finished applications are the norm, every step has regulatory implications, and the same workflow must support periodic re-KYC and event-triggered escalations for existing users. Outputs feed downstream feature gating (deposits, fiat ACH, wires, derivatives) and the ongoing transaction monitoring system.

## Requirements

### Functional Requirements
- Multi-step KYC pipeline: Basic (email/phone) -> Tier 1 (PII: name/DOB/address) -> Tier 2 (gov ID + selfie + liveness) -> Tier 3 (proof of funds, source of wealth)
- Tier-based feature gating: each tier unlocks a specific set of products (crypto-only deposits, fiat ACH, wires, high limits, derivatives)
- Document verification pipeline: OCR, face match, liveness check, with vendor abstraction
- Sanctions / PEP / adverse media screening against OFAC, UN, EU, and commercial lists
- Risk-based decisioning that combines doc, sanctions, fraud, and behavioral signals into one decision
- Manual review queue with case management, ownership, SLA tracking, and audit trail
- Save/resume across sessions: applicants abandon and return days later; state must persist
- Per-jurisdiction policy: country/state matrix as data, not hardcoded
- Re-KYC: periodic refresh and event-triggered escalation (high-volume activity, jurisdiction change, address change)
- Immutable audit log of every decision, override, and policy version applied

### Non-Functional Requirements
- Sub-2s p99 for synchronous steps (PII submission, eligibility check); document verification is async with explicit "in review" status
- 99.9% completion rate for applicants who reach Tier 2 (drop-off is the headline business metric)
- 99.99% availability for active applications and tier-status reads (downstream services depend on tier)
- PII encryption at rest with field-level encryption for SSN/government ID; documents in vault (S3 + KMS)
- 5-7 year regulatory retention; immutable audit log
- Workflow durability: a crash mid-application must not lose state, double-process, or leave the user stuck

### Out of Scope (clarify with interviewer)
- Transaction monitoring (separate system; this design produces the tier and risk profile that monitoring consumes)
- Travel Rule message construction (separate system; triggered post-KYC on outbound transfers)
- Tax form generation (1099, etc.)
- Customer support tooling beyond the manual review queue
- Institutional onboarding (very different shape -- mention as follow-up)

## Constraints
- Volume: millions of new applications per year, peak 10x normal during bull-market crypto inflows
- Jurisdictions: 100+ countries, per-state US (NY BitLicense, TX, CA), per-province CA, per-state regulated products
- Vendors: identity verification (Onfido, Persona, Jumio), sanctions (ComplyAdvantage, Refinitiv), blockchain analytics for declared wallets (Chainalysis, Elliptic). Must be swappable.
- Adversarial: synthetic identities, document forgery, mass-account-creation bots, account takeover during onboarding
- Regulatory: BSA, FinCEN, BitLicense, EU AMLD, FCA, MAS -- each with different evidence requirements
- KYC is not a one-time event: re-verification on cadence and on triggers, with full audit of why

## Key Topics Tested
- [[../../../05-async-processing/index|Async Processing]] -- workflow orchestration (Temporal), durable state, retries, saga compensation
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- vendor outages, fail-to-manual-review, partial sanctions match handling
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- idempotency across save/resume, exactly-once decision recording
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- PII vault, field-level encryption, immutable audit log, jurisdiction policy as data
- [[../../../02-scaling-reads/index|Scaling Reads]] -- tier-status lookups on hot path, jurisdiction policy cache
- [[../../../08-security-and-privacy/index|Security & Privacy]] -- PII redaction, KMS, access logs, retention policy
