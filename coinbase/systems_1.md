## Prompt 1: Design a Peer-to-Peer Money Transfer System (Venmo / Cash App)

Most likely prompt. Tests ledger, idempotency, fraud, notifications, KYC.


## Questions
- Whats the scale? 10M users? 100M? => 50M users
- Peak TPS?                         => 100 TPS, spike 10x
- Cross border? Single currency?    => US only

## Deep dives
1/ Ledger 
2/ ACH
3/ Risk
4/ Notifications
5/ Socials

### Ledger
We want strong consistency, so we choose postgresql over dynamoDB. FK to accounts and multi-row transactions for atomicity. Trade off is slower writes (50ms). We can mitigate this by sharding psql instances on user_id

We use a double ledger system, a credit and a debit ledger. Each transaction is a debt and a credit on from and to account ids respectively. By doing so, we get transaction history for free where as mutating account balance rows out need additional tracking. Trade off is that account balance is then derived from this ledger, which is an expensive compute. We can mitigate this with read-side caching using redis. Cache can be updated after a transfer.

- *"What happens if the user double-taps the send button?"*
To avoid double sends, we want to reach for idempotency keys to deduplicate multiple requests for the same intended transfer. Keys can be generated from the client (user_id, intent_id), and passed through the system. We can introduce the resumption pattern (transactions table with checkpoints along side operational path)

- *Why not mysql over psql? 1000 TPS makes sense for a single instance of psql, but psql cannot shard where mysql can*
For 1000 TPS, we have not reached the threshold to require multi-shard psql. A well tuned psql instance can handle 10,000 writes per second, making our spike traffic well within operational bounds. Stick with a primary with read replicas to reduce load.

Honestly both work for this scale — real teams pick on familiarity. If I have to defend on a single technical axis: **Postgres is strict by default, and for a ledger strict-by-default is a virtue.** Concrete: MySQL silently ignored CHECK constraints until version 8.0.16 (2019); Postgres has enforced them since forever. I want financial invariants like `amount > 0` in the schema as a last line of defense, not just in app code. Postgres also has stronger default isolation (Serializable Snapshot Isolation available natively) and no silent type coercion — both matter for money.

MySQL with Vitess wins at hyperscale sharding, but we're not there. If we hit data-residency or storage-growth constraints later we'd revisit; today strictness wins.

> **Aside — partial unique indices for idempotency keys.**
> A partial index in Postgres is a unique constraint scoped by a `WHERE` clause. For idempotency:
>
> ```sql
> CREATE UNIQUE INDEX idx_transfer_idempotency
> ON transfers (user_id, intent_id)
> WHERE intent_id IS NOT NULL
>   AND status NOT IN ('cancelled', 'expired');
> ```
>
> Two things this gets us:
> 1. **NULL-tolerant uniqueness.** System-initiated transfers without a client `intent_id` aren't constrained — the index only enforces uniqueness when the client provided a key.
> 2. **Reusable keys after terminal failure.** If a previous transfer with this key was `cancelled`, the partial predicate excludes it from the index so a new transfer with the same key succeeds. Without this, a user whose first attempt was hard-rejected would be permanently blocked from retrying with the same client key.
>
> The DB-level dedup is the *last line of defense* — application-layer dedup on the same key catches most cases first. But the partial unique index is what prevents a race condition where two concurrent inserts both pass the application check and both try to write.

- *If we shard on user_id, how do we handle transactions across two shards?*
Transaction flow starts from transferer shard to transferee shard along kafka. The state machine is persisted in the transferer shard since that's the start of the transaction flow. Worth noting if we have a reverse payment flow (requesting money), this should sit on the transferee shard (person receiving the money)

- *"What if the recipient's account is frozen?"* 
Saga with compensation. Happy path flow goes debit -> credit, but at any failure, we want to reverse the operation and compensating along the way. No deletes, append only a compensating row showing that the operation failed. Move state machine into the appropreiate state.

### ACH
ACH settlement takes multiple days (1-3) and can be returned up to 60 days for consumer. This workflow needs a durable state and orchestration. We choose Temporal here since our requirements are first class features. Trade off is additional complexity, and the decision to do self-hosted or cloud (temporal.io) which includes cost per workflow and action.

- *"What does Alice see in the app 2 seconds after hitting Deposit $100, and what's that number actually backed by?"*
Two pieces of state: `available_balance` (settled, fully spendable) and `pending_balance` (credited optimistically but not yet ACH-settled). The UI shows `available + pending` so Alice sees $100 immediately, but pending is **display-only** — it's not spendable until settlement. This is the conservative / fail-closed model; the alternative is Cash App-style instant-credit-with-spendability where the platform absorbs ACH-return losses.

