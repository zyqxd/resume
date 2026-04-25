# Walkthrough: Design a Checkout System (Shopify)

## Step 1: Clarify Requirements and Scope

Before drawing anything, confirm the scope with the interviewer:
- How many merchants on the platform? (Millions -- this is a multi-tenant system, not a single store)
- What is peak traffic? (BFCM scale: 284M requests/minute at edge, thousands of concurrent checkouts/second)
- Is PCI compliance required? (Yes -- card data must never touch the main application)
- Which payment providers? (Multiple: Stripe, PayPal, Shop Pay, Adyen -- need failover between them)
- Do we need to handle partial failures mid-checkout? (Yes -- a crash between charging the card and creating the order must not lose money or double-charge)

This scoping surfaces the three hardest problems upfront: **exactly-once payment semantics** (never double-charge, never lose an order), **PCI isolation** (card data in a separate trust boundary), and **multi-tenant scale** (millions of merchants sharing infrastructure, with traffic that spikes 10-100x during flash sales).

**Out of scope:** Post-purchase flows (fulfillment, returns), fraud detection (mention as a hook point in the payment step), subscription billing, cart persistence/abandonment recovery.

---

## Step 2: High-Level Architecture

```
Browser / Mobile
    |
    |  HTTPS
    v
+------------------+
| Edge / CDN       |  (Cloudflare / Shopify Edge, 284M req/min at BFCM)
| Load Shedding    |
+--------+---------+
         |
    +----v----+
    | Nginx   |  (per-pod routing, rate limiting)
    | + Lua   |
    +----+----+
         |
+--------v---------+          +-------------------+
| Rails Monolith   |          | CardSink (iframe)  |
| (Checkout        |          | PCI-isolated JS    |
|  Controller)     |          +--------+----------+
+---+-----+---+----+                   |
    |     |   |                   +----v-----------+
    |     |   |                   | CardServer      |
    |     |   |                   | (PCI scope,     |
    |     |   |                   |  tokenization)  |
    |     |   |                   +----+------------+
    |     |   |                        |
    |     |   +--- Payment Service <---+ (receives token)
    |     |              |
    |     |         +----v----+----+----+
    |     |         | Stripe  |PayPal|Adyen| (payment gateways)
    |     |         +---------+------+----+
    |     |
    |     +--- Tax Service (external: Avalara / internal)
    |     +--- Shipping Rate Service
    |     +--- Discount Engine
    |
    +--- Order Database (MySQL, sharded by shop)
    +--- Idempotency Store (Redis + MySQL)
```

### Core Components

1. **Edge / CDN** -- absorbs the majority of read traffic. During BFCM, static assets and cached storefront pages are served entirely at the edge. Checkout requests pass through.
2. **Pod-based routing** -- Shopify partitions merchants into "pods," each with its own set of app servers and database shards. A pod is the unit of horizontal scaling and failure isolation.
3. **Rails Monolith (Checkout Controller)** -- orchestrates the checkout flow. Manages the cart-to-order state machine. Only sees payment tokens, never raw card data.
4. **CardSink / CardServer** -- PCI-isolated subsystem. CardSink is a JavaScript component rendered in an isolated iframe on the checkout page. It captures card details and sends them directly to CardServer, which tokenizes them. The token is returned to the browser and submitted with the checkout form. The Rails monolith never sees the card number.
5. **Payment Service** -- takes the token and orchestrates the charge against payment gateways. Implements circuit breakers (Semian) per provider per region.
6. **Supporting Services** -- tax calculation, shipping rates, discount engine. These are non-critical in the sense that checkout can degrade (show estimated tax, cached shipping rates) if they are slow or down.

---

## Step 3: Cart-to-Order State Machine

The checkout is modeled as an explicit state machine. Every transition is persisted, making the system's state observable and recoverable after crashes.

