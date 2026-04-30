## Project description

Cash App and Square are two massive networks owned by the same company, never connected — every prior attempt to bridge them had stalled on technical and organizational complexity across the BUs. Cash Neighborhoods was Block's latest bet on connecting Cash App users to local sellers (neighborhoods).

A Square seller joins the network, drops to 1% payment processing, and gets their Cash-side customers in the merchant directory on day one. From there they run marketing automations — winback being our best-performing — that reach those customers as story-like push notifications inside Cash App, each carrying an item recommendation and a coupon.

- **Winback automation, targeting Cash Neighborhoods customers.**
  - These are customers in the program — buyers who use Cash App at merchants in the network.
  - Winback fires when a customer made a purchase at the seller's store but hasn't returned in 14 days.
  - It was our best-performing automation.
- **Sellers** who join the network get 1% payment processing and access to their Cash-side customer base.
  - Customers in the "local" network who have visited the seller's store appear in the directory on day one.
  - Today access is via automations; blast campaigns and omni-channel marketing are next.
- **Buyers** receive a push notification into Cash App rendered as a "story-like" message.
  - The message carries an item recommendation and a coupon.
  - Tapping the push lands the buyer directly on the story screen.

I was the engineering DRI, leading a team of 4 engineers and coordinating across 3 partner teams plus XFN partners spanning data, mobile, product, legal, and design. My work split across research and technical spec writing, work planning, and running the team rituals — standups, syncs, retros.

The rest of this doc covers the two threads that defined the build: one key architectural decision — where to build it, Cash App or Square — and one major technical issue we hit during early release, when our customer linkages weren't yielding the matches we needed.

We shipped on schedule in early October. The launch pulled a 7% follow-through purchase rate from buyers — 7x traditional text-message marketing — and validated the network-bridge thesis that prior attempts had only argued for.

## Architecture - Square owns marketing, Cash owns delivery

- Square and Cash app had separate messaging platforms
  - Square: Automatron
    - Our team - start of operation
    - Cron runs daily - searches customer directory for customers that match our strategy (winback)
    - Sends events to postoffice via SQS, which is then picked up by delivery workers
  - Square: postoffice 
    - Our team. Platform for marketing messages from sellers to square customers
    - SMS and Email channels
    - Multi-tenanted - promotions are scoped to merchant
    - Rich marketing features such as templates, themes, automations
  - Square: coupons
    - Our team. Go service that issues coupons (discounts)
    - Is part of the call path at delivery
  - Cash: promoter
    - Internal message platform used for internal marketing "Try out cash app loans"
    - SMS, email, and push channels
    - Single tenant
  - Cash: cash-app-local
    - Backend powering "neighborhoods" tab 
    - Denormalize "marketing" data into "stories" store

**The decision:** Square owns the marketing logic (templating, versioning, customer directory, targeting). Cash owns the delivery rail. Local powers the app. Shared communication with RPC.

**Rejected alternatives:**
- *Rebuild in one side (either Square or Cash App).* 2+ quarters, duplicates infra. PostOffice in particular has multi-tenant templating, themes, automations — a feature set built up over years that we needed on day one. Rebuilding it inside Cash would have produced a worse copy on a longer timeline. Lifting PostOffice into Cash's environment also doesn't make sense — it still serves a large existing Square traffic load and has to keep running where it is. Rejected on both cost and long-term coupling.
- *Build a thin shared service in the middle.* Tempting — it's the "platform" answer. Rejected for v1 because nobody owned the middle, and a middle layer with no team is worse than a clear seam between two teams that do exist. Worst of both worlds.

### How a winback message gets delivered

A daily Automatron cron sweeps the Customer Directory's search endpoint for the trigger condition — "buyers who made a purchase but haven't returned in 14 days." For each match, we issue a coupon via the Coupons service, assemble a payload, and send two messages out the door:

- A **story primitive** to Cash Local (the neighborhoods tab backend). The story carries the target Cash token, the images and text, and the coupon code with its expiry. Cash Local denormalizes it into its stories store so it's ready to render in the neighborhoods tab.
- A **push notification** to Promoter, with a deep link to the story screen.

When the buyer taps the push, the app opens the story screen directly. If the story has expired by then, the deep link falls through to the neighborhoods tab so the customer still lands somewhere coherent.

SMS and email stay entirely inside Square — PostOffice owns those rails as before. Only push goes through Promoter, because push delivery into Cash App is identity-bound to the Cash customer and only Cash can issue it.

### Promoter as a single-tenant service

