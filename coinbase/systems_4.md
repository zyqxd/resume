## Prompt 4: Design a Global Credit Card Application Approvals System

A backend that accepts credit card applications, returns approve/deny decisions, supports banks globally, integrates with credit bureaus (Credit Karma and similar), and defends against fraud and repeated-submission abuse. Tests workflow orchestration, third-party integration, fraud gates, idempotency, multi-tenant compliance.

### Probes to address as we go

- *"What if the credit bureau (Credit Karma, Equifax, etc.) is down or slow when an application comes in?"*
- *"What if a user submits 100 applications in 5 minutes from different devices?"*
- *"What if a decision takes longer than the user is willing to wait — what does the UX look like, and what state lives where?"*
- *"How do you handle differing credit-data formats and underwriting rules across countries?"*
- *"What if the underlying decisioning model is updated while applications are mid-flight?"*
- *"Two applications arrive with the same idempotency key — what happens?"*
- *"How do you keep the audit trail intact through retries, vendor failovers, and manual review?"*

### Functional Scope (clarify before designing)

- Who's the user? - Retail consumer
- What does "decision" mean — instant approve / deny
- Sync (user waits for the answer) or async (we email them later)? - hybrid
- Soft credit pull (pre-approval)
- Multi-tenant (one platform, many issuing banks each with their own underwriting policy)
- Jurisdictions — US-only first, expand to global
- In scope: application intake, underwriting decision, fraud screening, audit trail.
- Out of scope (probably): card manufacturing and shipping, post-issuance lifecycle, statement generation, disputes.

### Scale and shape

- 10,000 Applications per day, peak 10 QPS
- Decision latency target — sync seconds, async SLA 3 days
- Cost per credit bureau call? - Free for now
- Read traffic on application status? - 10x write

### Non-functional priorities

Correctness > availability > latency for the decision itself. Auditability is non-negotiable for regulatory reasons (FCRA in the US, GDPR / DPA in the EU, equivalent rules elsewhere).

### Deep-dive candidates

1. Application state machine + workflow orchestration (probably Temporal — long-running async, multi-vendor, durable)
2. Third-party credit bureau integration (caching, freshness, vendor abstraction, failover, cost containment)
3. Fraud (dedup, device fingerprinting, repeated-submission detection, allow vs review vs block)
4. Multi-tenant / multi-jurisdiction (per-bank policy as data, data-residency, per-country bureau adapters)
5. Idempotency and audit trail end-to-end (decision-explainability is a regulatory requirement)

### Architecture (10k ft)

We are the **underwriting platform** (Marqeta/Galileo-shaped). Banks are tenants who provide policy as config and are the legal issuer-of-record; we render the decision on their behalf and hand off approved applications to their card-management system. Internal-facing — banks call us, not consumers directly.

**Principles:** correctness > availability > latency. A bad approval is worse than a slow response. Auditability is non-negotiable.

#### Components

- **Backend service** — bank-facing API.
  - `POST /apply { entity_id, bank_id, ...metadata }` → `{ status: approved | rejected | pending, application_id }`. Sync if pre-approved or if the workflow finishes inside the HTTP window; async (`pending` + webhook) otherwise. Single code path — sync is just "did the workflow complete in time."
  - `GET /application_status/{id}` → current state. Read traffic is 10x writes; cache at the gateway.
  - **Idempotency:** client-supplied `Idempotency-Key` header per request, scoped per-tenant, 24h dedup window. Same key + same payload → replay; same key + different payload → 409.
  - **Pre-flight velocity check** by `entity_id` (calls fraud service inline) — rejects abuse before starting a workflow.