```
                  +-----------+
                  |   CART    |  (items added, mutable)
                  +-----+-----+
                        |
                  begin_checkout
                        |
                  +-----v-----+
                  | CHECKOUT  |  (address, shipping, tax calculated)
                  +-----+-----+
                        |
                  submit_payment
                        |
                  +-----v-----------+
                  | PAYMENT_PENDING |  (charge initiated, awaiting gateway response)
                  +-----+-----------+
                        |
              +---------+---------+
              |                   |
         charge_ok           charge_failed
              |                   |
      +-------v------+    +------v-------+
      | PAYMENT_DONE |    | PAYMENT_     |
      +-------+------+    | FAILED       |
              |            +--------------+
        create_order            (retry or abandon)
              |
      +-------v-------+
      | ORDER_CREATED |  (confirmation number assigned)
      +-------+-------+
              |
        send_confirmation
              |
      +-------v--------+
      | ORDER_CONFIRMED|  (email sent, visible in admin)
      +----------------+
```

### Why Explicit States Matter

Each state is a row in the database with a `state` column and `updated_at` timestamp. This gives you:

- **Crash recovery:** If a process dies between `PAYMENT_DONE` and `ORDER_CREATED`, a background sweeper finds checkouts stuck in `PAYMENT_DONE` for more than N seconds and completes them. No human intervention needed.
- **Debugging:** You can query "how many checkouts are stuck in PAYMENT_PENDING right now?" -- a critical dashboard metric during BFCM.
- **Metrics:** Conversion funnel analytics fall out naturally from state transition timestamps.
- **Guard rails:** The state machine enforces that you cannot create an order without a successful payment, and you cannot charge a card without a valid checkout.

**Key implementation detail:** State transitions are gated by database-level constraints. The UPDATE uses optimistic locking (`WHERE state = 'PAYMENT_DONE' AND lock_version = N`) to prevent concurrent processes from advancing the same checkout.

---

## Step 4: Exactly-Once Payment Semantics (Resumption Pattern)

This is the single most important correctness property. A customer must never be double-charged, and an order must never be lost after payment succeeds -- even if the process crashes, the network partitions, or the payment gateway times out ambiguously.

### The Problem

Consider the naive flow:
1. Charge the card via Stripe
2. Stripe returns success
3. Create the order in the database
4. Return confirmation to the user

If the process crashes between step 2 and step 3, the customer is charged but has no order. If the customer retries (or the frontend retries automatically), step 1 runs again and the customer is double-charged.

### The Resumption Pattern

The solution is an **idempotency key** combined with a **durable progress record** that survives process crashes.

```
1. Client generates idempotency_key (UUID) on the frontend
   (generated once when the "Pay" button is first clicked, reused on retries)

2. Server receives checkout request with idempotency_key

3. BEGIN TRANSACTION
     INSERT INTO idempotency_records (key, state, checkout_id)
     VALUES ('abc-123', 'started', 42)
     ON CONFLICT (key) DO NOTHING
   COMMIT

4. If the INSERT was a no-op (key already exists):
     -> Load existing record
     -> If state = 'completed': return cached response (already done)
     -> If state = 'started' or 'payment_charged':
        RESUME from that point (do not re-charge)

5. Charge payment gateway (Stripe) with THEIR idempotency key
     -> Stripe also deduplicates on their side

6. UPDATE idempotency_records
   SET state = 'payment_charged', gateway_response = '{...}'
   WHERE key = 'abc-123'

7. Create order (transactionally with updating the idempotency record)

8. UPDATE idempotency_records
   SET state = 'completed', response = '{order_id: 9001}'
   WHERE key = 'abc-123'

9. Return response to client
```

### Why This Works

- **Crash after step 5 (payment charged, order not created):** On retry, step 4 finds the record in `payment_charged` state. It skips the charge and proceeds directly to order creation. The payment is not duplicated because the gateway was called with its own idempotency key.
- **Crash after step 7 (order created, response not sent):** On retry, step 4 finds `completed` state and returns the cached response. The client gets the confirmation.
- **Gateway timeout (ambiguous response):** The record is in `started` state. On retry, the gateway is called again with the same idempotency key. Stripe returns the result of the original charge (success or failure) without creating a new one.
- **Concurrent retries:** The `INSERT ... ON CONFLICT` ensures only one process executes the flow. Others see the existing record and either wait or resume.

**Production nuance:** Idempotency records have a TTL (typically 24-48 hours). After that, the key can be reused. The TTL must be long enough to cover all retry scenarios, including long network partitions.

