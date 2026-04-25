# Walkthrough: Design a Payment Processing Pipeline (Shopify)

## Step 1: Clarify Requirements and Scope

Before drawing anything, confirm the scope with the interviewer:
- How many transactions per second? (Thousands of concurrent authorizations at peak -- Black Friday scale)
- Multi-provider or single gateway? (Multi -- Stripe, Adyen, PayPal, Shop Pay at minimum)
- Do we need to handle the full lifecycle? (Authorize -> Capture -> Settle, plus voids and refunds)
- Are we designing the PCI-scoped card capture too? (Yes -- the CardSink/CardServer isolation boundary is critical)
- Subscription/recurring billing? (Out of scope -- mention as extension)

The key constraint that shapes everything: **the main application must never see raw card numbers.** PCI DSS Level 1 compliance means we design an isolation boundary first and build everything else around tokens.

---

## Step 2: High-Level Architecture

```
Browser
  |
  |  1. Card entry via isolated iframe (CardSink)
  v
+--------------------+       +---------------------+
|    CardSink        |------>|    CardServer        |
|  (iframe, JS SDK)  |       |  (PCI-scoped svc)   |
+--------------------+       +----------+----------+
                                        |
                                  payment_token
                                        |
                                        v
+--------------------+       +---------------------+
|   Storefront /     |------>| Payment Orchestrator |
|   Checkout UI      |       | (Rails monolith or   |
+--------------------+       |  extracted service)   |
                             +----------+----------+
                                        |
                    +-------------------+-------------------+
                    |                   |                   |
              +-----v-----+     +------v------+     +-----v-----+
              |  Stripe    |     |   Adyen     |     |  PayPal   |
              |  Adapter   |     |   Adapter   |     |  Adapter  |
              +-----+------+     +------+------+     +-----+-----+
                    |                   |                   |
              +-----v-----+     +------v------+     +-----v-----+
              |  Stripe    |     |   Adyen     |     |  PayPal   |
              |  API       |     |   API       |     |  API      |
              +-----------+     +-------------+     +-----------+

Supporting Infrastructure:
  +------------------+  +------------------+  +------------------+
  | Payment State DB |  | Idempotency /    |  | Audit Log        |
  | (PostgreSQL)     |  | Resumption Store |  | (append-only)    |
  +------------------+  +------------------+  +------------------+
```

### Core Components

1. **CardSink / CardServer** -- PCI isolation boundary. CardSink is an iframe loaded from a separate domain; CardServer is a PCI-scoped microservice that tokenizes card data and returns a `payment_token`. The Rails monolith never touches raw card numbers.
2. **Payment Orchestrator** -- the brain. Receives a `payment_token` + order details, selects a gateway, runs the payment through the state machine, handles retries and failover.
3. **Gateway Adapters** -- normalize each provider's API into a common interface. Each adapter knows provider-specific retry semantics, error codes, and idiosyncrasies.
4. **Payment State DB** -- stores the canonical payment record and its state machine transitions.
5. **Resumption Store** -- tracks idempotency keys and checkpoint state for exactly-once semantics.
6. **Audit Log** -- append-only log of every state transition, gateway request/response, and decision point.

---

## Step 3: PCI Isolation -- CardSink and CardServer

This is the first architectural decision to nail because it constrains everything downstream.

### How It Works

```
Browser                          Shopify Infrastructure
+---------------------------+    +---------------------------+
|  Checkout Page             |    |                           |
|  +---------------------+  |    |   CardServer              |
|  | CardSink (iframe)   |-------->  (PCI-scoped service)    |
|  | card.shopify.com    |  |    |   - Receives raw PAN      |
|  | - Card number       |  |    |   - Validates card        |
|  | - Expiry            |  |    |   - Tokenizes via vault   |
|  | - CVV               |  |    |   - Returns payment_token |
|  +---------------------+  |    +---------------------------+
|                           |                |
|  Checkout JS receives     |<--- payment_token (not card data)
|  token, submits order     |
+---------------------------+
```

### Why an Iframe?

The iframe is loaded from a different origin (`card.shopify.com`), so the parent checkout page **cannot** access its DOM or intercept the card data via JavaScript. This is the same pattern Stripe uses with Stripe Elements. Even a compromised merchant storefront JavaScript cannot exfiltrate card numbers.

### PCI Scope Minimization