Promoter never became multi-tenant for this project. From its perspective it still has one tenant — Cash internal marketing — and we use it as a one-off direct-delivery channel: each push is a self-contained message we hand off with all the context it needs. Multi-tenant scoping (which Square seller, which campaign, which customer) lives entirely in our records on the Square side. Promoter only retains the delivery receipt.

This was a real scope cut. Extending Promoter into a true multi-tenant platform would have meant a separate engagement with the Promoter team and probably its own quarter of work. Treating it as a delivery primitive instead let us ship without that dependency.

### Data governance — what crossed the seam

Square → Cash data flows had to clear Cash's data-handling bar. The rule we landed on: transaction information is fine (amounts, item references, dates), anything that identifies the buyer or seller by name is not. So a coupon for "$5 off your next pizza" is fine; "Hi Mark, here's $5 off your next pizza from Joe's" is not.

Two enforcement points:
- **Outbound payload review.** Templates and content were reviewed against the PII rule before they could ship.
- **Logging obfuscation.** We added an obfuscation layer to our logger framework so that even when a payload was logged for debugging, the obfuscated fields didn't leak. This was the load-bearing piece, because logs travel further than payloads do.

The rest was paperwork — formal review with Cash's data governance team, signoffs documented, no system change required.

### Failure modes and idempotency

- **Promoter is down or slow.** PostOffice sees a failed delivery and retries with exponential backoff. If no successes land within SLO, oncall is paged. The send keeps trying until it succeeds, drops out the back of retry, or someone intervenes — no silent loss.
- **Retries don't double-send.** Every delivery is idempotent on `(merchant_id, promotion_id, customer_id)`. If the same logical send reaches Promoter twice, only one push goes out.
- **Search automation runs twice.** A missed daily cron is recovered the next day; an extra run is absorbed by the same idempotency key.

### Search automations vs event-driven

Most automations on PostOffice are event-driven — a buyer makes a purchase, an event fires, the automation reacts. Winback is different: the trigger condition is the *absence* of an event ("buyer hasn't transacted in 14 days"), and there's nothing to listen to. So winback is a **search automation** — Automatron runs a daily search against the Customer Directory's search endpoint and treats the result set as the trigger.

This is why winback is a cron rather than a stream consumer — and it's also why it has the cold-start problem described next.

### Automatron SQS vs Kafka

Today Automatron emits jobs to PostOffice over SQS. This is pre-existing tech debt and I'd argue it should be Kafka instead. The pain shows up on cold-start automations.

**The cold-start problem.** When a seller creates a new automation — say, "winback every customer who paid me but hasn't been back in 14 days" — the first run sweeps the entire customer directory and emits a flood of jobs all at once. PostOffice handles the surge fine on its own; it's built to be highly concurrent. The problem is downstream. Workers fan out in parallel and call services like the catalog to enrich each message, and the catalog gets overwhelmed by the sudden concurrency.

**Why caching alone didn't fix it.** The natural fix was to cache catalog data per merchant — most jobs in a single automation run hit the same handful of catalog rows. But because SQS workers pull jobs in parallel with no affinity, every worker on the cold-start surge hits an empty cache at the same time and races to fill it. A thundering herd on the catalog, just one layer down. The cache helped steady-state but didn't solve cold-start.

**Why Kafka fits better.** The key insight: we don't actually want parallelism *within a single merchant's surge*, because every job in that surge hits the same catalog rows. We want parallelism *across* merchants. Kafka gives us exactly that.

- **Tune parallelism with partition count, not backlog.** We pick the topic's partition count to match the throughput we want — say 256 partitions and 256 worker slots. That's still highly parallel; we're processing 256 merchants' work simultaneously. The difference is the ceiling is *chosen*, not driven by how many messages are queued.
- **Partition by `merchant_id` to warm caches naturally.** Every job for a given merchant lands on the same worker. That worker fills the catalog cache once on the first job and reuses it for the rest of the surge — no race, no thundering herd. Other merchants' surges run in parallel on other workers, each warming their own cache once. Total throughput goes up; catalog QPS goes down.
- **Backpressure for free.** If catalog gets slow, Kafka consumers slow down with it. Lag grows but nothing is dropped or DLQ-bounced. SQS gives us the opposite — workers keep pulling, downstream falls over, retries pile up in the DLQ.
- **Replay is cheap.** A botched automation run can be reprocessed from a known offset without re-running the directory scan. SQS replay is per-message and harder to reason about.