---

## Step 5: PCI Isolation (CardSink / CardServer)

PCI DSS requires that any system handling raw card numbers is in scope for compliance audits -- an extremely expensive and operationally burdensome process. Shopify's architecture isolates card handling into a tiny, separately audited service so the massive Rails monolith stays out of PCI scope.

### Architecture

```
+--------------------------------------------------+
| Checkout Page (browser)                          |
|                                                  |
|  +-------------------------------------------+  |
|  | Main frame (Shopify Rails app)             |  |
|  | - Shipping address form                    |  |
|  | - Order summary                            |  |
|  | - "Pay Now" button                         |  |
|  |                                            |  |
|  |  +--------------------------------------+  |  |
|  |  | CardSink iframe (separate origin)    |  |  |
|  |  | - Card number field                  |  |  |
|  |  | - Expiry, CVV fields                 |  |  |
|  |  | - Communicates ONLY with CardServer  |  |  |
|  |  +--------------------------------------+  |  |
|  +-------------------------------------------+  |
+--------------------------------------------------+
         |                          |
         | Form submit              | Direct HTTPS
         | (token only)             | (card data)
         v                          v
+------------------+     +-------------------+
| Rails Monolith   |     | CardServer        |
| (sees token      |     | (PCI scope)       |
|  "tok_abc123")   |     | - Validates card  |
+------------------+     | - Tokenizes       |
                         | - Returns token   |
                         +-------------------+
```

### How It Works

1. The checkout page loads. The card input fields are rendered inside a **cross-origin iframe** (CardSink) hosted on a separate domain.
2. The customer types their card number. This data exists only inside the iframe -- the parent page cannot read it (same-origin policy).
3. When the customer clicks "Pay," the iframe sends the card data directly to **CardServer** via HTTPS.
4. CardServer validates the card, stores it in its encrypted vault, and returns a **token** (e.g., `tok_abc123`).
5. The iframe passes the token to the parent frame via `postMessage`.
6. The parent frame submits the checkout form to the Rails monolith with the token. The monolith passes the token to the payment gateway.
7. The payment gateway (Stripe, etc.) uses the token to charge the card.

### Why This Matters

- **PCI scope reduction:** Only CardSink (a few hundred lines of JS) and CardServer (a small Go/Rust service) are in PCI scope. The entire Rails monolith, every microservice, and all developer laptops are out of scope.
- **Audit surface:** PCI DSS Level 1 audit covers only CardServer infrastructure. This is orders of magnitude cheaper and faster than auditing the entire platform.
- **Security in depth:** Even if the monolith is compromised (XSS, RCE), the attacker cannot exfiltrate card data -- it never touches the monolith's memory or logs.