Without this pattern, every server that touches card data is in PCI scope: your web servers, load balancers, application servers, databases, logging infrastructure, developer laptops. With CardSink/CardServer, only the CardServer cluster and its immediate infrastructure are in PCI scope. This reduces audit surface from hundreds of systems to a handful.

**Key detail:** CardServer is a separate deployment with its own network segment, its own CI/CD pipeline, its own access controls, and its own logging (which must redact or never log card data). Engineers working on the checkout flow in the Rails monolith do not need PCI clearance.

---

## Step 4: Payment State Machine

Every payment progresses through a well-defined state machine. Getting this right prevents double-charges, lost refunds, and broken accounting.

```
                         +----------+
                         |  PENDING  |
                         +-----+----+
                               |
                          authorize()
                               |
                    +----------v----------+
                    |     AUTHORIZED      |
                    +--+-------+-------+--+
                       |       |       |
                  capture()  void()   expires
                       |       |       |
              +--------v-+  +--v---+  +v--------+
              | CAPTURED  |  | VOID |  | EXPIRED |
              +-----+-----+  +------+  +---------+
                    |
               settle()
                    |
              +-----v-----+
              |  SETTLED   |
              +-----+------+
                    |
               refund()
                    |
              +-----v------+
              |  REFUNDED  |
              | (full or   |
              |  partial)  |
              +------------+
```

### State Transition Rules

Each transition is an atomic database operation with a precondition check:

```sql
UPDATE payments
SET state = 'captured', captured_at = NOW(), captured_amount = $1
WHERE id = $payment_id AND state = 'authorized'
RETURNING id;
```

If the `RETURNING` clause returns zero rows, the transition was invalid (the payment was not in the expected state). This prevents race conditions: two concurrent capture attempts on the same authorization will result in exactly one success.

### Why Separate Authorize and Capture?

Many merchants authorize at checkout but capture only when they ship. This is standard in e-commerce:
- **Authorize** -- places a hold on the customer's card. Funds are not yet transferred.
- **Capture** -- actually moves the money. Can be a partial capture (e.g., only some items shipped).
- **Void** -- releases the hold without capturing. No fees incurred.

The gap between authorize and capture can be days or weeks. Authorization holds expire (typically 7 days for credit cards), so the system must track expiration and alert merchants.

---

## Step 5: Exactly-Once Semantics -- The Resumption Pattern

This is the most critical reliability mechanism in the system. Double-charging a customer is the one failure mode that destroys trust instantly.

### The Problem

A payment flow involves multiple steps (validate, route, call gateway, update DB, notify). If the process crashes between "gateway accepted the charge" and "DB updated to reflect it," a naive retry would charge the customer again.

### Resumption Pattern

Each payment operation is wrapped in a resumption context that checkpoints progress:

```
Payment Flow with Resumption:

  Step 1: Generate resumption_token (idempotency key)
          Checkpoint: { step: "INITIALIZED", token: "abc-123" }

  Step 2: Select gateway
          Checkpoint: { step: "GATEWAY_SELECTED", gateway: "stripe_us" }

  Step 3: Call gateway authorize API (with idempotency key)
          Checkpoint: { step: "GATEWAY_CALLED", gateway_ref: "ch_xxx" }

  Step 4: Update payment state to AUTHORIZED
          Checkpoint: { step: "COMPLETED" }
```

If the process crashes at any step, the next attempt loads the last checkpoint and **resumes** from there rather than restarting. If it crashes after Step 3 (gateway called successfully), it skips the gateway call and proceeds to Step 4.

### Implementation Details

```
+------------------+
| Resumption Store |
+------------------+
| token (PK)       |  -- client-provided idempotency key
| payment_id       |
| last_checkpoint  |  -- which step completed
| checkpoint_data  |  -- serialized state at that step
| gateway_idempotency_key |  -- forwarded to provider
| created_at       |
| expires_at       |
+------------------+
```

**Critical subtlety:** The resumption token must propagate to the gateway as well. When we call Stripe with an idempotency key and crash before recording the response, Stripe will return the same response on retry. This is gateway-level exactly-once. Not all gateways support idempotency keys natively -- for those, the adapter must implement "check before retry" logic (query the gateway for the transaction status before re-submitting).

### Idempotency Key Lifecycle