So the framing flip is: SQS gives unbounded parallelism *with no affinity*, which is the worst possible shape for a workload that's bursty, correlated, and downstream-sensitive. Kafka gives bounded but tunable parallelism *with affinity*, which is exactly the shape we want.

**Handling large sellers — split enrichment from delivery.** The simple "partition by `merchant_id`" answer falls apart the moment a large seller comes down the pipeline. If one merchant has 100K customers in a winback surge, partitioning by merchant id funnels all of it through a single worker and we lose the parallelism we need at the delivery edge.

The fix is to recognize that two different jobs are happening on the same surge, and they want different parallelism shapes:

1. **Enrichment** — look up the catalog rows, render the template, mint the coupon. This is the cache-sensitive work. We *want* serialization per merchant here so the cache fills once and serves the rest.
2. **Delivery** — hand the rendered message to PostOffice / Cash Local / Promoter. The message is fully self-contained; there's no shared dependency that benefits from affinity. We *want* unbounded parallelism here.

Two-stage pipeline:
- **Stage 1 (enrichment topic):** partition by `merchant_id`. A surge for one merchant lands on one (or a small number of) workers, the catalog cache warms once, and every job in that surge reuses it. Output is an enriched, fully-rendered message written to a second topic.
- **Stage 2 (delivery topic):** partition by `customer_id` (or anything with no affinity requirement). Delivery workers fan out as wide as the partition count allows. A large seller's 100K-customer surge spreads across the full pool, exactly the parallelism we want.

For a *very* large seller whose enrichment alone is too slow on a single worker, we'd sub-partition stage 1 by `(merchant_id, customer_id % N)` — the surge spreads across N workers within that merchant, but each one still only sees that merchant's catalog so the cache still works. N is tunable; for most sellers it's 1.

The cost of all this is operational — Kafka is heavier to run than SQS, and a two-stage pipeline has more moving parts — but the workload's defining shape is *correlated upstream, parallel downstream*, and that's exactly what two stages give us.

## Architecture — Customer matching

```mermaid
flowchart LR
    POS[Square POS] -->|payment event<br/>fidelius + optional cas_token| Kafka[(Square payment<br/>Kafka topic)]
    Backfill[backfila] -->|1 year payment histroy| CM
    Kafka -->|forward fill| CM[customermapping<br/>stateless lambda]

    CM -->|cas_token present<br/>resolve to internal id| Cash[Cash token resolver]
    CM -->|no cas_token<br/>fallback by fidelius| SQLO[SQLO<br/>fidelius ↔ cash_customer]

    CM -->|write linkage| Store[(Customer Directory store)]
```

Precedence: payment-event link wins over SQLO (POS `cas_token` is strongest signal, robust to card-sharing). `customermapping` is the stateless matcher; the Customer Directory service reads the resulting linkage store to power both the merchant client and Automatron.

---

Square and Cash App had two separate customer databases that didn't share IDs. On the Square side a customer was an opaque token like `ABC`. On the Cash side, every customer had an internal token (`c_0123`) and an externally-shareable one (`cas_0123`). To power winback, we needed to connect both the customer profiles *and* the payments those customers made, so a Square seller targeting "customers who paid me last month" could find the right Cash users.

Once we connected a Square customer to a Cash customer, we couldn't safely change that connection later. Two things would break:

- **Winback would silently misfire.** Winback fires when a customer hasn't been back in 14 days. If we mistakenly attributed customer B's payment to customer A, our system would think A had returned and skip the winback that should have gone out. There's no error to catch — the campaign just quietly underperforms.
- **The merchant's directory app would show wrong data.** Each Square customer's payment history shows up in the merchant's Customer Directory app. Re-attributing payments after the fact means rewriting that history, which is as expensive and risky as un-merging two customer profiles by hand.

So keeping the connection stable was a product requirement, not just a tech-debt concern.

### How we matched customers

We had two ways to match:

- **Profile match** — done in our `customermapping` service. We compared standard personal details (email, first/last name, address) and combined them into a single confidence score. We only accepted matches above 95%. The matching ran entirely inside Square; Cash never received Square's customer details, which kept us clear of Cash's stricter data-handling rules.
- **Payment match** — done by credit card. We used a stand-in for the card called a *Fidelius* token, issued by our internal card server. This let us reason about cards without holding actual card numbers, which would have pulled us into the strict credit-card data rules (PCI DSS).

### Which match wins when both apply