**Trade-off:** The iframe approach adds UX complexity (cross-origin communication, styling the iframe to match the merchant's theme). Shopify solves this with a well-documented SDK that merchants use to embed the card fields. The security benefit is worth the integration cost.

---

## Step 6: Payment Gateway Integration and Failover

The checkout system must work across multiple payment providers and handle their inevitable failures without dropping transactions.

### Multi-Provider Architecture

```
Payment Service
    |
    +--- ProviderRouter
    |       |
    |       +--- priority_list(shop, region, method)
    |       |    -> [Stripe, Adyen, PayPal] (ordered by preference)
    |       |
    |       +--- Semian circuit breaker per (provider, region)
    |
    +--- ProviderAdapter (common interface)
            |
            +--- StripeAdapter
            +--- AdyenAdapter
            +--- PayPalAdapter
            +--- ShopPayAdapter
```

### Semian Circuit Breakers

Shopify uses Semian (their open-source circuit breaker library) to isolate failures per provider per region. Each (provider, region) pair has its own circuit breaker state.

```
Semian state:
  stripe-us-east:  CLOSED  (healthy, 0.1% error rate)
  stripe-eu-west:  OPEN    (tripped, 45% error rate for 30s)
  adyen-us-east:   CLOSED  (healthy)
  adyen-eu-west:   CLOSED  (healthy)

Checkout for EU merchant:
  1. Try stripe-eu-west -> circuit OPEN, skip immediately
  2. Try adyen-eu-west -> circuit CLOSED, attempt charge
  3. Adyen returns success -> done
```

### Why Per-Region Circuit Breakers

A global circuit breaker for Stripe would be wrong. Stripe's US infrastructure might be healthy while their EU endpoint is degraded. Per-region granularity means a failure in one region does not block checkouts in another.

**Bulkhead pattern:** Each provider adapter gets its own connection pool and thread pool. A slow response from Stripe cannot exhaust the connection pool used by Adyen.

### Provider Failover Logic

```
def charge(checkout, token, idempotency_key)
  providers = provider_router.priority_list(
    shop: checkout.shop,
    region: checkout.region,
    method: checkout.payment_method
  )

  providers.each do |provider|
    next if semian(provider).open?

    begin
      result = semian(provider).acquire do
        provider.charge(
          token: token,
          amount: checkout.total,
          currency: checkout.currency,
          idempotency_key: "#{idempotency_key}-#{provider.name}"
        )
      end
      return result if result.success?
      return result if result.hard_decline?  # Don't retry card declines
    rescue Semian::OpenCircuitError
      next
    rescue Timeout::Error, Net::OpenTimeout
      semian(provider).record_failure
      next
    end
  end

  raise AllProvidersFailedError
end
```

**Critical detail:** The idempotency key sent to each provider includes the provider name (`#{key}-stripe`, `#{key}-adyen`). If we retry with a different provider after an ambiguous timeout from the first, we do not want the second provider to deduplicate against the first provider's request. Each provider gets its own idempotency namespace.

**Hard declines vs soft failures:** If Stripe returns "card declined" (hard decline), do not failover to Adyen -- the card is invalid regardless of provider. Only failover on infrastructure failures (timeouts, 5xx errors, circuit open).

---

## Step 7: Multi-Tenant Pod Architecture

Shopify serves millions of merchants on shared infrastructure. The pod architecture is how they achieve isolation, scalability, and independent failure domains.

### Pod Structure

```
                    +------------------+
                    | Global Router    |
                    | (shop -> pod     |
                    |  mapping)        |
                    +--------+---------+
                             |
              +--------------+--------------+
              |              |              |
      +-------v------+ +----v---------+ +--v-----------+
      | Pod 1        | | Pod 2        | | Pod N        |
      | 100K shops   | | 100K shops   | | 100K shops   |
      |              | |              | |              |
      | +----------+ | | +----------+ | | +----------+ |
      | | App      | | | | App      | | | | App      | |
      | | Servers  | | | | Servers  | | | | Servers  | |
      | +----------+ | | +----------+ | | +----------+ |
      | +----------+ | | +----------+ | | +----------+ |
      | | MySQL    | | | | MySQL    | | | | MySQL    | |
      | | Primary  | | | | Primary  | | | | Primary  | |
      | | + Replica| | | | + Replica| | | | + Replica| |
      | +----------+ | | +----------+ | | +----------+ |
      | +----------+ | | +----------+ | | +----------+ |
      | | Redis    | | | | Redis    | | | | Redis    | |
      | +----------+ | | +----------+ | | +----------+ |
      +--------------+ +--------------+ +--------------+
```

### Why Pods for Checkout

- **Blast radius containment:** If Pod 2's MySQL primary fails, only Pod 2's merchants are affected. Pods 1 and N continue processing checkouts normally. During BFCM, this is the difference between a localized 1-minute blip and a platform-wide outage.
- **Independent scaling:** A pod with high-traffic merchants (e.g., a merchant running a viral flash sale) can be scaled up independently -- add app server replicas, promote read replicas, increase Redis capacity -- without affecting other pods.
- **Database shard isolation:** Each pod has its own MySQL primary. Checkout writes (order creation, payment records, idempotency records) are local to the pod. No cross-shard transactions needed for a single checkout.
- **Deployment isolation:** New checkout code can be rolled out pod-by-pod. If a bug is introduced, it is caught on the canary pod before affecting the entire fleet.

### Routing a Checkout Request

1. Request arrives at the edge with the shop's domain.
2. Global router looks up the pod assignment for this shop (cached in memory, backed by a configuration store).
3. Request is forwarded to the correct pod's app servers.
4. All database reads and writes for this checkout hit the pod's local MySQL.

**Trade-off:** Pod architecture makes cross-merchant queries (analytics, platform-wide search) more complex -- they require scatter-gather across all pods. But checkout is entirely single-merchant, so this trade-off is favorable.

---

## Step 8: Graceful Degradation Under Load

During BFCM, not everything can stay fast. The system must know what to sacrifice to protect the checkout path.

### Degradation Tiers

```
Tier 0 (Normal):      All features enabled
    |
    | Traffic increases, latency rising
    v
Tier 1 (Warm):        Disable non-critical features
                       - Skip real-time personalization
                       - Use cached product recommendations
                       - Reduce analytics event granularity
    |
    | Traffic still rising, p99 > 500ms
    v
Tier 2 (Hot):         Shed non-critical page elements
                       - Serve static storefront from CDN
                       - Skip live inventory counts (show "In Stock" or "Low Stock")
                       - Defer order confirmation emails (queue, don't send inline)
    |
    | Approaching capacity, checkout latency degrading
    v
Tier 3 (Critical):    Protect checkout at all costs
                       - Queue-based admission to checkout page
                       - Return 503 for non-checkout requests
                       - Tax: use estimated tax (cached rate tables)
                       - Shipping: show flat rate options only
                       - Skip discount validation (apply discount, reconcile later)
    |
    | This should never happen
    v
Tier 4 (Emergency):   Throttle checkout itself
                       - Virtual waiting room (queue position shown)
                       - Rate limit per-shop to prevent one merchant from starving others
```

### Implementation

Each tier is controlled by **feature flags** that can be toggled per-pod or globally in seconds. Shopify uses a load-based trigger that automatically advances tiers based on:
- Edge request rate vs capacity
- p99 latency of checkout endpoints
- MySQL replication lag (if replicas fall behind, reads are stale)
- Worker queue depth for async jobs

### What This Looks Like in Code

```
class CheckoutController
  def create
    checkout = build_checkout(params)

    # Tax: degrade if tax service is slow
    checkout.tax = if degradation_tier >= 3
      TaxEstimator.estimate(checkout)  # cached rate tables
    else
      TaxService.calculate(checkout)   # real-time API call
    end

    # Shipping: degrade if shipping service is slow
    checkout.shipping_rates = if degradation_tier >= 3
      ShippingService.flat_rates(checkout)
    else
      ShippingService.real_time_rates(checkout)
    end

    # Discounts: always apply, but skip validation in emergency
    checkout.apply_discount(params[:discount_code],
      skip_validation: degradation_tier >= 3
    )

    process_payment(checkout)
  end
end
```

**Key insight:** The degradation hierarchy reflects business priority. A checkout that completes with estimated tax (off by a few cents, reconciled later) is infinitely better than a checkout that fails because the tax service is overloaded. Design each non-critical dependency with an acceptable fallback.

---

## Step 9: Scale Estimates and Data Model

### Traffic Estimates

| Metric | Normal | BFCM Peak |
|---|---|---|
| Edge requests/min | ~30M | 284M |
| Checkout initiations/sec | ~1K | ~10K |
| Payment authorizations/sec | ~500 | ~5K |
| Orders created/sec | ~400 | ~4K |

### Database Write Volume

Each checkout generates approximately:
- 1 checkout record (INSERT + 3-4 UPDATEs for state transitions)
- 1 idempotency record
- 1 payment record
- 1 order record + N line items
- ~8-12 total writes per checkout

At BFCM peak: 10K checkouts/sec * 10 writes = ~100K writes/sec across all pods. With 100 pods, that is ~1K writes/sec per pod -- well within MySQL capabilities.

### Key Tables

```sql
-- Checkout (the state machine)
CREATE TABLE checkouts (
  id BIGINT PRIMARY KEY,
  shop_id BIGINT NOT NULL,
  token VARCHAR(64) UNIQUE NOT NULL,  -- public-facing checkout token
  state ENUM('cart','checkout','payment_pending',
             'payment_done','payment_failed',
             'order_created','order_confirmed') NOT NULL,
  lock_version INT NOT NULL DEFAULT 0,
  email VARCHAR(255),
  shipping_address_id BIGINT,
  subtotal_cents BIGINT,
  tax_cents BIGINT,
  shipping_cents BIGINT,
  discount_cents BIGINT,
  total_cents BIGINT,
  currency CHAR(3),
  created_at DATETIME(6),
  updated_at DATETIME(6),
  INDEX idx_shop_state (shop_id, state),
  INDEX idx_stuck_checkouts (state, updated_at)
);

-- Idempotency records (the resumption pattern)
CREATE TABLE idempotency_records (
  idempotency_key VARCHAR(64) PRIMARY KEY,
  checkout_id BIGINT NOT NULL,
  state ENUM('started','payment_charged','completed') NOT NULL,
  gateway_response JSON,
  cached_response JSON,
  created_at DATETIME(6),
  expires_at DATETIME(6),
  INDEX idx_expiry (expires_at)
);

-- Payments
CREATE TABLE payments (
  id BIGINT PRIMARY KEY,
  checkout_id BIGINT NOT NULL,
  provider VARCHAR(32) NOT NULL,
  provider_transaction_id VARCHAR(128),
  idempotency_key VARCHAR(64) NOT NULL,
  amount_cents BIGINT NOT NULL,
  currency CHAR(3) NOT NULL,
  state ENUM('pending','authorized','captured',
             'voided','refunded','failed') NOT NULL,
  gateway_response JSON,
  created_at DATETIME(6),
  INDEX idx_checkout (checkout_id)
);
```

**Note on money:** All monetary values are stored in cents (integer) to avoid floating-point precision issues. Currency is stored alongside every amount -- never assume a default currency.

### Indexing Strategy

- `idx_stuck_checkouts (state, updated_at)` -- used by the background sweeper to find checkouts stuck in transitional states. This is a critical operational query.
- `idx_shop_state (shop_id, state)` -- used by merchant-facing dashboards to show active checkouts.
- Idempotency records are queried by primary key (the idempotency key itself) for maximum lookup speed.

---

## Step 10: Failure Modes and Recovery

Every component in this system will fail. Here is how each failure is handled.

### Failure Scenarios

| Failure | Impact | Recovery |
|---|---|---|
| Process crash mid-payment | Checkout stuck in `PAYMENT_PENDING` | Background sweeper detects stuck state, queries gateway for actual charge status, resumes or rolls back |
| Payment gateway timeout | Unknown if charge succeeded | Retry with same idempotency key -- gateway returns original result. If gateway is down, circuit breaker trips, failover to next provider |
| MySQL primary down | Pod cannot write | Automated failover promotes replica (seconds). In-flight checkouts retry. Idempotency records ensure no duplicates |
| Redis down | Idempotency cache miss | Fall back to MySQL lookup for idempotency records. Slower but correct |
| Tax service down | Cannot calculate tax | Degrade to estimated tax from cached rate tables. Flag order for tax reconciliation |
| CardServer down | Cannot tokenize cards | Checkout cannot proceed for new card entries. Saved payment methods (already tokenized) still work. Show appropriate error |
| Network partition between app and gateway | Ambiguous payment state | The resumption pattern handles this -- on retry, the gateway's idempotency key resolves the ambiguity |

### The Background Sweeper

A critical component that runs continuously, scanning for checkouts stuck in transitional states:

```
Every 30 seconds:
  SELECT * FROM checkouts
  WHERE state IN ('payment_pending', 'payment_done')
  AND updated_at < NOW() - INTERVAL 2 MINUTE

For each stuck checkout:
  IF state = 'payment_pending':
    -> Query payment gateway: "Did charge X succeed?"
    -> If yes: advance to 'payment_done', then create order
    -> If no: mark 'payment_failed'
    -> If gateway doesn't know: wait, retry on next sweep

  IF state = 'payment_done':
    -> Payment succeeded but order was not created
    -> Create the order now (idempotent operation)
    -> Advance to 'order_created'
```

This sweeper is the safety net that guarantees **no order is ever lost after payment succeeds**. It turns a potentially inconsistent crash into a delayed-but-correct completion.

### Monitoring During BFCM

The operations team watches:
- **Stuck checkout count** by state (alert if `payment_pending` count spikes)
- **Circuit breaker state** per provider per region (alert on any OPEN)
- **Idempotency record collision rate** (high rate means retries are happening -- symptom of upstream problems)
- **Sweeper execution time** (if it takes longer than the interval, the backlog is growing)
- **p99 checkout latency** by pod (detect hot pods early)

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Payment safety | Resumption pattern (idempotency keys + durable progress) | 2PC across gateway and DB | 2PC is fragile and gateways do not support it. Resumption is crash-safe and works with any gateway |
| PCI isolation | CardSink iframe + CardServer tokenization | Tokenize in the monolith (PCI-scope everything) | Reduces PCI audit scope from entire platform to one small service. Worth the iframe UX complexity |
| Circuit breakers | Semian per (provider, region) | Global per provider | Regional granularity prevents a localized provider issue from blocking globally healthy regions |
| State management | Explicit state machine in MySQL | Implicit state derived from event log | State machine is simpler to query, debug, and alert on. Event sourcing is overkill for checkout state |
| Multi-tenancy | Pod-based sharding (shops to pods) | Single shared database cluster | Pod isolation limits blast radius. A pod failure affects thousands of shops, not millions |
| Degradation | Tiered feature shedding with fallbacks | All-or-nothing availability | Completing a checkout with estimated tax is better than failing the checkout entirely |
| Money storage | Integer cents + explicit currency column | Floating point or implicit currency | Eliminates rounding bugs. Every money column has a currency -- never assume |

---

## Common Mistakes to Avoid

1. **Treating payment as a synchronous request-response.** Payment gateways can timeout ambiguously. If you do not plan for "I don't know if the charge succeeded," you will either double-charge (by retrying naively) or lose orders (by assuming failure). The resumption pattern with idempotency keys at both your layer and the gateway's layer is the correct approach.

2. **Putting card data anywhere near the monolith.** Even logging the card number accidentally puts your entire application in PCI scope. The CardSink/CardServer architecture exists specifically to make it physically impossible for the monolith to see card data. The iframe is a security boundary, not a UI convenience.

3. **Using a single global circuit breaker per payment provider.** Stripe's US region can be healthy while EU is degraded. If your circuit breaker is global, a problem in EU blocks checkouts in US. Always scope circuit breakers to (provider, region) at minimum.

4. **Forgetting the background sweeper.** The idempotency pattern handles retries from the same request, but what about a process that dies and never retries? You need an independent process that scans for stuck checkouts and completes or rolls them back. Without this, you will accumulate orphaned charges over time.

5. **Degrading checkout before degrading everything else.** During a traffic spike, the instinct is to shed load uniformly. Wrong. Checkout is the revenue path. Shed product recommendations, analytics, personalization, and non-essential page elements first. Checkout should be the last thing to degrade, and even then, degrade the non-critical parts of checkout (estimated tax, flat-rate shipping) before touching the payment path.

6. **Storing money as floating point.** `0.1 + 0.2 != 0.3` in IEEE 754. Use integer cents or a decimal type. Store currency alongside every monetary value -- a system processing multi-currency transactions cannot assume USD.

7. **Ignoring the "retry with different provider" idempotency key collision.** If you use the same idempotency key for both Stripe and Adyen, and Stripe timed out ambiguously, Adyen will not deduplicate -- it has never seen that key. But if Stripe later confirms the charge succeeded, you have charged twice across two providers. Namespace your idempotency keys per provider.

---

## Related Topics

- [[../../../03-scaling-writes/index|Scaling Writes]] -- idempotent writes, exactly-once semantics, sharding by shop
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- circuit breakers (Semian), graceful degradation tiers, chaos engineering (Toxiproxy)
- [[../../../05-async-processing/index|Async Processing]] -- background sweeper, deferred confirmations, saga pattern for checkout steps
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- distributed state machines, idempotency across network boundaries
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- MySQL sharding by pod, optimistic locking, index strategy for operational queries
- [[../../../08-api-gateway-and-service-mesh/index|API Gateway & Service Mesh]] -- edge load shedding, per-pod routing, rate limiting during BFCM
