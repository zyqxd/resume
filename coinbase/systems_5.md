## Prompt 5: Design a Crypto Trading Aggregator (Smart Order Router)

A trading service that accepts user limit orders (immediate or scheduled), cancels them, executes across many third-party external exchanges, picks the best price for the user, and notifies them on fill. Tests price aggregation, smart order routing, multi-vendor failure handling, scheduled-order durability, notification fan-out.

### Probes to address as we go

- *"What if Coinbase's or Binance's API goes down mid-order?"*
- *"What if the best price changes between price-discovery and execution? How stale can a quote be before we re-fetch?"*
- *"What if we route to an exchange and they reject our order (rate-limited, insufficient balance, market halted)?"*
- *"Scheduled orders — what's the state machine for an order that should fire at 3pm tomorrow? What if the system is down at 3pm?"*
- *"How do you avoid users gaming our pricing — arbitrage against our quotes, race-condition fills, etc.?"*
- *"What's the consistency story when a single user order fills across multiple exchanges?"*
- *"Cancel arrives after we've already routed half the order to one exchange — what happens?"*

### Functional Scope (clarify before designing)

- Spot only? (assume yes; futures changes the risk model substantially)
- Custodial — do we hold user funds, or are we non-custodial passing through to user-held exchange accounts? This is the architectural fork that shapes everything downstream.
- What "scheduled" means — fire at a specific timestamp, recurring (DCA), or conditional (price triggers)?
- Cross-exchange splitting — can a single user order route partial quantities to multiple exchanges to fill?
- Which exchanges are integrated (tier-1 only or also smaller venues with weaker reliability)?
- Latency target for "submit order → confirmed routing"?
- In scope: price aggregation, order submission, order cancel, notification on fill.
- Out of scope (probably): KYC, fiat on-ramp, withdrawal to bank, custody internals if non-custodial.

### Scale and shape

- DAU? Orders per day? Peak orders per second on volatile market events?
- Price update volume from upstream exchanges (tens of thousands of price ticks per second across N venues is typical)?
- Notification delivery channels — push, email, in-app, webhook?

### Non-functional priorities

Correctness > durability > availability > latency. Money paths fail-closed. The price-data path can degrade (stale quotes are better than no quotes, but there's a freshness ceiling beyond which we should refuse to quote).

### Deep-dive candidates

1. Price aggregation pipeline (consume from N exchange WebSockets, normalize, derive consolidated best bid/ask)
2. Smart order router (route, optionally split, handle partial fills, manage idempotency across vendors with different APIs)
3. Custody model (hold vs pass-through — this determines whether we're a brokerage or a routing service, and changes the entire architecture)
4. Scheduled order state machine (durable workflow over hours / days / weeks; same Temporal-shaped problem as ACH)
5. Notification fan-out on fill (with delivery guarantees)
6. External vendor failure handling (rate limits, downtime, divergent API semantics, idempotency keys per vendor, retries)

### Architecture

TBD