The payment event always wins. The `cas_token` attached at the point-of-sale tells us exactly which Cash customer authorized the payment. SQLO's `fidelius → cash_customer` mapping is right most of the time, but it falls apart whenever a card is shared — a family card, or a partner using a spouse's card. In those cases SQLO would attribute B's payment to A, but the live POS token wouldn't. So the rule is: trust the payment event when it's there, only fall back to SQLO when it's missing.

### Forward fill — handling new payments as they come in

Every Square payment event carries a Fidelius token. If the merchant is enrolled in Cash Neighborhoods, the event also carries the customer's external Cash token (`cas_0123`).

`customermapping` is a small stateless service (a lambda) that listens to the Square payment Kafka topic. When it sees an event with a Cash token, it asks Cash to resolve that token to the internal customer ID, then writes the connection into the Customer Directory store. This path covers customers who pay with **Cash App Pay (CAP)** or **Cash Card Pay (CCP)** — Cash's own card.

Downstream, the full Customer Directory service reads from that store to power both the merchant's directory app and Automatron (covered separately).

### Backfill — connecting customers from before they joined

A core selling point was: when a merchant joins Cash Neighborhoods, their existing Square customers show up matched on day one — not weeks later. To deliver that, we backfilled the past year of Square payments — the same window that the predecessor feature, **Cash Local**, had retained. Backfill ran through the same `customermapping` pipeline, just driven from a dedicated backfill service instead of the Kafka stream.

Forward-fill and backfill divided the timeline by a cutoff date so they couldn't fight over the same payment, and both deduplicated on `payment_id` — so retries and replays converged on a single record.

### The issue — and what fixed it

When we launched to a small pre-beta group, our matched-payment numbers came in well below what data science had projected. The expectation, based on Cash Local's history, was at least one matched payment per linked Cash customer. We weren't close.

The problem held for one to two weeks. The Customer Directory team tried fixes from inside their own scope — tightening match thresholds, replaying events — but nothing moved the number. Going into week two, I took the lead on the remediation.

The diagnosis was simple in hindsight: most Cash Local customers weren't actually paying with CAP or CCP. The `cas_token` we were counting on rarely showed up on Square payment events, so forward-fill had almost nothing to connect. The whole forward-fill design rested on an assumption — that CAP and CCP would be the dominant ways Cash customers pay — and we'd never tested it.

I pulled in our data scientist, a Cash Local engineer, and the Customer Directory lead. Together we surfaced a service we hadn't been using: **SQLO**, which already had a `fidelius ↔ cash_customer` mapping built for Cash Local's cashback matching. It was solving exactly the problem we hit. We added a SQLO lookup as the fallback when an event came in without a `cas_token`. Matched-payment volume came back to projection.

SQLO is a bridge, not where we want to end up. The proper long-term fix is upstream: have the POS attach the `cas_token` whenever a Cash customer is signed in, regardless of how they actually pay. The Fidelius cache helps in the meantime — if SQLO has an incident, only first-time-seen cards are affected; everyone else continues to match against the cache.

### Throughput

The matching pipeline sits on a high-volume topic, but each event is cheap:

- **Most events exit immediately.** About 99% of Square payment events aren't from Cash Neighborhoods merchants. Those take a single index lookup and return without any external service call.
- **Repeat customers hit a cache.** Once we've resolved a card-to-customer mapping, the next payment on the same card uses the cached answer instead of calling out again.
- **Per-event timing doesn't matter.** As long as the Kafka topic isn't backing up, we're fine. We don't need millisecond delivery into the directory.

We deliberately didn't build cache invalidation. When a card is reissued or revoked, it stops appearing in payment events at the source, so any stale cache entries naturally age out as new payments push them down. We accepted this rather than build a card-invalidation feed for v1.

### What I'd do differently

The "CAP and CCP will dominate payments" assumption was the whole foundation of forward-fill, and we never tested it. It *felt* obvious in lead reviews — "Cash Local customers are Cash customers, of course they pay with Cash" — so no one pushed on it. The cost of validating it against historical data ahead of time would have been a fraction of the cost of finding out at launch.

The lesson: when a single assumption sits underneath the design, call it out in the spec — *"this design assumes X, here's the data that confirms X"* — and treat any unvalidated one as a launch blocker, not a footnote.

## Architecture - release strategy

## Future iterations
- Cleaning up SQLO / customer matching hot paths. Right now the reliance on SQLO is a GA blocker. We need customer information to come down the payment pipeline.
- Omni-channel marketing - this is already in place. From a marketing perspective, sellers should not have to consider per-channel marketing effectiveness - we know that. We implemented omni-channel marketing as a next step - 1 promotion -> multiple channels (tmm, email, cash app)