- Client generates the key (tied to the checkout session) and sends it with the payment request
- Server rejects duplicate keys that have already completed successfully (returns cached result)
- Keys expire after 24-48 hours to bound storage growth
- The key is hashed and stored in a unique index -- concurrent requests with the same key will result in one winner (via `INSERT ... ON CONFLICT`) and one waiter

---

## Step 6: Multi-Gateway Routing and Failover

Relying on a single payment provider is a single point of failure for your revenue. Shopify routes through multiple providers with intelligent selection and automatic failover.

### Gateway Selection (Router)

```
Payment Request
      |
      v
+-----+---------+
| Gateway Router |
+-----+---------+
      |
      |  1. Check merchant's configured providers
      |  2. Filter by: payment method, currency, region
      |  3. Rank by: success rate, latency, cost
      |  4. Check circuit breaker state
      |  5. Select primary + fallback(s)
      |
      v
+-----+----------+
| Waterfall       |
| Execution       |
|                 |
|  try: Stripe US |--fail--> try: Stripe EU --fail--> try: Adyen
|  (primary)      |          (failover 1)              (failover 2)
+-----------------+
```

### Routing Factors

1. **Region** -- prefer the provider with a local acquiring bank. A US card processed through a US acquirer has lower interchange fees and lower latency than routing through Europe.
2. **Success rate** -- track authorization rates per provider/region/BIN range. If Stripe's auth rate for Visa US drops below threshold, shift traffic.
3. **Cost** -- interchange + processor fees vary. Route to minimize cost when success rates are comparable.
4. **Payment method** -- not every provider supports every method. iDEAL goes through Adyen; Shop Pay goes through Shopify Payments.

### Waterfall Failover

When the primary gateway fails, the system falls through to the next provider. But this is where provider-specific retry semantics matter enormously:

- **Timeout with no response:** Safe to retry on a different provider? Depends. Stripe returns idempotent responses -- safe. Some providers might have processed the charge but the response was lost. **You must query the original provider for transaction status before trying another.**
- **Hard decline (insufficient funds, stolen card):** Do NOT retry on another provider. The card itself is the problem.
- **Soft decline (do not honor, try again):** May be worth retrying on the same provider or a different one.
- **Gateway error (5xx, connection refused):** Safe to failover to another provider (the original never processed the charge).

```
Retry Safety Matrix:
+----------------------+-----------+----------+-----------+
| Failure Mode         | Same GW   | Diff GW  | Action    |
|                      | Retry?    | Failover?|           |
+----------------------+-----------+----------+-----------+
| Hard decline         | No        | No       | Return    |
| Soft decline         | Maybe     | Maybe    | Depends   |
| Gateway 5xx          | Yes       | Yes      | Failover  |
| Timeout (no resp)    | Check*    | Check*   | Query     |
| Network error        | Yes       | Yes      | Failover  |
+----------------------+-----------+----------+-----------+
* Must verify with original gateway before retrying
```

---

## Step 7: Circuit Breakers (Semian Pattern)

Circuit breakers prevent a failing provider from dragging down the entire payment system. Shopify uses the Semian library (open-sourced by Shopify) for this.

### Per-Provider, Per-Region Breakers

A circuit breaker is not just "Stripe is down." It is granular:
- `stripe_us` might be failing while `stripe_eu` is healthy
- `adyen_credit_card` might be down while `adyen_ideal` is fine
- Network partition to a specific provider datacenter in one region

```
Circuit Breaker States:
                         success_count > threshold
           +----------+  ---------------------->  +--------+
           |  CLOSED  |                           |  OPEN  |
           | (normal) |  <----------------------  | (fail) |
           +----+-----+   after cooldown_period   +---+----+
                |          (enters HALF_OPEN)          |
                |                                      |
           All requests       All requests fail-fast   |
           pass through       (return error immediately)|
                |                                      |
                +---------->  HALF_OPEN  <-------------+
                              (probe: let 1 request through)
                              success -> CLOSED
                              failure -> OPEN
```

### Configuration

Each breaker has tunable parameters:
- **Error threshold:** 5 failures in 20 seconds opens the circuit
- **Cooldown:** 30 seconds before trying again (half-open)
- **Bulkhead:** limit concurrent requests to a provider (e.g., max 100 in-flight to Stripe US) to prevent thread pool exhaustion

### How It Integrates with Routing

