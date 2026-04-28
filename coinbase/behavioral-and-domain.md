# Coinbase: Behavioral + Domain (Tech Project Leadership) Prep

Recruiter signal: **pick the more technical project for domain.** That's FARM (ML integration, 2-way Snowflake/Databricks pipeline, multi-vertical data quality). Cash Neighborhoods is the better behavioral spine — XFN/org complexity, 4 partner teams, security-bar negotiation, network-bridge thesis. Use them in tandem; don't mix them up.

Anchor lines to repeat:
- **Mission:** "increase economic freedom in the world."
- **Principles to name when natural:** #SecurityFirst, #ExplicitTradeoffs, #OneCoinbase, #1-2-Automate.
- **Tone:** direct, metric-led, owns the call. No hedging.

---

# Domain Round — Tech Project Leadership (FARM)

This round wants: depth of technical expertise, justified decisions, ownership of a real outcome. Treat it like system design with a real story attached. Lead every choice with the rejected alternative.

## Opening (60–90 seconds, memorize)

> "FARM — Fully Automated Recurring Marketing — is Square's text-message marketing product: modular content like coupons and item recommendations sent on a recurring cadence to a seller's customer base. I led FARM through two milestones as engineering DRI.
>
> **Milestone 1 — Beta**, scoped to Food & Beverage. The core technical work was turning Automatron, our one-shot marketing automation service, into a recurring one without breaking any of the legacy automations sharing its tables. We layered heuristic item recommendations and coupons on top and shipped to ~6K F&B sellers.
>
> **Milestone 2 — TMM-GA**: expand beyond F&B, replace heuristics with a covariance ML model, and migrate the send orchestration to Temporal. We took it from 6K to 32K sellers, and the ML integration drove an 11% lift in customer win-backs and 35% lift in first-time buyer engagement."

Then pause. Let them pick the milestone — or the thread within it.

## How to navigate the round

The two milestones map onto two interview shapes:

- **Milestone 1 (Beta) is the system-design-flavored story** — concrete service modification, schema changes, idempotency. Best default thread is **Automatron**.
- **Milestone 2 (TMM-GA) is the scaling/leadership-flavored story** — three concurrent workstreams, ML integration, vertical risk. Best default thread is **the ML data pipeline** or **Temporal migration**.

If they ask for "the most technically interesting piece," go to Automatron. If they ask "what was hardest to land," go to TMM-GA orchestration.

---

# Milestone 1 — Beta (Food & Beverage)

**Scope:** Stand FARM up as a recurring-marketing product on Square's existing automation stack, restricted to F&B sellers where data was uniform enough to make recommendations and coupons viable. Ship to ~6K sellers.

**Why F&B-only as a deliberate choice:** F&B has small catalogs, predictable repeat-purchase cadence, and a tight price band — which let us ship recurrence without first solving cross-vertical data quality. We deferred the harder data problem to TMM-GA on purpose. #ExplicitTradeoff: smaller addressable beta in exchange for not blocking on a data-quality program.

## 1A — Automatron: from one-shot to recurring

**What Automatron is (set the frame in 30 seconds):**

> "Automatron is the marketing automation microservice. It listens to events and scans the contact directory for contacts matching an automation's targeting criteria, then emits an SQS event to PostOffice — our delivery service — to enqueue a send. It uses DynamoDB to keep a record per `(automation_id, contact_id)` so a contact never gets retargeted by the same automation. That dedup record is the core invariant — it's what made Automatron *one-shot by design*."

**The problem FARM created:**
- FARM is recurring marketing. The whole point is that a seller's regular customer gets a coupon every N days, not once ever. That violates Automatron's core invariant: `(automation_id, contact_id)` was a *terminal* record.
- Naive fix: delete the dedup record after each send. Rejected immediately — loses idempotency, loses audit trail, and a stuck retry could double-send.
- Second naive fix: append a timestamp to the dedup key. Rejected — turns the dedup table into an unbounded log and breaks the "have I sent to this contact for this automation" lookup that other parts of the pipeline rely on.

**What we built (two coordinated changes):**

