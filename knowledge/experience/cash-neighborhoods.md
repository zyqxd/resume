# Cash Neighbourhoods — Interview Prep

---

## 1. Project Overview (60 seconds — keep this tight)

Cash App and Square are two massive networks under Block — ~57M monthly actives on Cash App, $200B+ annual payment volume on Square — that had never been successfully connected. Every prior attempt stalled on technical and organizational complexity across the BUs.

Cash Neighbourhoods was Block's bet on bridging them: connecting Cash App users to local Square sellers. I was the engineering DRI, leading 6 engineers (4 backend, 2 mobile) and coordinating across 4 partner teams plus cross-functional partners in data, mobile, product, legal, and design.

We shipped on schedule in early October. 7% buyer follow-through purchase rate — 7x traditional text/email marketing — validating the network-bridge thesis that prior attempts had only argued for.

---

## 2. Architecture (draw this — 2 minutes max)

**What existed before:**
- Post Office (Square) — message delivery for email/SMS campaigns
- Automatron (Square) — event-based and time-based automation triggers
- Customer Directory (Square) — maps buyers to sellers via payment data
- Cash Messages (Cash App) — internal marketing platform (push notifications to iOS/Android)
- Cash App Local (Cash App) — newer service, partially built for the neighbourhoods initiative

**What we built (net new):**
- Orchestration layer between Post Office → Cash App Local → Cash Messages
- Cash notification channel (new delivery path through Cash Messages)
- Story content rendering pipeline (Instagram-like story UI for promotions)
- Data pipeline from Square → Cash that cleared Cash's higher security bar

**Key architectural decision — split responsibilities:**
The obvious path was rebuilding marketing inside Cash, but that duplicated Square infra and cost 2+ quarters. Instead, Square owned marketing logic (templating, versioning, customer targeting) and piped data into Cash. Cash owned delivery. Each side kept what it was already good at.

**Data flow:**
1. Automatron detects trigger event (e.g., lapsed customer) → SQS → Post Office
2. Post Office hydrates promotion content (template, styles, targeting)
3. Post Office calls Cash App Local via RPC (`createStory`) — synchronous
4. On success, Cash App Local calls Cash Messages (`pushNotification`)
5. Buyer sees story in Cash App, engages, purchases

---

## 3. Challenge 1: Customer Directory Data Mismatch (lead with this — 5 min)

_Use for: "Tell me about a time something went wrong" / "Cross-team dependency" / "What would you do differently"_

**The problem:**
During our tiered release (pre-beta → beta → GA), we immediately saw far fewer deliveries than our data science projections predicted. The issue was in Customer Directory — a well-established sister team responsible for mapping Cash App users to Square customers.

Cash App's account model was fundamentally different from Square's. Cash uses "facets" — when a user changes their email, they swap one facet for another. Facets have a many-to-many relationship with accounts (a facet can be reassociated to a different Cash account). Customer Directory was dropping matches whenever there was a conflict, which meant huge portions of the customer base weren't being mapped.

**What I did:**
- The tiered release strategy saved us — we caught this in pre-beta with 2 months of runway before GA
- I escalated the data gap to leadership with concrete numbers (expected vs. actual deliveries)
- Worked with Customer Directory to revise their mapping logic and run backfills
- The going-forward pipeline (Kafka CDC from Cash App) was correct; the problem was the historical backfill

**What I learned:**
I had set up weekly cross-lead syncs and everything appeared on track. But I was relying on status updates rather than inspecting outputs. In hindsight, I should have been closer to Customer Directory's work — specifically, validating match rates against our data science benchmarks earlier, not waiting for beta to surface the gap. For a project that's not technically complex but organizationally widespread, I needed to invest more in cross-team leadership and less in IC work.

---

## 4. Challenge 2: UGC Risk and the Automation-First Decision (3 min)

_Use for: "How did you shape scope" / "Product-engineering tradeoff" / "Risk management"_

**The problem:**
Cash Messages was built for internal marketing (e.g., "Try Cash Loans!"). We were the first external team using their platform at scale, and they pushed back hard — UGC from sellers could violate carrier TOS on iOS/Android. Post Office had its own content moderation (text scanning, computer vision for images — flagging nudity, violence, etc.), but Cash Messages didn't have equivalent risk arbitration.

**What I did:**
- Identified two message types with different risk profiles: blast campaigns (full UGC — "Come try my new bagel!") vs. automations (event-triggered, templated — abandoned cart, win-back, birthday coupons)
- Pushed to ship automations first — lower UGC surface area, templated content we controlled
- Deferred blast campaigns until Cash built its own risk arbitration
- Worked with Cash Messages PM to find middle ground on what content we could send at launch

**Why it mattered:**
This unblocked our October launch without compromising Cash's compliance posture. We shipped blast campaigns later after Cash's risk arbitration was in place. The decision to scope down rather than delay was what kept us on schedule.

---

## 5. Challenge 3: Last-Minute Release Strategy Change (3 min)

_Use for: "Navigating ambiguity" / "Adapting under pressure" / "Stakeholder misalignment"_

**The problem:**
Three weeks before GA (late September), at a company offsite, I discovered through informal conversations that Cash App Local had built a completely different onboarding funnel — a whitelist system with a manual admin dashboard where BizDev would hand-pick high-value merchants. This replaced our planned approach (feature flag toggle → self-service signup).

Nobody had communicated this change to our team. We had two weeks to adapt.