- **MySQL (single instance)** — operational store. Throughput is not a concern at 10 QPS.
  - `applications { entity_id, temporal_workflow_id, bank_id, state, created_at, ... }`
  - `banks` — slow-growing list of integrated banks.
  - `bank_config` — versioned, immutable rows (`bank_id, version, effective_at, min_score, jurisdictions, model_id, model_version, bureau_strategy, manual_review_triggers, ...`). Workflow pins `version` at start.
  - `pre_approved { offer_id, entity_id, bank_id, soft_pull_snapshot_id, terms, expires_at, consumed_at }` — short-circuits underwriting if offer is unexpired and applicant data hasn't materially changed.

- **Temporal (Cloud)** — workflow spine. Every application is one workflow, even pre-approved/sync ones. Workflow pins `bank_config.version` and `model_version` at start so policy/model changes mid-flight don't affect in-flight applications.
  - Activities call out to: KYC, fraud, bureau, decision engine, notifications, finalize-decision.
  - Workflow code is deterministic; all I/O lives in activities.
  - **Sync vs async response — `Update-With-Start`.** `POST /apply` calls Temporal's `UpdateWithStartWorkflow` (Server ≥ 1.28) — starts the workflow and awaits the Update handler's return value, in one round trip. Caller waits on `wait_for_stage = COMPLETED`.
    - Update handler runs as workflow code: assigns `application_id`, kicks off the main path, then `workflow.wait_condition(predicate, timeout=2.5s)` where `predicate = state in {APPROVED_PENDING_FUND, APPROVED, DECLINED}`. Returns `ApplyResult(verdict=state, application_id)`.
    - On internal timeout → returns `verdict=pending, application_id`. Internal timeout is set just under the client RPC budget (~2.5s vs 3s) so the handler returns cleanly rather than the client RPC timing out.
    - Main workflow continues regardless; webhook fires on terminal state.
    - Predicate choice (return on `APPROVED_PENDING_FUND` vs wait for `APPROVED`) is a product decision — returning earlier means more sync verdicts but rare bank-rejection-after-approval is handled via the `RescindWorkflow` compensation path.
  - **Idempotency:** `WorkflowID = idempotency_key`. Retry of the same request rehydrates the same handle and returns the now-completed result or another `pending`.
  - **`FinalizeDecision` lives in the workflow.** Idempotent MySQL write of the decision row + idempotent outbox enqueue, same activity. Decision is not "made" until both are durable; workflow-level retry semantics ensure at-least-once delivery. Kafka → WORM tail is plumbing outside Temporal.

- **Decision engine** — stateless service. `(features, policy_version) → (decision, reason_codes)`. Called from a Temporal activity. Policy config is passed in by the workflow, not fetched at decision time.

- **Fraud service** — separate bounded context (different SLAs, data model, on-call).
  - **Pre-flight path** (sync, cheap): velocity / dedup-of-intent by `entity_id` across recent applications. Called inline from intake.
  - **In-workflow path** (authoritative): full fraud verdict with device fingerprint, identity graph, consortium signals. Called as a Temporal activity.
  - Manual-review queue with on-call alerting on backup. Queue is part of the architecture, not an ops afterthought.

- **Bureau service** — vendor abstraction over Equifax / Experian / TransUnion / Credit Karma. Per-country adapters behind a uniform interface. Soft pull (cached, prequal) vs hard pull (never cached, snapshotted into the audit record). Idempotent calls keyed by `(applicant_id, pull_type, day)` to prevent double hard-pulls. Circuit breaker + per-applicant budget cap. Fail-closed on prolonged outage, but with retry + SLA window (3 days) before declining — don't DDoS the manual-review queue on an Equifax blip.

- **Notification service** — outbound webhooks to banks announcing application status. Retries with exponential backoff. Bank's CMS is responsible for card manufacturing/shipping (out of scope).