1. **Automation record gets an interval schedule.**
   - Added a `cadence` config on the automation record itself — interval (e.g. 14 days), quiet hours, max sends per contact lifetime.
   - Static for FARM v1. The schema was deliberately ML-ready: the field is a *policy*, not a constant. Future state: the ML team scores per-contact optimal intervals and writes them per `(automation_id, contact_id)` override. We didn't build that — but we shaped the field so we wouldn't have to migrate the table to add it.

2. **Contact record gets `last_sent_at` / `next_send_at` per automation.**
   - `last_sent_at`: stamped by Automatron on successful SQS emit to PostOffice.
   - `next_send_at`: computed = `last_sent_at + cadence.interval` (with quiet-hours rounding). This is the *targeting predicate*: a contact is eligible iff `next_send_at <= now()`.
   - Crucially: the existing `(automation_id, contact_id)` dedup record stayed. Its semantic shifted from "have I ever sent" to "is this contact enrolled in this automation." Existing one-shot automations behaved identically — the dedup record's presence still blocked retargeting, because for one-shots `next_send_at` was never written.

**The targeting flow after the change:**

```
event/scan → for each candidate contact:
  if no (automation_id, contact_id) record → enroll, send, stamp last_sent_at, compute next_send_at
  if record exists AND automation is one-shot → skip (legacy behavior)
  if record exists AND automation is recurring AND next_send_at <= now → send, restamp
  else → skip
```

**Tradeoffs to name explicitly (lead with the rejected alternative):**

- *Stamp timestamps on the contact record over creating a `send_history` table:* a separate history table is the "clean" answer but adds a join on the hot path. We get audit history from PostOffice's send log already; Automatron only needs *next-eligible* state, which is a single field. #ExplicitTradeoff: gave up generic queryability of send history in Automatron's DB to keep the targeting predicate to one DDB read.
- *Cadence on the automation, override slot on the contact, ML writes the override:* keeps the static path and the future ML path on the same code path. The static case just has no override.
- *Keep `(automation_id, contact_id)` as enrollment, not last-send:* preserves the one-shot invariant for legacy automations on the same table. Migration was zero-rows-rewritten.
- *Compute `next_send_at` at write time, not query time:* lets the targeting scan stay an indexed range query (`next_send_at <= now`) instead of a full-table compute. At our scale that was the difference between a 30-minute scan and a 30-second one.

**Failure modes I'd pre-load (they will probe):**

| Probe | Answer |
| --- | --- |
| *"What if PostOffice fails to deliver after Automatron stamped `last_sent_at`?"* | We stamp on SQS emit, not on terminal delivery. PostOffice retries idempotently from the SQS message; if it dead-letters, an alert fires and ops re-enqueues. We chose "stamp on intent" over "stamp on confirmation" because confirmation can lag hours and would re-fire the targeting scan in the meantime. The cost: a true failed send pushes `next_send_at` forward as if it had succeeded — we accepted that as the lesser evil vs. duplicate sends. |
| *"What if Automatron crashes between SQS emit and DDB write?"* | SQS emit is the durable side. We do DDB write *first*, then SQS emit, in that order, with the SQS message carrying the `last_sent_at` we just wrote. If the emit fails, a sweeper job finds contacts with `last_sent_at` set but no PostOffice ack within N minutes and re-emits idempotently using `(automation_id, contact_id, last_sent_at)` as the SQS dedup key. |
| *"What if the cadence config changes mid-flight?"* | `next_send_at` is computed at last-send time using the cadence *as of that send*. Changing cadence affects future sends, not in-flight ones. Documented; admins were surprised by this exactly once. |
| *"How do you stop a runaway automation?"* | Per-automation kill switch + per-contact `max_lifetime_sends` cap on the cadence config. Both checked on the targeting path. |
| *"What if a contact unsubscribes between scan and send?"* | PostOffice re-checks subscription state at delivery — Automatron is not the source of truth for consent. #SecurityFirst-flavored: the safety check lives at the boundary nearest the customer, not the cheapest place to put it. |

**10x scale on Automatron specifically:**
- First bottleneck: the targeting scan. At 6K F&B sellers we scanned daily; at 32K with recurring schedules the scan runs constantly. We moved from "scan all contacts" to "scan contacts where `next_send_at <= now + window`" with an index on `next_send_at`. At 320K it'd need sharding by automation_id and a GSI strategy I'd want to think through.
- Second: SQS fan-out to PostOffice. Solved by PostOffice batching consumer-side, not Automatron's problem.
- Third: DDB hot partitions on popular automations. Mitigation we shipped: composite partition key `(automation_id, contact_id_hash_prefix)` so a single automation's writes spread across partitions.