**What I did:**
- Assessed the gap immediately — our system assumed we were top-of-funnel, now Cash App Local was
- Designed an interim solution: Cash App Local would send an RPC call back to Post Office when a merchant cleared their onboarding queue
- First iteration was a Slack notification where BizDev manually flagged merchants for our feature flag — we knew this wouldn't scale
- Built the automated RPC flow as a fast-follow before GA, eliminating the manual step
- The architecture looked "gross" (Cash App Local calling back into Post Office when we'd designed the flow the other direction), but it worked and shipped on time

**Why it mattered:**
Demonstrated composure under pressure and pragmatic decision-making. We didn't fight the product decision or try to redesign the funnel — we adapted our integration point and automated what we could.

---

## 6. Team Leadership & Mentorship (3 min)

_Use for: "How do you lead a team" / "Mentorship" / "Engineering culture"_

**Pod structure:**
- Split 4 ICs into 2 pods of 2 — eliminated silos, ensured coverage if someone was out
- Deliberately paired my strongest engineer (someone I'd worked with before and trusted) with a more junior engineer I was concerned about
- The junior engineer ended up owning a key component of the design and shipping it successfully

**Pair programming culture shift:**
- Square's culture had minimal pairing. Cash App paired aggressively.
- When we started collaborating with Cash teams, we adopted their pairing methodology
- Block introduced dev metrics (PR count, ship velocity) as signals — team was worried pairing would hurt their numbers
- I pushed to have pair programming sessions count toward PR metrics, which removed the disincentive
- Result: more knowledge sharing, faster onboarding, better code quality

**Cross-team coordination:**
- Weekly engineering lead sync across all teams (Post Office, Customer Directory, Cash App Local, Cash Messages) + data science
- Separate weekly sync with product leadership (skip-level PM, director) — more of a presentation/alignment layer
- Used Linear with Slack integrations for async project updates — more detail and scrutiny than verbal standups
- _Retrospective:_ The lead sync may have been too large. Would add more ad-hoc 1:1s with each lead next time.

**Prior mentorship (use if asked about broader mentorship experience):**
- When I joined the Square marketing team, it was a legacy Rails app with high engineer churn and inconsistent patterns
- Led a series of 30-min technical talks for the team covering Ruby fundamentals, ActiveRecord associations, and common anti-patterns
- Brought in guest speakers from Block's Ruby guild
- Part of what qualified me for the tech lead promotion — had to demonstrate I could level up the team

---

## 7. Technical Depth (use if pushed on specifics)

_Use for: "Tell me about a technical decision" / "What tech debt did you leave behind"_

**Data governance:**
- Cash App operates as a bank — higher DLS classification required for any data flowing from Square into Cash
- I led the investigation into what PII we could send, encryption requirements, and pipeline redesign to meet Cash's bar
- This was non-trivial and blocked the project until resolved

**SQS thundering herd (mention briefly only if asked about tech debt):**
- Automatron → Post Office used SQS, which doesn't support controlled consumer scaling
- When automations turned on, 100K+ eligible users queued simultaneously, 100 Post Office workers raced to hydrate the same cache, overwhelming downstream services
- I proposed migrating to Kafka with controlled consumer groups as a fast-follow — would solve the concurrency problem and give us better backpressure
- Scoped as post-launch work; not in scope for the initial release

---

## 8. Metrics & Results (1 min)

- **7% buyer follow-through purchase rate** — 7x traditional email/SMS marketing
- **Shipped on schedule** — October GA despite 3 major roadblocks
- **Two primary metrics tracked during rollout:**
  1. Number of deliveries sent (volume/health indicator)
  2. Attributable purchases (buyer engagement signal — did the marketing message lead to a purchase within a time window?)
- **Top-line metric for Cash Neighbourhoods overall:** number of sellers onboarded (we influenced this but didn't own the lever directly — we were part of the value proposition that attracted merchants)

---

## 9. Tailoring Notes

**For Coinbase:** Lead with data governance (DLS classification, PII across BUs, Cash as a bank). Emphasize Customer Directory mapping problem — account facets, many-to-many relationships, data consistency challenges. These map directly to financial account systems.

**For Airbnb:** Lead with cross-team coordination and the release strategy pivot. Emphasize how you adapted when stakeholder alignment broke down. Airbnb values "belonging" and collaboration — the pod structure and pairing culture shift stories land well here.

**For Shopify (already done):** Balanced approach worked. They responded well to the thoroughness.

---

## 10. Common Follow-up Questions & Answers

**"What would you do differently?"**
→ Invest more in cross-team oversight, especially Customer Directory. Inspect outputs, not just status updates. More ad-hoc 1:1s with partner team leads rather than relying on group syncs.

**"How did you handle disagreements?"**
→ Cash Messages UGC pushback. Didn't force it — found middle ground by scoping to automations first. Showed I could adjust scope to unblock without compromising the partner team's concerns.

**"How did you measure success during rollout?"**
→ Tiered release (pre-beta, beta, GA) with two metrics: delivery volume and attributable purchases. Pre-beta caught the Customer Directory gap with 2 months of runway.

**"How did you prioritize?"**
→ Automation before blast (lower risk, unblocked launch). Data governance before feature work (hard blocker). Customer Directory backfill in parallel with feature development.

**"Tell me about a conflict with another team."**
→ Cash Messages UGC risk or the last-minute onboarding funnel change. Both show composure and pragmatism.