- **Audit trail (decision-of-record store)** — separate from operational logs and from Temporal history.
  - **Emit at each significant boundary**, not only terminal: `KYC_VERDICT`, `FRAUD_VERDICT`, `BUREAU_PULL`, `DECISION_ENGINE_OUTPUT`, `MANUAL_REVIEW_ACTION`, `DECISION_FINALIZED`. Each is required for adverse-action notices and Art. 22 explanations.
  - Each emit is an idempotent activity: MySQL outbox row + (downstream) Kafka publish + WORM terminal sink. Same envelope, hash-chained per `(application_id, sequence)`.
  - **`FinalizeDecision`** is the closing activity that ties prior events with a terminal hash and writes the decision row to MySQL.
  - Delivery: **transactional outbox** in MySQL → Kafka → **S3 Object Lock (Compliance mode)** with Glacier Vault Lock for cold archival. Hash chain at producer = tamper-evidence on top of WORM's tamper-prevention. (On-prem WORM only when contractually required.)
  - **Hot read index: OpenSearch** mapping `(application_id, event_type, timestamp) → S3 key`. Regulator queries hit OpenSearch to locate records, then read raw payloads from S3. Index is mutable; data it points to is immutable.
  - **Per-regulation emit:** events are emitted at any boundary required by jurisdictional rules (e.g., a region-specific rule requires capturing reviewer rationale) — same envelope, same pipeline, regulatory adapter consumes from OpenSearch + S3 to render notices.
  - Snapshot completeness at decision time: applicant payload hash, bureau response (hash + S3 pointer if large), feature vector, policy version, model version, model output, reason codes, timestamp, workflow_id, idempotency_key. Any referenced object is also WORM-stored.
  - **Read path:** WORM is cold — regulator queries served via a hot index (OpenSearch or Postgres mapping `application_id → S3 keys`) or Iceberg/Delta on S3 with Athena. Index is mutable; data it points to is immutable. Minutes-to-hours response time is acceptable.
  - **Failure semantics:** if outbox/Kafka emit fails, `FinalizeDecision` retries (Temporal). Activity does not return success until durable. Workflow blocks; sync HTTP response delays. Aligns with correctness > availability > latency — a decision that isn't auditable isn't a decision.
  - CDC → Snowflake/Axiom is for **analytics**, not for the regulatory record. Don't reconstruct compliance artifacts from CDC.

- **Regulatory adapter (hand-waved)** — FCRA adverse-action notices, GDPR Art. 22 right-to-explanation, jurisdiction-specific rules. Reads from the audit log; not on the decision hot path.

#### Cross-cutting

- **Pinning at workflow start:** `bank_config.version`, `model_version`, feature snapshot. Survive policy/model changes mid-flight without workflow versioning gymnastics.
- **Idempotency layered:** HTTP key at edge; `WorkflowID = idempotency_key` at orchestrator; `(applicant, pull_type, day)` at vendor calls.
- **Fail-closed with SLA window:** vendor outage doesn't auto-deny; retry within the 3-day async SLA, then route to manual review or decline. On-call engages before the cutoff.
- **KYC → fraud → underwriting** order of operations. Bureau pulls feed underwriting, not fraud.

#### State ownership (Temporal vs MySQL)

**Decision: MySQL is the source of truth for application state.** Temporal owns orchestration; `applications.status` in MySQL is canonical for `GET /application_status`.