**The line to land:**
> "The non-obvious part of this work wasn't adding recurrence — it was preserving the one-shot invariant for every legacy automation on the same table while doing it. The change is invisible to old automations and reversible if FARM had failed."

---

## 1B — Heuristic item recommendations

> *David — fill this in. I want to know:*
> - *What was the heuristic? (e.g., most-purchased-by-this-customer, most-popular-this-week, recency-weighted, something else?)*
> - *Where did it run — inside Automatron, a separate service, a batch job upstream?*
> - *What was the input data and the refresh cadence?*
> - *Any tradeoffs you remember explicitly rejecting (e.g., why not collaborative filtering, why not just bestseller list)?*
> - *What was the failure mode you were most worried about, and how did you bound it?*
>
> *Once I have these, I'll write this up in the same shape as Thread 1A — frame, what we built, tradeoffs, failure modes, scale.*

---

## 1C — Coupons

> *David — fill this in. I want to know:*
> - *What's the coupon module — fixed % off, dynamic, item-specific, basket-level?*
> - *Where does the coupon get generated and where does it get redeemed? Any integration with Square's existing POS / discount engine?*
> - *Idempotency / abuse story: what stops a customer from redeeming the same coupon twice, or one customer's coupon being used by another?*
> - *Expiry and reconciliation: how is an unused coupon cleaned up, and how does redemption settle back to reporting?*
> - *Anything you'd flag as a deliberate scope cut for beta vs. what TMM-GA needed?*
>
> *Same drill — I'll shape this into a domain-round thread once I have the inputs.*

---

# Milestone 2 — TMM-GA (Text Message Marketing General Availability)

**Scope:** Three concurrent workstreams converging on one launch — **Temporal migration** of the send orchestration, **ML integration** replacing heuristic recommendations with a covariance model, and **vertical expansion** beyond F&B. Took FARM from 6K to 32K sellers; ML drove 11% lift in win-backs, 35% lift in first-time buyer engagement.