The gateway router checks circuit breaker state before selecting a provider. If `stripe_us` is OPEN, the router skips it and selects the next provider in the waterfall. This happens transparently -- the merchant and customer never see the internal rerouting.

**Production war story:** Without per-region breakers, a Stripe US outage would trip a global Stripe breaker and route all traffic to Adyen -- even traffic from regions where Stripe was healthy. Per-region granularity keeps healthy routes open.

---

## Step 8: Shop Pay and Payment Method Vaulting

### Shop Pay (Accelerated Checkout)

Shop Pay is Shopify's own payment method. Returning customers store their card, shipping address, and billing info once. On subsequent checkouts across any Shopify store, they authenticate (via SMS OTP or biometric) and pay with one tap.

```
Returning Customer Flow (Shop Pay):

1. Customer enters email at checkout
2. System recognizes email -> offers Shop Pay
3. Customer authenticates (SMS OTP / passkey)
4. Retrieve vaulted payment token + shipping address
5. Process payment using vaulted token (skips CardSink flow)
6. Sub-second checkout experience
```

### Payment Method Vaulting

Vaulting stores a reference to a customer's card for reuse without storing the actual card data:

```
+---------------------+        +--------------------+
| Vault Record (DB)   |        | Provider Vault     |
+---------------------+        +--------------------+
| vault_token (PK)    |------->| Stripe: cus_xxx    |
| customer_id         |        | Adyen: storedPM_yy |
| last_four: "4242"   |        | (actual card data)  |
| brand: "visa"       |        +--------------------+
| exp_month: 12       |
| exp_year: 2027      |
| provider: "stripe"  |
| fingerprint: "fp_x" |  -- deduplicate same card across providers
+---------------------+
```

**Key design decision:** The vault token is provider-specific. If a customer's card is vaulted with Stripe, you cannot use that token to charge through Adyen. This limits failover for vaulted payments. Some platforms solve this by multi-vaulting (storing the card with multiple providers), at the cost of complexity and additional PCI scope interactions.

### Card Fingerprinting

To prevent duplicate cards in the vault, CardServer generates a fingerprint (hash of PAN + expiry). If a customer tries to add a card that already exists, the system returns the existing vault reference instead of creating a duplicate.

---

## Step 9: Audit Trail and Observability

In payments, every state transition, every gateway call, and every routing decision must be auditable. Regulators, chargebacks, and debugging all demand it.

### Audit Log Design

```
+---------------------------+
| Payment Audit Log         |
+---------------------------+
| id (PK)                   |
| payment_id                |
| event_type                |  -- "authorized", "captured", "gateway_timeout"
| from_state                |
| to_state                  |
| gateway                   |
| gateway_request (redacted)|  -- never log full card data
| gateway_response          |
| idempotency_key           |
| resumption_checkpoint     |
| actor                     |  -- "system", "merchant", "customer"
| metadata (JSONB)          |  -- routing decision, circuit breaker state
| created_at                |
+---------------------------+
```

This is an **append-only** table. No updates, no deletes. For high-volume systems, partition by `created_at` (monthly) and archive old partitions to cold storage.

### What Gets Logged

Every decision point, not just state transitions:
- "Selected stripe_us because: highest auth rate for Visa US (94.2%), circuit CLOSED, latency p50=180ms"
- "Failover from stripe_us to adyen_eu: stripe_us returned 503, circuit now OPEN"
- "Resumption: loaded checkpoint GATEWAY_CALLED, skipping gateway call, proceeding to update state"

This level of detail is what lets you reconstruct exactly what happened during a 3am incident or a disputed chargeback six months later.

### Monitoring and Alerting

Key metrics to track in real time:
- **Authorization rate** per provider, region, card brand, BIN range
- **Latency** p50/p95/p99 per provider
- **Circuit breaker state changes** (alert on any breaker opening)
- **Double-charge attempts** (resumption key collisions that bypassed idempotency -- this should be zero, alert immediately if nonzero)
- **Failover rate** (sudden spike means a provider is degrading)

---

## Step 10: Scale Estimates and Storage

### Transaction Volume

- Peak: 5,000 payment authorizations/second (Black Friday scale)
- Average: 500/second
- Each authorization involves: 1 DB read (resumption check), 1 external API call (gateway), 2 DB writes (state update + audit log)

### Latency Budget