- Each transition is an idempotent `recordStatus(app_id, new_status, expected_version)` activity doing `UPDATE applications SET status=?, version=version+1 WHERE id=? AND version=?`. Crash-safe via Temporal retry.
- `workflow_id` stored on the row so ops can jump to Temporal UI; bank-facing reads never touch Temporal.
- Read path (~100 QPS) hits MySQL with a covering index, gateway-cached.
- Property: if Temporal is swapped for Step Functions / Restate later, the data model is untouched.
- Rejected alternatives: **Temporal-as-source-of-truth** (couples API SLO to worker fleet, expensive on Cloud advanced visibility, non-platform teams can't `SELECT`); **event-sourced via Kafka** (overkill at 10 QPS); **Restate-style durable KV** (tighter lock-in, smaller ecosystem).

#### Application state machine

```
SUBMITTED               intake accepted, workflow started
SCREENING               KYC + fraud, parallel inside workflow
PENDING_DOCS            applicant action required (SSN mismatch, ID upload)
MANUAL_REVIEW           queued for human analyst
UNDERWRITING            bureau + decision engine
APPROVED_PENDING_FUND   decision made, awaiting bank CMS confirmation
APPROVED                terminal: card issued
DECLINED                terminal: + decline_reason (fraud | credit | kyc | policy)
WITHDRAWN               terminal: applicant canceled
EXPIRED                 terminal: timed out, regulatory cutoff
```

**Rescission is NOT a status on `applications`.** Once `applications.status` reaches a terminal state, that row is immutable — it records what underwriting concluded. Post-decision reversals are tracked in a separate `application_rescissions` table (see below). The API's `effective_status` is a derived view: `if active rescission exists → REVERSED else applications.status`.

**Conventions:**
- Gerunds for in-flight, past participles for terminal.
- One `DECLINED` state with a reason field — not per-stage rejection states. State encodes progress; audit log encodes the why.
- Parallelism (KYC + fraud) lives in workflow code, not in the status column. Status column shows parent phase (`SCREENING`).
- Reversibility is forward-only: post-decision rescission goes to `REVERSED`, never back to an earlier state.
- Both events (append-only, audit) and status column (projection for ops queries) — kept in sync via the transition activity.

#### Happy path workflow

```
SUBMITTED
  └─ enter workflow; pin bank_config.version + model_version
  └─ if pre_approved offer matches and unexpired → fast-path to APPROVED_PENDING_FUND
  
SCREENING
  └─ Promise.all([kycActivity(), fraudActivity()])
  └─ both pass → UNDERWRITING
  └─ fraud needs more info → PENDING_DOCS (notify bank via webhook to collect)
  └─ fraud can't auto-decide → MANUAL_REVIEW (queue + on-call alert on backup)
  └─ either fails terminally → DECLINED (reason: fraud | kyc)

PENDING_DOCS / MANUAL_REVIEW
  └─ resolved (signal from bank or analyst, recorded with reviewer_id) → UNDERWRITING
  └─ unresolved past SLA → EXPIRED

UNDERWRITING
  └─ bureau pull (idempotent, snapshotted) → decision engine activity
  └─ approve → APPROVED_PENDING_FUND
  └─ deny → DECLINED (reason: credit | policy)

APPROVED_PENDING_FUND
  └─ outbound webhook to bank CMS to provision + fund
  └─ bank confirms → FinalizeDecision activity → APPROVED
  └─ bank rejects (BIN exhausted, internal overlay) → DECLINED (reason: bank_rejection)

APPROVED
  └─ FinalizeDecision: MySQL decision row + outbox → Kafka → WORM
  └─ webhook to bank: terminal status
  └─ workflow ends
```

#### Rescission (post-decision reversal)

Modeled as a **separate record in a separate table**, driven by a separate workflow. The original `applications` row is never mutated after terminal — same shape as `authorizations` vs `chargebacks` in payments.

```sql
application_rescissions {
  id, application_id FK,
  rescission_workflow_id,
  reason,             -- post_decision_fraud | bank_request | regulator | applicant_request
  triggered_by,
  status,             -- PENDING | COMPLETED | FAILED
  effective_at,
  compensations_json  -- card_revoked, fees_refunded, bank_notified
}
```

```
RescindWorkflow (triggered by post-decision fraud, bank request, regulator, applicant)
  └─ insert application_rescissions row (status=PENDING)
  └─ append RESCISSION_INITIATED event to audit log
  └─ compensating activities: revoke card via bank webhook, refund fees, notify applicant
  └─ on success → status=COMPLETED, append RESCISSION_COMPLETED event
  └─ on failure → status=FAILED, retry policy + on-call alert
```

**API exposes `effective_status`:** `if active rescission exists → REVERSED else applications.status`. Materialize as a view, or denormalize as `applications.current_effective_status` written by the rescission workflow's `recordStatus` activity (still forward-only — projection updates, original decision row is untouched).

**Why two tables, not one status column:**
- The original underwriting decision is provably immutable in OLTP, not just in the audit log.
- Rescission has its own lifecycle (PENDING → COMPLETED), compensations that can fail and retry, fields that don't belong on applications.
- Multiple rescissions are representable (rare but possible: applicant rescinds → reinstated → bank rescinds → multiple rows, applications.status APPROVED throughout).
- Same conceptual split as `authorizations` vs `chargebacks`, `orders` vs `returns`.

#### Failure modes & manual review SLA enforcement

**Timer lives in Temporal, not fraud.** Durable timers are exactly what Temporal is for — survive restarts, deterministic, free vs rebuilding cron+DB+leader-election. Fraud owns the queue tooling (reviewer UI, assignment, prioritization); workflow owns the clock.

```
on entering MANUAL_REVIEW:
  await(reviewSignal | timer(bank_config.manual_review_sla_seconds))
  if timer fires first → execute bank_config.manual_review_breach_action
  if signal first → record { reviewer_id, decision, decided_at } → advance to UNDERWRITING
```

**Two-tier SLA enforcement — separate concerns:**

- **Hard cutoff (Temporal timer):** the system's escape hatch. Fires at 100% of SLA, no human required. Deterministic, regulatory protection.
- **Internal SLO alerts (Datadog):** warning at 50%, page at 80%. Fires on queue depth, **age of oldest item**, review velocity vs intake rate, reviewer abandonment. Oncall responds *before* the hard timer fires. Incident-level: failing our internal SLO means we're at risk of breaching the bank-facing SLA.

A small queue can still be stalled — monitor dwell time, not just count.

**Breach action is per-bank policy, not a system decision.** Fail-closed feels safe but isn't always correct (some jurisdictions, some contracts, an `EXPIRED` outcome with no adverse-action notice is cleaner than a forced `DECLINED`).

```
bank_config:
  manual_review_sla_seconds
  manual_review_breach_action: declined | expired | escalate
  internal_slo_warning_pct, internal_slo_page_pct
  reviewer_priority_rules
```

System enforces the timer; policy decides what to do when it fires. Same engine, different policies per tenant, no code branches per bank.

**Sunk-cost compensation:** SLA-breach declines have already incurred bureau pulls / fraud vendor calls. Eat the cost, but cache soft-pull data within freshness window so re-applications don't double-pay.

**Manual review queue SLOs (operational):**
- p50/p95 dwell time per priority tier
- queue depth + age-of-oldest
- reviewer throughput, abandonment rate

#### Failure modes by state

**Vendor timeouts in UNDERWRITING.** No SQS / DLQ — Temporal *is* the durable retry layer. Wrap bureau calls as activities with explicit retry policy:

```
StartToCloseTimeout, ScheduleToCloseTimeout (overall budget),
RetryPolicy { InitialInterval, BackoffCoefficient, MaxAttempts, NonRetryableErrors }
```

In the bureau service: per-vendor circuit breaker, per-applicant cost cap, vendor-side idempotency key `(applicant_id, pull_type, day)`. On retry exhaustion, the **workflow** decides next step from `bank_config`:
- Fall back to secondary bureau (`bureau_strategy = fallback_chain`)
- Route to `MANUAL_REVIEW` with reason "bureau unavailable"
- Fail-closed → `DECLINED` with reason `bureau_outage`

Monitor activity failure rate, retry count, p99 latency, `ScheduleToCloseTimeout` exhaustions — Temporal Cloud emits these; scrape via OTEL to Datadog.

**Worker crashes mid-activity.** Temporal gives at-least-once activity execution for free. Activity is re-dispatched to another worker. Requirements:
- Activity must be idempotent (vendor idempotency keys, version-column UPDATEs).
- Long activities (>30s) must heartbeat — `HeartbeatTimeout` lets Temporal reschedule a stalled worker.
- Vendor calls that succeeded but didn't return: vendor-side idempotency key + reconciliation job to detect ghost charges.

**Applicant withdrawal mid-flight.** Use Temporal cancellation (`WorkflowClient.cancel`). In-flight activities receive a cancel signal and decide whether to abort or finish (e.g., let an in-flight bureau pull complete since we've already paid).

Compensating signals needed only where work has been dispatched:
- **MANUAL_REVIEW:** `recallReviewItem(application_id)` to fraud's queue.
- **APPROVED_PENDING_FUND:** compensating cancel webhook to bank CMS (saga pattern).

Race condition: withdrawal arrives same instant as finalization. Signal handler guards on current state — if already `APPROVED`, the withdrawal becomes a **rescission request** (`applicant_request` reason) routed through `RescindWorkflow`. Forward-only, consistent with the audit log.

**Per-bank queues in fraud.** Logical partition `(bank_id, priority_tier)` on a shared physical store, not separate infrastructure. Reviewer pools configured per-bank where compliance requires; pooled with bank-affinity routing otherwise. Hard physical isolation only as exception (data residency, in-house staff requirements).

#### Multi-region / global

**Cell architecture.** Each region is a full self-contained stack: backend, MySQL, Temporal namespace, Kafka, fraud, decision engine, bureau adapters, audit log + WORM, manual review pool. Reasonable cells: `us`, `eu`, `uk`, `ca`, `apac-sg`, `india`, `latam`. Driven by data-residency law (GDPR, UK-DPA, India DPDP, Brazil LGPD), not technical convenience.

**Same architecture, different config + adapters.** One codebase, many cells. Regional differences are plumbed through:
- **Config:** per-bank, per-jurisdiction policy thresholds, allowed jurisdictions, SLA windows, breach actions — all rows in `bank_config`.
- **Adapters:** bureau (Equifax/Schufa/CIBIL/Serasa), KYC, fraud — uniform interface, regional implementations.
- **Regulatory adapter output:** FCRA letter vs GDPR Art. 22 explanation vs UK FCA disclosure — same audit data, different rendering.

Workflow engine, state machine, FinalizeDecision, idempotency, audit substrate, rescission flow are **identical across cells**.

**Global control plane (no PII):**
- Bank registration metadata, region pinning, contract config
- Software artifact registry, model artifact registry
- Aggregate metrics, anonymized dashboards
- Engineering observability

**Regional data plane (all PII):**
- All applications, decisions, bureau payloads, audit records, reviewer actions, model predictions. Never crosses cell boundaries.

**Routing.** Banks register with a home region; API endpoints are region-pinned. No dynamic geo-routing. Cross-border applicant/bank pairs (US bank, EU resident) default to forbidden at contract level; allowed only with explicit per-bank contract that pins data to applicant residency.

**Cross-region entity dedup is intentionally absent.** Same human, different cell = different applicant for regulatory purposes. Cross-border fraud rings are addressed at the consortium-vendor layer (out of our system's scope).

**Reviewer pools are cell-local.** Some jurisdictions require in-region reviewers; reviewer accounts don't span cells.

**Failure isolation bonus.** Regional outages don't cascade.

**Cost.** N cells > 1 cell. At 10k/day global, per-cell utilization is low, but compliance is non-negotiable. Control-plane savings come from sharing artifacts (one training pipeline, one observability stack), not from collapsing data.

#### Open / not yet deep-dived

- Application state machine end-to-end with failure transitions.
- Manual review queue mechanics (assignment, SLAs, reviewer tooling).
- Multi-jurisdiction data residency (cells per region, control plane vs data plane).
- Sync-vs-async UX handoff (long-poll vs webhook) — partially specified.