- *"5 minutes later, can Alice send Bob $80? What about 5 days later? What's the rule for what's spendable?"*
All outbound checks `available_balance` only — in-app transfer, ACH out, future crypto buy, all of it. Pending never funds an irreversible (or potentially-reversible-against-us) operation. So 5 minutes after deposit, Alice cannot send Bob $80 from the deposited funds; if she had $80 of available beforehand she can use that. After ACH settles (T+1 to T+3), pending → available and she can now send.

This is fail-closed by default. Cost: 3-day UX wait on first deposits. Benefit: no platform-loss absorption, no transitive clawback chains, no risk of pending dollars funding a crypto withdrawal that can't be reversed. Coinbase's product reality has more irreversible operations than a pure P2P app, so the conservative model maps better.

- *"45 days after the deposit, Alice has already spent the $100. Her bank issues an ACH return (R10 / R01). What's our system's state, and what's Alice's balance?"*
ACH returns are **non-rejectable** under NACHA rules — the receiving institution must honor them. So we can't refuse.

In the conservative model this is much less catastrophic than it would be in the lenient model: pending never propagated, so only Alice's account is affected. The compensating workflow:
1. Receive return event from bank → signal the original deposit workflow into a `RETURNED` state
2. Append a reversing journal entry for the original credit
3. If Alice's `available` is positive, debit it; if it goes negative, account flips to a "negative balance / collections" state
4. Block further deposits + outbound until resolved; attempt ACH pull from a backup funding source if one exists; eventually charge-off as bad debt if uncollectable

The recovery is a real liability but bounded to the original depositor. Risk gates at deposit time (per-user deposit caps, fraud scoring on deposit patterns) limit blast radius further.

- *"Sketch the Temporal workflow state machine for an ACH deposit. What are the states, what events transition between them, and how long can the workflow run?"*
???

- *"What about ACH returns 5 days later?"* 
Our system should be able to handle async requests. Once we get a reply from ACH (settled vs rejected), we can utilize a temporal signal to update our workflow's state.

- *"Why Temporal over a status column on the deposits table plus a cron job that polls for state transitions?"*
ACH workflows live ~60 days end-to-end (settlement at T+1–3, but the consumer return window keeps the workflow alive ~60 days post-settle). A status-column-plus-cron approach has to keep that state observed, retried, and recoverable for two months — every primitive (durable state, replay-safe activities, external signals from NACHA, crash-resume) becomes hand-rolled. Temporal gives all of this as primitives. Cost: cluster ops or per-action pricing; for a 60-day workflow this is real, but worth it because the alternative is a custom orchestrator we'd build badly.

### Risk (abridged — breadth-only for this role)

Risk is a first-class concern but not a deep-dive area for Consumer-Retail Cash. Cover at breadth, name-drop the patterns, pivot back if pushed deeper.

**Framing:** Money paths fail-closed. Risk runs synchronously inline before any debit; the latency cost (50-200ms) is the price of correctness. Compliance gates (OFAC, KYC tier) are non-negotiable.

**Gate ordering, cheap-first** (so we fail fast on the easy rejections):
1. Auth / 2FA — already handled at API layer
2. KYC tier check — does this user's tier permit this transfer size?
3. Velocity limits — per-asset, per-day caps from a Redis counter
4. Recipient allowlist — 48-hour cooldown on first sends to a new recipient
5. OFAC sanctions screening — sender + recipient against SDN list
6. ML fraud score — the expensive call, last
7. Policy gate — combine all signals into allow / block / challenge / review

**Score / Decide / Act separation** — three independent layers (named in the Coinbase crash course):
- *Score:* ML model produces a risk number. Versioned, shadow-deployable.
- *Decide:* Policy bundle (rules + thresholds) maps score → action class. Policy is data, not code.
- *Act:* Plumbing executes the action (block, 2FA challenge, manual review queue, allow). Audit-logged per decision.

This separation lets us tune thresholds without redeploying models, ship new models in shadow before A/B ramp, and add new enforcement actions independently.

**Cold-start (new users with no history):** tier-based defaults. New unverified user = small per-day limits and longer holds. As the user accumulates clean history (settled deposits, no chargebacks), tier upgrades unlock higher limits. KYC level gates the ceiling.

**Failure outcomes are not just block-or-allow.** Possible terminal states for a flagged transfer: hard block, 2FA step-up challenge, manual review queue (human-in-the-loop), velocity reduction (allow at lower amount), shadow-allow (log but permit, used during model rollout). Alice sees a clear reason or a generic "review pending" depending on the action — never reveal the specific signal that triggered the gate (anti-evasion).

**OFAC** is structural: sanctions list ingested daily, every new transfer screened, *and* periodic re-screening of existing users when the list updates. A new SDN match on an existing user freezes the account immediately and routes to compliance team — handled out-of-band, not by the user-facing app.

**Going deeper if asked:** be ready to talk about adversarial robustness (rate-limited feature lookups so attackers can't probe the model), explainability (feature snapshot + model version stored per decision for regulatory review), and online/offline feature parity for ML serving. But these belong on a fraud-team interview loop, not Consumer-Retail Cash.

