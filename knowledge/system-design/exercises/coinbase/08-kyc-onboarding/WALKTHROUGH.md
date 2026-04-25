# Walkthrough: Design an Account Opening and KYC (Know Your Customer — identity verification required before account opening) / AML (Anti-Money Laundering) Onboarding Workflow (Coinbase)

## Step 1: Clarify Requirements and Scope

Before drawing anything, lock down the scope. Onboarding is the single system at Coinbase where naming the wrong primary axis costs you the round.

- How many jurisdictions? (100+ countries, per-state in the US, per-province CA. Jurisdiction shapes every rule.)
- Are KYC tiers required? (Yes -- Basic -> Tier 1 -> Tier 2 -> Tier 3, each unlocking a specific feature set.)
- What's the latency budget? (Synchronous steps under 2s p99. Document verification is async with an explicit "in review" status -- vendors take 30s-30min.)
- Is drop-off a design constraint? (Yes -- it's the headline business metric. Half of applicants abandon at the doc-upload step. Save/resume is non-negotiable.)
- Vendor strategy? (Multi-vendor with abstraction. Identity verification, sanctions, and blockchain analytics each have a primary vendor and a fallback. Vendors get switched every couple of years for cost or quality reasons.)
- Is this a one-time event? (No. Re-KYC on cadence and on triggers. Same workflow handles new and existing users.)

**Primary design constraint:** Compliance correctness over latency. A wrong tier assignment is a regulatory event, sometimes a fine, sometimes a license suspension. Every architectural choice filters through "can we defend this decision in front of a regulator three years later, with the exact policy version, evidence, and signals in hand?" If the audit trail is incomplete, the design fails compliance.

**The single staff-level move that sets up the whole answer:** Pick workflow orchestration as the architectural primitive, not ad-hoc service calls.

KYC is a long-running, multi-step, durable, branchy process. Some steps are synchronous (PII (Personally Identifiable Information) submission), some are async with vendor SLAs (Service Level Agreements) measured in minutes (document verification), some require a human in the loop (manual review). It must survive process crashes, vendor outages, and applicant absences of days or weeks. It must support save/resume, replay, and exactly-once side effects. It must produce a decision audit trail.

That shape -- durable state, branchy, retryable, observable, replayable -- is exactly what a workflow engine like Temporal (workflow orchestration platform — durable async state machines, used at Coinbase; publicly known to be in use at Coinbase), Cadence (workflow orchestration platform — Uber's predecessor to Temporal), AWS Step Functions (AWS managed state machine service), or Airflow (workflow orchestrator focused on batch/DAG execution) exists to solve. State that you'll use Temporal early, then describe the rest of the system as services the workflow orchestrates. If you instead try to model this as a chain of REST calls or microservices passing each other messages, you'll spend the rest of the round inventing distributed transactions, retry logic, and timeout handling that already come free with the orchestrator.

---

## Step 2: High-Level Architecture

```
        Applicant (Web / iOS / Android)
                       |
                       v
       +----------------------------------+
       |   Onboarding API Gateway         |  (auth, captcha (bot-detection
       |   (idempotent submission)        |   challenge), device fp,
       |                                  |   rate limit, anti-bot)
       +----------------+-----------------+
                        |
                        v
       +----------------------------------+
       |   Application Service            |  (CRUD app state, save/resume,
       |   (workflow id stable per user)  |   eligibility shortlist)
       +----------------+-----------------+
                        |
                        v
       +----------------------------------+
       |   Workflow Orchestrator          |  (Temporal -- durable state,
       |   (per-application workflow)     |   retries, saga, branch logic)
       +-----+----------+----------+------+
             |          |          |
             v          v          v
   +-----------+  +-----------+  +-----------+
   | KYC Tier  |  | Identity  |  | Sanctions |
   | Engine    |  | Verif.    |  | / PEP     |
   | (policy)  |  | Pipeline  |  | Screening |
   +-----+-----+  +-----+-----+  +-----+-----+
         |              |              |
         |              v              v
         |        (vendor abstraction layer:
         |         Onfido / Persona / Jumio,
         |         ComplyAdvantage / Refinitiv)
         |
         v
   +----------------------------------+
   |   Risk Decisioning Service       |  (combines all signals,
   |   (per-jurisdiction thresholds)  |   produces tier + decision)
   +-----+----------+-----------------+
         |          |
         v          v
   +-----------+  +-----------+       +-------------------+
   | Auto-     |  | Manual    | <---> | Reviewer Console  |
   | Approve   |  | Review    |       | (case mgmt, SLA,  |
   |           |  | Queue     |       |  override audit)  |
   +-----+-----+  +-----+-----+       +-------------------+
         |              |
         +------+-------+
                |
                v
       +----------------------------------+
       |   Tier Service (read-side cache, |  <-- downstream services
       |   served sub-10ms to gating)     |     read here for feature gating
       +----------------+-----------------+
                        |
                        v
       +----------------------------------+
       |   Audit Log (append-only,        |  <-- compliance, regulator
       |   immutable, 5-7yr retention)    |     audits, internal review
       +----------------------------------+

   PII Vault (off to the side, accessed only by services that need plaintext):
   +-----------------------------------+
   |  S3 + KMS for documents           |
   |  Field-level encryption for SSN,  |
   |  gov ID, DOB. Tokenization layer. |
   +-----------------------------------+
```

### Core Components

1. **Onboarding API Gateway** -- client termination, anti-bot defenses (captcha, device fp, IP reputation), idempotency enforcement.
2. **Application Service** -- owns the application record; maps user_id to stable workflow_id; exposes save/resume.
3. **Workflow Orchestrator (Temporal)** -- the spine. One workflow per application. Durable state, retries, saga, timeouts, branching. The rest of the system is activities the workflow invokes.
4. **KYC Tier Engine** -- versioned policy service. Given (jurisdiction, declared attributes, target tier), returns required steps, evidence rules, and thresholds.
5. **Identity Verification Pipeline** -- doc OCR (Optical Character Recognition — extracting text from images), face match, liveness behind a vendor abstraction. Async with manual fallback.
6. **Sanctions / PEP (Politically Exposed Person — higher-risk for corruption: political officeholders, family, close associates) / Adverse Media Screening** -- vendor-abstracted, partial-match handling, whitelist management.
7. **Risk Decisioning Service** -- combines signals into tier + approve/review/deny with per-jurisdiction thresholds and explainability.
8. **Manual Review Queue** -- case management, ownership, SLA, escalation, reviewer console.
9. **Tier Service** -- read-side projection. Sub-10ms tier lookups for downstream feature gating.
10. **PII Vault** -- S3+KMS (Key Management Service — managed cryptographic key service, e.g., AWS KMS) for documents; field-level encryption for SSN (Social Security Number)/gov ID; tokenization so most services carry opaque tokens.
11. **Audit Log** -- append-only, immutable, 5-7 year retention.

---

## Step 3: Data Model

### Core Tables

```sql
-- The application record. One per user per re-KYC cycle.
applications (
  id              BIGINT PRIMARY KEY,
  user_id         BIGINT NOT NULL,
  workflow_id     VARCHAR(64) NOT NULL UNIQUE,  -- stable across save/resume
  jurisdiction    VARCHAR(8) NOT NULL,           -- ISO country + subdivision (US-NY, CA-ON)
  declared_target_tier  SMALLINT NOT NULL,       -- 1, 2, 3
  current_tier    SMALLINT NOT NULL DEFAULT 0,   -- 0 (basic) until first decision
  status          VARCHAR(24) NOT NULL,          -- 'in_progress', 'in_review', 'approved', 'denied', 'abandoned'
  created_at      TIMESTAMP NOT NULL,
  updated_at      TIMESTAMP NOT NULL,
  policy_version  VARCHAR(32) NOT NULL,          -- which KYC policy version applies
  reason          VARCHAR(64),                   -- 'new_user', 're_kyc_periodic', 'tier_upgrade', 'event_triggered'
  CHECK (current_tier <= declared_target_tier)
);

-- Per-step record. Each step is one phase of the pipeline.
kyc_steps (
  id              BIGINT PRIMARY KEY,
  application_id  BIGINT NOT NULL REFERENCES applications(id),
  step_type       VARCHAR(32) NOT NULL,          -- 'pii_collect', 'doc_verify', 'sanctions', 'risk_decision', 'manual_review'
  status          VARCHAR(16) NOT NULL,          -- 'pending', 'in_progress', 'passed', 'failed', 'review'
  vendor          VARCHAR(32),                   -- 'onfido', 'persona', 'comply_advantage', 'internal'
  vendor_ref      VARCHAR(128),                  -- vendor-side correlation id
  result_summary  JSONB,                         -- redacted result (no PII)
  evidence_ref    VARCHAR(128),                  -- pointer to vault for raw evidence
  attempt         SMALLINT NOT NULL DEFAULT 1,
  started_at      TIMESTAMP NOT NULL,
  completed_at    TIMESTAMP,
  UNIQUE (application_id, step_type, attempt)
);

-- Documents uploaded by the applicant. Stored in vault; only metadata here.
documents (
  id              BIGINT PRIMARY KEY,
  application_id  BIGINT NOT NULL,
  document_type   VARCHAR(32) NOT NULL,          -- 'passport', 'drivers_license', 'id_card', 'proof_of_address'
  vault_object    VARCHAR(256) NOT NULL,         -- S3 key in PII vault
  kms_key_id      VARCHAR(128) NOT NULL,
  ocr_extracted   JSONB,                         -- name, DOB, expiry -- field-level encrypted
  face_match_score NUMERIC(4,3),                 -- 0.0 to 1.0
  liveness_score  NUMERIC(4,3),
  uploaded_at     TIMESTAMP NOT NULL
);

-- Sanctions / PEP screening results.
sanctions_checks (
  id              BIGINT PRIMARY KEY,
  application_id  BIGINT NOT NULL,
  list_name       VARCHAR(32) NOT NULL,          -- 'OFAC_SDN', 'UN_consolidated', 'EU_consolidated', 'PEP_global'
  match_status    VARCHAR(16) NOT NULL,          -- 'no_match', 'partial', 'confirmed', 'whitelisted'
  match_score     NUMERIC(4,3),
  vendor_ref      VARCHAR(128),
  reviewed_by     VARCHAR(64),                   -- compliance officer if manually cleared
  whitelist_until TIMESTAMP,                     -- whitelist has explicit expiry
  checked_at      TIMESTAMP NOT NULL
);

-- The terminal decision per application (and per step that produces a decision).
risk_decisions (
  id              BIGINT PRIMARY KEY,
  application_id  BIGINT NOT NULL,
  decision        VARCHAR(16) NOT NULL,          -- 'approve', 'review', 'deny'
  assigned_tier   SMALLINT NOT NULL,
  signal_snapshot JSONB NOT NULL,                -- doc, sanctions, fraud, behavioral inputs at decision time
  thresholds      JSONB NOT NULL,                -- thresholds applied (jurisdiction-specific)
  policy_version  VARCHAR(32) NOT NULL,
  model_version   VARCHAR(32),                   -- if a fraud model contributed
  explanation     JSONB,                         -- top contributing signals (SHAP-style)
  decided_at      TIMESTAMP NOT NULL,
  decided_by      VARCHAR(64) NOT NULL           -- 'auto' or reviewer id
);

-- Append-only audit log. Every state transition lands here.
audit_events (
  id              BIGSERIAL PRIMARY KEY,
  application_id  BIGINT NOT NULL,
  event_type      VARCHAR(48) NOT NULL,
  actor           VARCHAR(64) NOT NULL,          -- user, 'system', or reviewer id
  before_state    JSONB,
  after_state     JSONB,
  metadata        JSONB,                         -- redacted -- never raw PII
  occurred_at     TIMESTAMP NOT NULL
);

-- Jurisdiction policy lives as data, not code.
jurisdiction_policy (
  jurisdiction    VARCHAR(8) NOT NULL,
  tier            SMALLINT NOT NULL,
  required_steps  JSONB NOT NULL,                -- ordered list of step types
  evidence_rules  JSONB NOT NULL,                -- e.g., {"id_doc": ["passport","drivers_license"]}
  thresholds      JSONB NOT NULL,                -- match-score, fraud-score thresholds
  policy_version  VARCHAR(32) NOT NULL,
  effective_from  TIMESTAMP NOT NULL,
  effective_to    TIMESTAMP,
  PRIMARY KEY (jurisdiction, tier, policy_version)
);
```

### Key Design Decisions in the Schema

**`workflow_id` stable per user across save/resume:** Idempotency anchor. An applicant returning after three days hits the same workflow. Without a stable id, save/resume becomes a state-merging nightmare.

**`policy_version` on every application and decision:** Policy changes monthly (new sanctions list, new state regulation, vendor swap). A decision made under policy v2025-09 must remain explainable when audited in 2030. Storing the version with the decision is the audit-trail foundation.

**`evidence_ref` and `vault_object` separate from the structured row:** Application rows are small and queried hot; documents are large, encrypted, and accessed rarely. Splitting them keeps the OLTP path narrow and lets the vault have its own access controls and retention.

**`audit_events.metadata` is redacted:** Never raw PII. Engineers debugging stuck workflows do not need to see SSNs.

**Jurisdiction policy as a table, not a code constant:** Adding a new state's rule should be a config change reviewed by Legal, not a deploy. Deploys are for behavior changes, config is for rule changes.

---

## Step 4: Workflow Orchestration -- The Spine

The orchestrator is Temporal. The application workflow is a long-running, durable function whose checkpoints are the database of record for "where this applicant is right now."

### The Workflow Shape

```
@workflow
def kyc_workflow(user_id, target_tier, jurisdiction):
  policy = await activity.get_policy(jurisdiction, target_tier)  # pinned for this run

  pii = await activity.collect_pii(user_id)            # may sleep
  await activity.persist_pii(pii)

  sanctions = await activity.run_sanctions(pii, policy)
  if sanctions.match == 'confirmed':
    return await activity.deny(reason='sanctions_match')

  if target_tier >= 2:
    doc = await activity.collect_document(user_id)     # may sleep up to 14 days
    verify = await activity.verify_identity(doc, policy)
    if verify.requires_manual_review or sanctions.match == 'partial':
      decision = await activity.manual_review(application_id)
    else:
      decision = await activity.auto_decide(pii, sanctions, verify, policy)

  if target_tier >= 3:
    pof = await activity.collect_proof_of_funds(user_id)
    decision = await activity.evaluate_pof(pof, decision, policy)

  await activity.assign_tier(user_id, decision)
  await activity.publish_decision(decision)
```

### What Temporal Gives You for Free

- **Durable state:** Every `await` is a checkpoint. Process crashes don't lose state.
- **Retries with policies:** `verify_identity` retries 3x on transient errors; permanent errors bubble out.
- **Timeouts per activity:** `collect_document` waits up to 14 days; `run_sanctions` must return in 30s.
- **Saga compensation:** If `assign_tier` succeeds but `publish_decision` fails, the compensation rolls back the tier. Hand-coding this across services is a bug factory.
- **Replay safety:** Activity inputs/outputs are durably recorded; re-running replays history without re-invoking side effects.
- **Observability:** Built-in workflow history view -- support engineers and compliance officers can see every step, input, output, and retry per application.

### Idempotency at Every Activity

Every activity must be idempotent because Temporal will retry on ambiguous failures:

```
activity verify_identity(doc):
  vendor_request_id = hash(application_id || doc_id || attempt_number)
  return vendor.verify(doc, idempotency_key=vendor_request_id)
```

The vendor's idempotency key dedupes on their side; our writes use deterministic keys derived from workflow id and step.

### Why Not a Custom State Machine?

You could model this in PostgreSQL with a polling worker. You'd reinvent: durable timers (calling `pg_sleep` doesn't survive crashes), retry tables, distributed timeout handling, replay semantics, and a support UI. You'd end up building half of Temporal, badly.

---

## Step 5: KYC Tier Engine

The Tier Engine is a versioned policy service. Given `(jurisdiction, declared_attributes, target_tier)`, it returns the required steps, evidence rules, and decision thresholds. It is read-heavy and changes weekly.

### Tier Definitions (Coinbase shape)

| Tier | Required | Unlocks |
|---|---|---|
| Basic (0) | Email + phone (OTP) | View prices, watchlist, no funds movement |
| Tier 1 | Name, DOB (Date of Birth), residential address, last 4 SSN (US) | Crypto-only buy/sell up to small daily limit |
| Tier 2 | Government ID (passport/DL/ID), selfie, liveness, full SSN (US) | Fiat ACH on/off-ramp, larger crypto limits |
| Tier 3 | Proof of funds, source of wealth, attestations | Wires, high daily limits, derivatives in eligible regions |

### Per-Jurisdiction Tier Matrix (illustrative)

| Jurisdiction | Tier 1 evidence | Tier 2 evidence | Tier 3 special | Region-locked products |
|---|---|---|---|---|
| US-CA | Name/DOB/addr + SSN-4 | Gov ID + SSN-9 + selfie | POF + SOW + W-9 | None additional |
| US-NY | Name/DOB/addr + SSN-4 | Gov ID + SSN-9 + selfie + BitLicense (NY DFS license required to run a virtual currency business in NY) addendum | POF + SOW + heightened | No staking, futures restricted |
| US-TX | Name/DOB/addr + SSN-4 | Gov ID + SSN-9 + selfie | POF + SOW | Derivatives allowed |
| CA | Name/DOB/addr + SIN | Gov ID + selfie + FINTRAC (Financial Transactions and Reports Analysis Centre — Canada's FIU) attestations | POF + SOW + FINTRAC | Restricted listing set |
| GB | Name/DOB/addr + NI ref | Gov ID + selfie + FCA (Financial Conduct Authority — UK financial regulator) disclosures | POF + SOW + risk warning sign-off | FCA promotion rules apply |
| DE | Name/DOB/addr | Gov ID + selfie + Tax-ID | POF + SOW + MiCA (Markets in Crypto-Assets — EU regulation governing crypto issuance/services) disclosures | MiCA-aligned product set |
| SG | Name/DOB/addr + NRIC/FIN | Gov ID + selfie + MAS (Monetary Authority of Singapore) attestations | POF + SOW + accredited investor | MAS-restricted listing set |

The matrix lives in the `jurisdiction_policy` table. Adding a new jurisdiction is a config change, not a code change. The Tier Engine reads policy at workflow start and pins the version for the duration of the run.

### Tier Escalation Triggers

Users self-escalate when they hit a feature wall ("you need Tier 2 to deposit USD"). Beyond that: cumulative volume thresholds force Tier 3 prompts; address changes retrigger Tier 1+2 under the new jurisdiction; sanctions re-screen hits trigger holds; periodic 24-month re-KYC prompts users to refresh evidence. Each trigger spawns a workflow with the appropriate `reason` field -- same code path for new applicants and re-KYC. This is the payoff for treating KYC as a workflow, not a one-time event.

---

## Step 6: Identity Verification Pipeline

This is the most user-visible step and the most vendor-dependent. It's also where most drop-off happens (poor lighting, expired ID, camera issues).

### The Pipeline

```
Applicant uploads doc + selfie (mobile or web)
   |
   v
+-----------------------+
| Vendor Abstraction    |  one interface, multiple impls
| Layer                 |  (Onfido, Persona, Jumio, internal)
+----------+------------+
           |
           v
   +-----------+----------+
   |                      |
   v                      v
+--------+         +-------------+
|  OCR   |         | Face match  |
| (name, |         | (doc photo  |
| DOB,   |         |  vs selfie) |
| expiry)|         +------+------+
+---+----+                |
    |                     v
    |              +-------------+
    |              | Liveness    |
    |              | (selfie is  |
    |              |  a real     |
    |              |  person)    |
    |              +------+------+
    |                     |
    v                     v
+-----------------------------+
|  Result: pass / fail /      |
|  manual_review              |
+-----------------------------+
```

### Vendor Abstraction

The vendor interface is intentionally narrow:

```
interface IdentityVerifier:
  verify(document_ref, selfie_ref, jurisdiction) -> {
    ocr: { name, dob, expiry, doc_number_token },
    face_match_score: 0.0-1.0,
    liveness_score: 0.0-1.0,
    risk_signals: [...],            # vendor-specific flags, normalized
    verdict: 'pass' | 'fail' | 'review',
    vendor_ref: string
  }
```

Implementations: `OnfidoVerifier` (Onfido — identity verification vendor with document and biometric checks), `PersonaVerifier` (Persona — identity verification vendor with no-code workflow builder), `JumioVerifier` (Jumio — identity verification vendor with enterprise focus), `InternalVerifier`. A vendor router routes based on jurisdiction (some vendors are stronger in certain regions) and a per-vendor traffic split that the Vendor Ops team controls.

### Async Pattern

The vendor call is initiated synchronously from the workflow activity, but the verification itself can take 30 seconds to several minutes (OCR + face match + liveness review). The activity polls or, better, uses a vendor webhook:

```
Activity verify_identity():
  1. POST document to vendor with idempotency key
  2. Receive vendor_ref synchronously
  3. Workflow awaits a signal: "vendor.callback(vendor_ref)"
  4. Vendor webhooks to our endpoint when verification completes
  5. Webhook handler signals the workflow with the result
  6. Activity returns the result
```

Temporal's signal mechanism is what makes this clean. The workflow can suspend for hours waiting for a webhook, no polling needed.

### Manual Fallback

If vendor verdict is `review`, or if the vendor times out beyond a threshold, the activity routes to manual review (Step 9). The orchestrator doesn't decide the rules -- the Risk Decisioning Service does. The verification pipeline only produces the signals.

### Drop-off Mitigation

Pre-flight checks on the client (detect blur, glare, missing corners before upload) save vendor calls and manual reviews. Allow up to 3 doc upload attempts before forcing review. Vendor selection by historical pass rate per jurisdiction -- if Vendor A has 92% on US passports and Vendor B 88%, route US passports to A. Email reminders at +1d, +3d, +7d if the user uploads but never confirms.

---

## Step 7: Sanctions / PEP / Adverse Media Screening

Sanctions screening is run on declared identity (Tier 1 attributes) and again post-document-verification on the doc-extracted identity (in case they differ).

### What Gets Screened

- **OFAC (Office of Foreign Assets Control — US Treasury body that maintains the SDN sanctions list) SDN (Specially Designated Nationals — OFAC's blocked-persons list) list** (US Treasury, mandatory for any US user)
- **UN Consolidated Sanctions List**
- **EU Consolidated Sanctions List**
- **HMT (UK)**
- **PEP (Politically Exposed Persons)** -- not a sanction, but a heightened-due-diligence flag
- **Adverse media** -- news mentions tied to financial crime
- **Internal denylist** -- users we've previously banned

### Vendor Integration

ComplyAdvantage (AML and sanctions screening data provider) and Refinitiv World-Check (sanctions and adverse-media screening data provider) are common vendors. Same abstraction pattern as identity verification:

```
interface SanctionsScreener:
  screen(name, dob, country, lists) -> {
    matches: [{ list, match_score, candidate_id, candidate_data }],
    overall_status: 'no_match' | 'partial' | 'confirmed',
    vendor_ref: string
  }
```

Coinbase typically runs both a primary and secondary vendor and reconciles -- a partial in one is checked against the other, and a high-confidence match in either triggers the same workflow.

### Partial-Match Handling

This is where most reviewer time goes. A partial match means the vendor returned a candidate that fuzzy-matches the applicant on name + something else (DOB, country, alias) but isn't a confirmed identity match. The workflow:

1. Sanctions returns `partial` with N candidates (often 1-5).
2. The risk decision routes to manual review with the candidates attached.
3. A compliance officer compares the candidate's birthplace, photo (if available), and history against the applicant.
4. The reviewer either:
   - **Clears as no-match:** records reasoning, moves the application to the next step. Optionally adds the applicant to a whitelist with an expiry.
   - **Confirms as match:** denies the application, files SAR (Suspicious Activity Report — required filing for suspected illicit activity) if required.
5. The decision is recorded in `sanctions_checks` with `reviewed_by` and rationale. This is the audit trail.

### Whitelist Management

A whitelist is `(applicant_id, sanctions_candidate_id)` pairs manually cleared, preventing re-prompting on every re-screen. Hard rules: every entry has 12-24 month expiry (sanctions data changes); whitelist is per-applicant and per-candidate (not blanket); requires elevated reviewer privileges and dual approval; audit-logged on add/remove.

### Periodic Re-Screening

Existing users are re-screened nightly against updated lists. New matches trigger a workflow with `reason='event_triggered'` and may temporarily hold the user's tier pending review.

---

## Step 8: Risk-Based Decisioning

This is the brain. It combines doc verification, sanctions, fraud signals, and behavioral data into a single decision. It's pure logic; it doesn't talk to vendors.

### Signal Inputs

| Signal Source | Examples |
|---|---|
| Doc verification | OCR confidence, face-match score, liveness score, doc-tampering flags |
| Sanctions | match status, list, match score |
| Fraud / device | device fingerprint reputation, IP reputation, velocity (N applications from this IP/device), email/phone disposability, age of account |
| Behavioral | time-to-fill, copy-paste vs typed, retry count on doc upload, geolocation drift |
| Declared wallet | Node2Vec (graph-embedding algorithm used to score blockchain addresses) address risk on declared external wallets (if applicant declared one for funding) |
| Synthetic identity | SSN-DOB-name correlation against credit bureau or third-party data |

### Decision Logic

```
def decide(signals, policy):
  # Hard rules first -- compliance gates
  if signals.sanctions.match == 'confirmed':
    return Decision('deny', reason='sanctions')
  if signals.sanctions.match == 'partial':
    return Decision('review', reason='partial_sanctions')
  if not signals.doc.passed:
    return Decision('review', reason='doc_quality')

  # Score-based decision
  composite = compose_score(signals, policy.weights)
  if composite >= policy.thresholds.auto_approve:
    return Decision('approve', tier=target_tier)
  elif composite >= policy.thresholds.review:
    return Decision('review', reason='composite_risk')
  else:
    return Decision('deny', reason='composite_risk')
```

### Per-Jurisdiction Decision Signal Matrix (illustrative)

| Signal | Weight (low-risk juris) | Weight (high-risk juris) | Notes |
|---|---|---|---|
| Sanctions confirmed | -inf (hard deny) | -inf (hard deny) | No score can override |
| Doc face match < 0.85 | 0 (route to review) | 0 (route to review) | Hard rule, not weight |
| Device fp on denylist | -0.8 | -0.95 | Heavier in high-risk |
| Disposable email | -0.3 | -0.5 | |
| Velocity > 3 apps/day from IP | -0.5 | -0.7 | Cap traffic from one source |
| Declared wallet Node2Vec risk | -0.4 | -0.6 | High-risk address neighborhood |
| Time-to-fill < 30s | -0.2 | -0.3 | Bot signal |
| Address-DOB correlation OK | +0.1 | +0.2 | Confirms identity |
| Auto-approve threshold | 0.55 | 0.75 | Higher bar for high-risk |
| Review threshold | 0.30 | 0.50 | More cases routed to manual |

Thresholds are jurisdiction-specific because regulators expect more conservative decisioning in higher-risk regions. The Tier Engine returns the right thresholds; the decisioning service applies them.

### Explainability

Every decision is recorded with composite score, top negative and positive signals with contributions, thresholds applied, and policy version. SHAP-style attribution if a model is part of the score; for rule-based composition, per-rule contribution. This lands in `risk_decisions.explanation`, shown to reviewers and auditable by regulators.

---

## Step 9: Manual Review Queue

When the decisioning service returns `review`, the application goes to a queue. A compliance reviewer pulls from the queue, makes a call, and writes back a decision.

### Queue Properties

SLAs: 24 hours routine, 4 hours partial-sanctions, 1 hour re-screen hits on existing users (because their account is on hold). Cases are locked to a reviewer on claim with a 4-hour lock expiry so absent reviewers don't strand cases. Routing by jurisdiction (language, regulatory expertise) and case type. Junior reviewers can escalate; cases above a complexity score auto-escalate. Dual approval required for sanctions clearance, Tier 3 approval, and any override of an auto-deny.

### Reviewer Console

Web UI shows the application with redacted PII, collected evidence (deep-link to vault behind elevated access), all signals and auto-decision explanation, and matched sanctions candidates side-by-side with applicant data. Free-form rationale is mandatory on any decision. Actions: Approve, Deny, Send back for more info, Escalate.

### Override Workflow

Override of an auto-decision requires mandatory rationale, dual approval, and auto-flag for QA. QA samples 5% of overrides for retrospective review. Every action -- not just decisions -- is logged with actor, evidence inspected, and policy version applied.

---

## Step 10: Save / Resume / Drop-off Recovery

Half of applicants don't finish in one session. The applicant abandons at the doc upload step, comes back three days later from a different device, and expects to pick up where they left off.

### How Save/Resume Works

Workflow id is stable per `(user_id, kyc_cycle_id)`. Long-running activities like `collect_document` suspend waiting for an upload signal up to 14 days. The `applications` and `kyc_steps` tables back a "you're at step 3 of 5" UI without consulting Temporal. Submissions are keyed on `(workflow_id, step, idempotency_key)` so double-clicks don't double-process.

### Reminders and Timeout

A sweeper queries `applications WHERE status='in_progress' AND last_step_at < now() - 24h AND reminders_sent < 3`, sending reminders at +1d, +3d, +7d. After 14 days the activity times out and the application moves to `abandoned`. The user can start fresh; the old workflow closes cleanly.

### Drop-off Diagnostics

The funnel is instrumented per (jurisdiction, tier, step, vendor). A spike at "selfie capture" for one vendor in one jurisdiction is a vendor or product bug, not a user problem -- Vendor Ops uses this to renegotiate or swap.

### Multi-Device Resume

Sessions are tied to the user, not the device -- start on web, finish on mobile. Resuming on a new device triggers a fresh OTP challenge and device-fp capture; resumes from bad-reputation IPs are blocked pending review.

---

## Step 11: PII Handling

KYC has the most concentrated PII in the company. PII handling is rigorous, layered, and assumes someone will eventually try to exfiltrate it.

### Vault for Documents

Documents in S3 with KMS envelope encryption: each doc has a per-document data key wrapped by a per-application KMS key. Access requires AWS IAM plus an application-level token; both are audit-logged. Lifecycle: 5-7 year retention, cryptographic erasure on expiry (drop the KMS key, the data is unreadable).

### Field-Level Encryption for Sensitive Attributes

SSN, full government ID, DOB, tax IDs are encrypted at the field level in addition to disk-level using HMAC (Hash-based Message Authentication Code):

```
applications.ssn_encrypted = AES_GCM_encrypt(plaintext_ssn, kms_data_key)
applications.ssn_token     = HMAC(plaintext_ssn, app_secret)  -- searchable
```

The deterministic token answers "does any user have this SSN?" without decrypting. Plaintext is re-derived only by services with explicit need (sanctions, reviewer console).

### Tokenization Layer

Most internal services work with tokens, not plaintext. Only the sanctions activity and reviewer console detokenize. Most of the system is PII-free by design -- a breach at the analytics layer reveals nothing.

### Access Logs

Every plaintext PII access is logged: who, when, which application, why. Logs are immutable, monitored, and reviewed monthly. A reviewer fetching 500 SSNs in an hour triggers an alert.

### Redaction in Non-Prod

Lower envs never see real PII. A redaction pipeline replaces names (consistent per user), SSNs (valid-format-but-fake), and document images (synthetic samples). There is no "dump prod into my local DB" path.

### Retention and Right to Erasure

5-7 years post-account-closure (jurisdiction-specific) via lifecycle policy and cryptographic erasure. GDPR (General Data Protection Regulation — EU data privacy law)/CCPA erasure requests are mostly exempted by regulatory retention -- we hold for the regulatory window even if asked to delete, then auto-delete. Users can self-service export their KYC data (rate-limited, logged).

---

## Step 12: Re-KYC and Event-Triggered KYC

KYC is not a one-time event. The same workflow handles new users, periodic re-checks, and event-triggered escalations.

### Periodic Re-KYC

A scheduler runs nightly to identify users due for refresh:

```
SELECT user_id, current_tier, jurisdiction
FROM users
WHERE last_kyc_at < now() - interval '24 months'
  AND status = 'active';
```

For each, a new workflow starts with `reason='re_kyc_periodic'`. The user is prompted in-app to refresh evidence (re-upload ID, re-confirm address). Failing to complete within the grace period (30-90 days) downgrades their tier.

### Event-Triggered KYC

Events that retrigger KYC:

| Event | Trigger condition | Action |
|---|---|---|
| High-volume activity | Cumulative volume crosses Tier 3 threshold | Prompt for Tier 3 evidence |
| Address change | User updates residential address | Re-verify Tier 1; if jurisdiction changes, full re-Tier-2 |
| Adverse media hit | Periodic re-screen returns adverse media | Hold + manual review |
| Sanctions list update | Existing user newly matches a list | Hold + manual review |
| Suspected synthetic identity | Downstream fraud system flags account | Re-verify with stricter evidence |
| Document expiry | ID document expiry < 30 days | Prompt for re-upload |

Each event publishes to a `kyc_triggers` topic; a consumer kicks off the appropriate workflow. The orchestrator is the same; the policy engine returns different required steps based on `reason`.

### Tier Hold During Re-KYC

Re-KYC for an existing active user puts them in soft hold, not full freeze: existing balances stay accessible, new high-risk actions (wires, new derivatives) block, and the user has a deadline to refresh evidence. Hard hold (full freeze) only on confirmed sanctions match or law enforcement request.

---

## Step 13: Anti-Bot / Synthetic Identity Defense

Adversaries try to mass-create accounts to abuse promo codes, launder funds through synthetic identities, or stage account-takeover infrastructure.

### Defenses on the Onboarding Path

Device fingerprinting at signup (canvas hash, font list, timezone, hardware) stored and checked across applications. IP reputation flags VPN/Tor/proxy ranges (not auto-block; adds score). Velocity caps on max apps per IP/device/email-domain per 24h. Adaptive captcha shown only to low-trust sessions. Disposable email/phone vendor lists. SSN-DOB-name correlation via third party. Behavioral biometrics (typing cadence, mouse movement) -- bots have measurably different patterns.

### Synthetic Identity Detection

Synthetic identity = fabricated identity using real PII fragments (real SSN of a minor, fake name). Layered defense: credit bureau cross-reference (real SSN with no credit history at age 30 is suspicious); address validation (vacant lots and commercial addresses raise score); vendor document forensics for tampering, MRZ anomalies, font inconsistencies; network behavior -- 50 accounts from one device fingerprint claiming different identities is a ring; post-onboarding transaction monitoring catches what onboarding missed.

---

## Step 14: Failure Modes

### Failure: Vendor Outage (Identity Verification)

Activity retries with exponential backoff (Temporal handles this). The vendor router detects elevated error rate and shifts traffic to the secondary vendor automatically, per-jurisdiction. If all vendors are down, the activity routes to manual review -- compliance officers verify by hand. Drop-off rises, throughput falls, but we don't lose applications. **Never auto-approve in a vendor outage.** Fail closed.

### Failure: OCR Returns Poor Quality

Re-prompt the user once with guidance ("good lighting, full document visible"). If the re-upload also fails, route to manual review with both attempts attached. A reviewer eyeballs both and decides.

### Failure: Partial Sanctions Match

Always routes to manual review with candidates attached. Never auto-deny (false positives cost goodwill); never auto-approve (false negatives are regulatory events).

### Failure: Workflow Stuck

Temporal's 30-day execution timeout is the hard cap; workflows stuck > 7 days at one step alert SRE. Sweeper for workflows in `manual_review` past SLA surfaces in a daily ops report.

### Failure: Manual Review Queue Backup

Queue depth is a paged alert at 2x SLA target. Auto-scale via on-call BPO if available. If the queue won't drain, tighten auto-approve thresholds temporarily on composite-risk cases (with compliance sign-off, accepting higher false-negative rate). Never tighten compliance-driven reviews (sanctions, adverse media).

### Failure: Tier Service Read Path Outage

Tier Service is read-replicated; failover to replicas. Consumers cache 5-10 min. **Fail closed:** if we can't confirm tier, block new high-risk actions. Allowing a $50K wire because the tier check failed is worse than 5 minutes of friction.

### Failure: Audit Log Write Fails

Use a transactional outbox: decision and audit event written in the same DB transaction; a relay ships to the audit store. Never make a decision without the audit event being durable -- reorder if necessary.

---

## Step 15: Tradeoffs Summary

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Workflow engine | Temporal (durable workflow) | Hand-rolled state machine in Postgres | Temporal gives durable timers, retries, signals, replay; rolling your own is half the system you'd build anyway |
| Vendor strategy | Multi-vendor with abstraction | Single-vendor exclusive | Vendors swap every couple years; cost negotiations require a credible swap threat; per-jurisdiction strengths differ |
| Verification mode | Async with manual fallback | Always-sync block-the-user | Verification takes 30s-5min; blocking user causes drop-off; async + status UI is the right UX |
| Sanctions on partial | Always manual review | Auto-deny or auto-approve heuristic | Auto-deny costs goodwill; auto-approve is a regulatory event. Manual review is the only correct path |
| Decision policy storage | Data table with version | Code constant | Adding a state should be config + Legal review, not a deploy |
| Tier failure mode | Fail closed (block actions) | Fail open (allow if unsure) | Allowing high-risk action without tier confirmation is worse than 5min downtime |
| PII storage | Vault + field-level + tokens | Encrypted columns only | Vault separates blast radius; tokens make most services PII-free; field-level adds an extra layer |
| Manual review override | Dual approval + QA sampling | Single reviewer authority | Override is the most consequential action; controls match the consequence |
| Re-KYC trigger | Workflow with `reason` field | Separate re-KYC service | Same code, same audit, different inputs. Forking the codebase doubles bugs |
| Drop-off mitigation | Save/resume + reminders + pre-flight checks | Force-complete-in-one-session | Half of users will leave; designing for that is the difference between 50% and 90% completion |

---

## Step 16: Common Mistakes to Avoid

1. **Treating KYC as a one-time event.** Onboarding is the trigger, not the totality. Re-KYC, event-triggered escalation, periodic re-screening, and document expiry must all flow through the same workflow primitive. Designs that treat "new user" specially and bolt re-KYC on later fail compliance two years in.

2. **Hardcoding jurisdiction rules.** `if country == 'US' && state == 'NY'` sprinkled through the codebase turns adding a single new state into a six-week project. Jurisdiction policy belongs in a table, owned by Legal, deployed via config change.

3. **No vendor abstraction.** Calling Onfido directly ties you to Onfido. When renegotiation goes sideways or quality drops in a region, the swap is a six-month project instead of a flag flip.

4. **Mutable application state across re-KYC.** Reusing a single `applications` row across cycles destroys the audit trail. Each re-KYC is a new application linked by `user_id` but separately recorded.

5. **No save/resume.** Forcing one-session completion crushes drop-off and is a multi-percent revenue hit because Tier 2 unlocks fiat ACH, which unlocks LTV. Save/resume is a business KPI, not a UX nicety.

6. **Leaking PII to logs and lower envs.** A debug log that prints the request body with SSN is a breach waiting to happen. Logs are aggregated, retained, queryable, and sometimes shipped to third-party vendors. PII never enters structured logs without redaction.

7. **Auto-deciding partial sanctions matches.** Auto-clearing creates regulatory exposure; auto-denying creates customer pain. The correct answer is manual review with documented rationale.

8. **No idempotency on submission.** Double-click Submit, two applications, both reach manual review, reviewer sees duplicates. Every submission keys on `(user_id, step, idempotency_key)`.

9. **Tier check on the slow path.** Every transaction endpoint reads tier. If the read takes 200ms, every transaction takes 200ms longer. Tier Service is read-replicated and consumer-cached.

10. **Skipping the audit log on overrides.** Reviewers can be wrong, malicious, or exploited. Every override must log actor, rationale, and evidence inspected. Without this, a single bad reviewer compromises every decision they touched and there is no forensic recovery.

---

## Step 17: Follow-up Questions

**How would you add a new jurisdiction (say, Australia) in a week?**

The architecture is built for this. Add rows to `jurisdiction_policy` for AU at each tier (Legal-owned). Confirm vendor coverage (most cover AU; sanctions vendors all carry AUSTRAC). Add AUSTRAC to the sanctions list config. Add AU-specific PII fields and i18n strings. Test with AU test data. Roll out behind a feature flag, AU IPs first. The week is mostly Legal review and QA, not engineering -- that's the goal.

**How do you handle institutional onboarding?**

Institutional KYC (KYB -- Know Your Business) is a separate workflow with different evidence: beneficial owner identification (KYC each owner above 25% threshold), corporate structure documents, source-of-funds at company level, relationship-manager-driven, SLA in days not minutes. The orchestrator pattern transfers; the activities differ. KYB calls the person-level KYC workflow for each beneficial owner, then aggregates into a company-level decision. Core abstractions (workflow_id, policy_version, audit_event) work the same.

**How would you reduce drop-off without lowering the bar?**

Pre-flight document quality checks. Smarter vendor selection per (jurisdiction, document type) by pass rate. Better in-app guidance with example images. Allow partial Tier 1 access while Tier 2 is in flight (browse, watchlist, deposit crypto while verification runs). Email reminders with deep-links to the exact step. A/B test (randomized controlled experiment) prompts and step ordering -- the order we ask for information measurably affects completion rate. None of these lower the compliance bar.

**How do you support biometric re-auth for high-value actions?**

Tier 3 wires and unusual high-value actions can require a step-up: fresh selfie face-matched against the on-file Tier 2 selfie. Reuses the identity verification pipeline (vendor abstraction, liveness). Result is short-lived (15 min) so the user doesn't re-auth every click. Logged with `event_type='biometric_step_up'` tied to the triggering action. This is an inline activity, not a new workflow.

**How does this connect to the Travel Rule (FinCEN/FATF rule requiring originator/beneficiary info on transfers above ~$3000)?**

Travel Rule kicks in post-KYC when funds move. On a withdrawal above threshold ($3K US, varies by jurisdiction), the Travel Rule system constructs an originator-info payload (name, address, account) and sends it to the destination VASP. That payload sources from the KYC application's persisted data. KYC is upstream; it must produce clean, current originator records the Travel Rule integration consumes. This is another reason re-KYC and address-change-triggered re-verification matter -- stale KYC produces incorrect Travel Rule payloads, which is a regulatory event.

---

## Related Topics

- [[../../../05-async-processing/index|Async Processing]] -- Temporal workflows, durable state, sagas, signals
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- vendor abstraction, fail-closed for tier checks, manual fallback
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- idempotency, exactly-once decision recording, transactional outbox
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- field-level encryption, KMS, append-only audit log, jurisdiction policy as data
- [[../../../02-scaling-reads/index|Scaling Reads]] -- tier read path, jurisdiction policy cache
- [[../../../08-security-and-privacy/index|Security & Privacy]] -- PII vault, redaction in non-prod, retention, right to erasure