Sub-second p99 for authorization means roughly:
- Gateway selection + circuit breaker check: 5ms
- Resumption store lookup: 10ms
- Gateway API call: 300-800ms (the dominant cost, varies by provider)
- DB state update + audit write: 15ms
- Total: ~330-830ms, within budget if the gateway responds quickly

The gateway API call dominates. You cannot speed it up (it is an external dependency). This is why failover latency matters -- if the primary times out at 3 seconds, you've already blown the budget before trying the fallback. Use aggressive timeouts (1-2 seconds) on gateway calls and fail over quickly.

### Storage

- Payment records: ~2KB per transaction, 500M transactions/year = ~1TB/year
- Audit log: ~5KB per event, ~4 events per transaction average = ~10TB/year
- Resumption store: ~500 bytes per key, TTL 48 hours, max ~50M active keys = ~25GB

Audit log is the storage hog. Partition by month, compress old partitions, archive to S3/GCS after 90 days. Keep 7 years for regulatory compliance (searchable via data warehouse, not hot storage).

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| PCI isolation | CardSink iframe + CardServer | Full PCI compliance on monolith | Minimizes PCI scope to one service; monolith engineers need no PCI clearance |
| Exactly-once semantics | Resumption pattern (checkpoint-based) | Simple idempotency key cache | Resumption handles mid-flow crashes; simple cache only deduplicates at the entry point |
| Gateway failover | Waterfall with retry-safety matrix | Round-robin | Must respect provider-specific retry semantics; blind failover risks double-charges |
| Circuit breakers | Per-provider, per-region (Semian) | Global per-provider | Regional granularity prevents healthy routes from being blocked by regional outages |
| Vault strategy | Single-provider vault per card | Multi-provider vault | Simpler, less PCI surface; limits failover for vaulted payments (acceptable trade-off) |
| Audit storage | Append-only PostgreSQL, partitioned | Kafka + data warehouse | Simpler query model for chargeback investigation; Kafka is an option at higher scale |
| State transitions | Conditional UPDATE with row-level check | Application-level locking | DB-level atomicity prevents race conditions without distributed locks |

---

## Common Mistakes to Avoid

1. **Retrying on a different gateway after a timeout without checking the original.** A timeout does not mean the charge failed. The original gateway may have processed it successfully. Always query the original provider for transaction status before failover. Skipping this check is how double-charges happen.

2. **Global circuit breakers instead of per-region.** If Stripe US is down but Stripe EU is healthy, a global breaker kills all Stripe traffic unnecessarily. Always scope breakers to (provider, region) at minimum.

3. **Treating all declines the same.** Hard declines (stolen card, insufficient funds) should never be retried. Soft declines (do not honor) might succeed on retry. Gateway errors (5xx) should trigger failover. Conflating these leads to either wasted retries or missed recovery opportunities.

4. **Letting the monolith see card data "temporarily."** There is no "temporarily" in PCI compliance. If raw card data touches any system, that system is in PCI scope permanently until re-audited. The CardSink/CardServer boundary must be absolute.

5. **Forgetting authorization hold expiry.** Authorizations expire (typically 7 days for credit, 1 day for debit). If a merchant tries to capture after expiry, it fails. The system needs to track hold expiry and either alert merchants or auto-void expired holds.

6. **Not propagating idempotency keys to gateways.** Your system may be idempotent, but if you send the same charge to Stripe twice with different idempotency keys, Stripe will process it twice. The idempotency key must flow end-to-end: client -> your system -> gateway.

7. **Logging raw card data in error traces.** When a gateway call fails, engineers want to see the request/response for debugging. If the request body contains card data and it ends up in Datadog/Splunk, you have a PCI breach. Redaction must happen at the adapter layer before any logging.

8. **Designing refunds as a simple state flip.** Refunds are their own payment flow -- they can fail, partially succeed, or take days to settle. Treat refunds as first-class payment operations with their own state machine, idempotency, and audit trail.

---

## Related Topics

- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- exactly-once semantics, idempotency, distributed state machines
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- circuit breakers, multi-provider failover, graceful degradation
- [[../../../05-async-processing/index|Async Processing]] -- payment state machine, event-driven settlement, webhook processing
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- audit logging, partitioning, transaction guarantees
- [[../../../08-api-gateway-and-service-mesh/index|API Gateway & Service Mesh]] -- gateway adapter pattern, provider abstraction