**How I sequenced them:** foundational/Temporal first (the platform couldn't take the load otherwise), ML and vertical expansion in parallel behind that. Integration test bench gated the launch.

**Where it almost broke:** ML model retrain SLA slipped two weeks. Vertical expansion was ready, sitting idle. I made the call to ship vertical expansion behind a flag, run it on heuristics for two weeks, then flip the model on. Kept the launch date, isolated the ML risk.

**The line to land:**
> "Treat the launch as a sequence of independently shippable units, not a single atomic event."

## 2A — Temporal migration

> *David — fill this in. I want to know:*
> - *What was the orchestration before Temporal? (cron + state column? bespoke scheduler? in-Automatron logic?)*
> - *What specifically pushed you to Temporal — was it the recurring cadence, the multi-step send-and-confirm flow, retry semantics, observability, something else?*
> - *What's the workflow shape — one workflow per automation? per contact? per send? signals vs activities?*
> - *What did you put inside the workflow vs. left in Automatron / PostOffice?*
> - *Migration story: how did you move existing F&B beta automations onto Temporal without re-firing sends or losing state?*
> - *Any tradeoffs you weighed against (e.g., Step Functions, Airflow, building it in-house)?*
> - *What broke or surprised you in production?*
>
> *Temporal is a high-signal answer for staff-level system design — interviewers love probing it. Once I have your inputs I'll write this up with the failure-mode probe table the way I did for Automatron.*

## 2B — ML data pipeline (covariance model integration)

**Problem framing:**
- Existing system: heuristic ranker, daily batch refresh of seller data into our marketing DB.
- New requirement: covariance model owned by Product ML team. Models retrain *nightly* but on *their* cadence, against *their* feature store in Databricks. We needed (a) training-quality data flowing *out* to them, (b) freshly scored recommendations flowing *back in* fast enough to land in the next morning's send.
- The naive option: synchronous request-response at send time. Rejected — adds latency to a batch send pipeline and couples our SLA to theirs.

**What we built:**
- Two-way pipeline on Snowflake as the shared substrate. Outbound ETL from our system → Snowflake share → Databricks for training. Inbound: model scores landed back in Snowflake → ETL into our recommendation table keyed by `(seller_id, item_id)`.
- Cadence decoupling: their nightly retrain ran on *their* clock; our daily send job read whatever the freshest scored snapshot was, with a staleness guard that fell back to heuristics if scores were >36h old.
- Idempotency: every batch carried a `(model_version, scored_at)` stamp, so a re-run never produced ambiguous "which scores got sent" forensics.

**Tradeoffs to name:**
- *Snowflake as integration layer over Kafka:* batch-shape on both sides, no real-time need, and Snowflake gave us free auditability of exactly which feature snapshot trained which model version. Cost: we eat Snowflake compute/storage; mitigated by partitioning and TTL on the share.
- *Fallback to heuristics on staleness over hard-failing:* sends are a customer-visible cadence. #OneCoinbase-flavored — degrade quality, don't degrade trust. (Note: the heuristics fallback only existed because we'd already shipped them in Beta — Milestone 1 work paid for Milestone 2 resilience.)
- *Schema contract owned by us, not ML:* the ETL contract was versioned in our repo; ML pulled the schema, not the other way around. #APIDriven boundary so their model iterations didn't break our sends.

**10x scale probe (anticipate this):**
- First bottleneck: Snowflake warehouse contention during the inbound ETL window. Address: separate warehouses for ingest vs. send, scaled independently.
- Second: per-seller scoring rows scale `sellers × items_in_catalog`. At 32K we were fine; at 320K with retail catalogs (10K SKUs each) we'd need to cap at top-N items per seller server-side and stream rather than full-snapshot the table.

> *David — confirm or correct: was the staleness guard actually 36h, or was it different? Was the inbound ETL daily or more frequent? Anything else I'm misremembering from the spec?*

## 2C — Vertical expansion (cross-vertical data quality)

- F&B is uniform: small catalogs, predictable cadence, $5–30 price band. Health & Beauty, Retail are not — catalogs in the thousands, item-name inconsistency, $5 lipstick vs $500 hair tool in the same shop.
- The risk: a coupon module that says "20% off your favorite item" picks a $500 item by accident.
- We didn't try to fix the data — we gated *which modules each vertical could use*, by analyzing per-vertical distributions on (catalog size, price variance, repeat-purchase cadence).
- Output: a vertical-eligibility matrix in config, not code. Modules turned on per vertical as the data caught up. Concretely: H&B got recommendation modules but not percent-off coupons until pricing variance dropped below a threshold.
- Tradeoff to surface: *config-driven gating over algorithmic detection.* Algorithmic catches edge cases; config is auditable and reversible. We chose config because the cost of a bad coupon to a seller's reputation is asymmetric.

> *David — confirm the per-vertical thresholds and which modules ended up gated on which verticals at launch. Also: was there a vertical you ended up excluding entirely from TMM-GA?*

---

## Things to drop in unprompted (signals ownership)

- Cost: Snowflake compute under our team's cost center; I tracked it weekly.
- On-call: I owned the new pipeline's runbooks and was first responder for the first month post-launch.
- Observability: alert on staleness, alert on row-count drift, alert on score-distribution drift (not just freshness).
- What I'd build next: closing the human-in-the-loop on misranked recommendations — a seller-facing override that becomes training signal.

---

# Behavioral Round

Structure each answer as: **situation in 1 sentence → tension/decision → what you did → metric outcome → what you'd repeat.** Aim for 90 seconds per answer, then stop.

## Why are you leaving Block?

The honest, mission-grounded version. Don't bash Block.

> "Block did a RIF in [month] and my role was eliminated. I'm using that as a forcing function to ask what I actually want to optimize for next, not just the next title. Two things I'm prioritizing: working on a product that has real consumer stakes — money, custody, safety — where the engineering bar has to be high because the cost of being wrong is real, not just velocity. And working on a domain that has 5+ years of headroom for me to keep learning. Cash and Square gave me payments depth; crypto and onchain are the natural next step where that experience compounds rather than resets."

Variants:
- If asked harder: "I had a great five years there. The work I'm proudest of — Cash Neighborhoods — was about bridging two networks that hadn't been connected. That kind of high-leverage zero-to-one problem is what I want more of, and post-RIF I'm in a position to be intentional about where I find it."
- Don't say: layoffs, severance, "looking for new challenges."

## Why Coinbase?

Three beats. Memorize the shape.

> "Three reasons. **One — mission**: 'increase economic freedom' is the rare company mission that's specific enough to make tradeoffs against. At Block, our mission was economic empowerment for sellers and individuals; Coinbase is the global, infrastructure-layer version of the same thesis, and that's where I want to keep working. **Two — the phase transition**: Coinbase is going from exchange to onchain platform — Base, smart wallets, gasless tx. That's a zero-to-one bet on top of a profitable core, which is exactly the structure where staff engineers have the most leverage. **Three — the engineering principles match how I already work**: #ExplicitTradeoffs and #SecurityFirst aren't slogans for me — Cash Neighborhoods was a year of explicit tradeoffs against a much higher security bar than Square's, and the project FARM was where I learned that for money-adjacent systems, fail-closed beats fail-fast every time."

If asked which principle resonates *most*: **#ExplicitTradeoffs** — because the worst staff-eng failure mode is hidden assumptions, and naming the rejected alternative is the cheapest way to prevent it.

## How do you manage complexity on a project? (Cash Neighborhoods)

> "Cash Neighborhoods bridged two BUs at Block — Cash App's 60M MAU consumer network and Square's seller network — that nobody had successfully connected before. I was the engineering DRI: 6 engineers on my team, 4 partner teams, plus data, mobile, product, legal, design.
>
> The way I managed the complexity was to refuse to centralize what didn't need to be centralized. The instinct on a problem like this is to rebuild — duplicate Cash's marketing platform inside Square so we control the whole pipe. That would have cost two-plus quarters and recreated infrastructure that already worked. Instead we split responsibilities along the seam where each side was already strong: Square owned the marketing logic — templating, versioning, customer directory — and piped targeting data over; Cash owned delivery. That single decision halved the surface area of the integration.
>
> Where complexity actually came from was the seam itself. Cash ran at a much higher security bar than Square, and every flow from Square into Cash had to clear it — so we redesigned our pipeline to match. On the delivery side, Cash Messages was nervous about UGC violating carrier TOS at our volume — so I worked directly with their PM on content guardrails until we had a launch path both sides signed off on.
>
> The two moves I'd repeat: **own the seam, not both sides**, and **negotiate constraints early with the team that owns the bar** — not at launch readiness review.
>
> We shipped on schedule, hit a 7% follow-through purchase rate — 7x traditional SMS marketing — and proved the bridge thesis prior attempts had only argued for."

## How would you adapt if usage increases 10x? (live, on the project)

They'll likely apply this to whichever project you're walking through. Have both ready.

**For Cash Neighborhoods:**
- Current shape: targeting batch generated server-side at Square, piped into Cash, delivered as SMS. Most of the cost is in the *fan-out from a campaign to N recipients*, and 10x volume means 10x fan-out plus 10x delivery cost.
- First bottleneck at 10x: Cash Messages delivery throughput — that's *their* infrastructure, not ours, so the answer is *not* "scale our service." It's: tighter targeting upfront so we send fewer, more relevant messages. We were already at 7x lift over baseline; better targeting compounds.
- Second: the Square→Cash data sync. Today batch; at 10x I'd consider event-streaming the deltas to keep the steady-state load flat and only spike on campaign launch.
- Third: the security review pipeline becomes the human bottleneck, not the systems. #1-2-Automate the recurring patterns of review so legal/security only sees the novel cases.

**For FARM:**
- Bottlenecks named earlier in domain — Snowflake warehouse contention, per-seller×item table cardinality. Mitigations: separate warehouses, top-N capping, streaming inserts.
- Add: model retrain cadence is the real ceiling. At 10x sellers we'd want regional/vertical model shards rather than one global model — both for retrain time and for relevance.

**The framing line to use:**
> "10x usually breaks the *cheapest* component first, not the most-engineered one. So before scaling anything, I'd profile and find which dependency is cheapest — that's almost always where the next failure is."

## A problem that took multiple times to resolve

Pick something *real* with a clear arc of failed attempts. Cash Neighborhoods data governance is a strong candidate — fits the prompt because there were genuinely multiple stalled prior attempts before mine.

> "Cash and Square had been trying to bridge networks for years. There were at least two prior internal attempts I inherited the post-mortems from. Both stalled at the same place: the security and data governance review.
>
> The first time *we* hit it, I made the same mistake — treated it as a checklist at the end. Brought our designed pipeline to Cash security, got handed back a list of 14 issues, most of them architectural. Two-week slip.
>
> Second pass, I shifted approach: rebuilt the pipeline with their bar as the *input*, not the audit. We met weekly with their security lead during design, not after. Got down to 3 issues at review.
>
> Third pass — the one that landed — was specifically about Cash Messages' carrier-TOS concerns around UGC. Their first instinct was to block our launch. I spent two weeks with their PM going through actual content samples, building shared guardrails (length, link policy, opt-out semantics) — and we shipped.
>
> The pattern I took away: **when something has stalled multiple times before you, the failure mode is almost never the technical work — it's that the constraint owner isn't in the room early enough.** I'd repeat that for any cross-org build."

## How do you use AI day-to-day?

This question is probing two things: are you actually using it productively, and do you have a *take* on what works vs. what doesn't. Show range, not rah-rah.

**Memorized beats:**

> "Three buckets — what's worked, what hasn't, where I'm still calibrating.
>
> **Worked well:** I've moved from using AI as autocomplete to using it as a research partner for spec writing. For the FARM ML pipeline spec, I had Claude pull together pros/cons of streaming vs. batch architectures with citations to actual postmortems and papers, then I argued against its first answer to surface the weak spots. The exercise of *defending against an AI-generated counter-position* sharpens the spec faster than solo writing.
>
> Also: code review on my own PRs before I send them to humans. Burns first-round review cycles I used to spend on style and obvious bugs.
>
> **What I'd do differently:** early on I let it write too much greenfield code without scoping the surface area. The output looked good but didn't compose with the existing codebase patterns. The fix was treating it like an intern — give it 20 lines of context from the actual repo first, *then* ask. Quality jumped immediately.
>
> **Where I move significantly faster:** anything with a clear input/output contract — small refactors, test scaffolding, runbooks, migrations. I don't move faster on architecture or on debugging weird production behavior; those still benefit from carrying state in my head.
>
> **My read on it for engineering teams:** the leverage isn't 'AI writes the code.' It's that AI compresses the time from *idea* to *first concrete artifact you can argue about*. That's what changes the meeting cadence on a project."

If they push on Coinbase-specific AI angle, drop in the data quality moat point: *"Eide's piece on Coinbase's AI strategy lands the same way I think about it — model choice is interchangeable, data quality and human-in-the-loop are the moat."*

## Questions to ask them

Pick 3–4 from this list. Front-load the team/work ones; close on a strategic one to leave a strong impression.

**Day-to-day / team / work:**
1. "What's the team's split between consumer-facing product surface and platform/infra work? How does that ratio shift over a typical quarter?"
2. "Where does this team sit on the Phase 3 → Phase 4 transition? Is the work mostly serving Coinbase's existing exchange product, or building toward Base / onchain primitives?"
3. "What does the on-call rotation look like, and what's the realistic incident frequency? I want to understand the operational load before I optimize for it."
4. "What's the most recent technical decision the team made that you'd characterize as #ExplicitTradeoffs in action — where the rejected alternative was actually compelling?"

**Strategic / closing:**
5. "If I'm successful at the staff bar in the first 6 months, what does that look like concretely? What's a *bad* version of staff in this team that I should know to avoid?"
6. "What's the failure mode you've seen most often when staff engineers join from outside crypto? I'd rather hear the pattern than walk into it."

**Don't ask:**
- Compensation, RSU vesting, remote policy — recruiter handles those.
- Anything that's on the careers page or recent earnings.

---

# Tactics for the Round

- **Open every answer with the headline number or decision.** Then explain. Don't build to it.
- **Name the rejected alternative.** Every answer has one. If you can't name one, your answer is too soft.
- **Take pushback by leaning in, not defending.** "That's fair — let me think." Three-second pause. Then revise.
- **Stop talking when you've made the point.** 90 seconds is the target; 2 minutes is the ceiling.
- **Mission and principles get one mention each, max two.** More than that and it sounds rehearsed.
- **For the AI question specifically:** show you have a *take*, not just a tool list. Coinbase is screening for staff judgment, not tool fluency.
