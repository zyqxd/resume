# Walkthrough: Design Coinbase's Wallet Custody Architecture

## Step 1: Clarify Requirements and Scope

Before drawing anything, confirm the scope with the interviewer:
- Retail or institutional? (Both -- but they share the same custody backbone with different signing policies. Institutional Vaults (Coinbase's institutional custody product with quorum approvers and 48-hour cooling-off) add quorum approvers and longer cooling-off periods.)
- Which chains? (Start with BTC, ETH/ERC-20, Solana. Each has a different finality model and signing primitive -- the architecture must abstract over them.)
- Regulatory regime? (US qualified custodian -- NYDFS (New York Department of Financial Services) BitLicense (NY DFS license required to run a virtual currency business in NY), SOC 2 (Service Organization Controls Type 2 — audit framework for service providers) Type II, NIST (National Institute of Standards and Technology) SP 800-57 key management. This is non-negotiable and shapes most decisions.)
- What does "loss" mean? (Any unauthorized outbound transfer of customer funds. The system is judged not on uptime but on whether $1 of customer crypto ever leaves without authorization.)
- What threats are in scope? (External attackers, insiders, supply-chain implants on signing servers, and "$5 wrench" coercion of any single human.)

This scoping matters because custody is a security-first domain, not a throughput-first one. Most system design problems optimize for latency or QPS (Queries Per Second). Custody optimizes for *the worst-case adversary*. Every architectural decision is filtered through "what happens if this component is fully compromised?"

**Primary design constraint:** No single point of compromise -- human, key, or service -- should produce customer loss. This forces multi-tier custody, threshold signing, and segregation of duties into the *first* diagram, not bolted on later.

**Secondary constraint:** ~98% of customer crypto must live in cold storage. This is both a regulatory expectation and an insurance underwriting requirement (the $320M crime insurance policy excludes hot wallet exposure above a defined cap). Hot-tier capacity directly limits operational liquidity.

---

## Step 2: High-Level Architecture

```
                         Customer (Retail / Institutional)
                                       |
                                       | HTTPS (signed JWT, 2FA, device binding)
                                       v
                        +----------------------------+
                        |   API Gateway / WAF        |
                        |  (rate limit, OFAC pre-check)|
                        +-------------+--------------+
                                      |
                +---------------------+--------------------+
                |                                          |
                v                                          v
    +-----------------------+                  +-----------------------+
    | Withdrawal Service    |                  | Deposit Service       |
    | (state machine)       |                  | (block scanners)      |
    +----+----------+-------+                  +-----------+-----------+
         |          |                                      |
         v          v                                      v
    +--------+  +--------+                         +---------------+
    | Risk   |  | Policy |                         | Confirmation  |
    | Engine |  | Engine |                         | Watcher       |
    | (graph)|  | (rules)|                         | (per-chain)   |
    +---+----+  +---+----+                         +-------+-------+
        |           |                                      |
        +-----+-----+                                      |
              |                                            |
              v                                            v
    +---------------------+                       +-----------------+
    |  Signing Router     |                       |  Ledger Service |
    |  (tier dispatcher)  |                       |  (double-entry) |
    +----+--------+-------+                       +-----------------+
         |        |        \
         v        v         v
   [HOT TIER] [WARM TIER] [COLD TIER]
   HSM-backed  MPC/TSS    Air-gapped + multi-sig
   signers     signers    via CDS (cross-domain)
   (~2-5%)     (5-20%)    (~75-98%)
         |        |         |
         v        v         v
    +------------------------------+
    |     Broadcast Service        |
    |  (per-chain RPC / Snapchain) |
    +-------------+----------------+
                  |
                  v
         +-----------------+        +-----------------+
         | Public Chains   | <----> | Audit Log       |
         | (BTC, ETH, ...) |        | (immutable WORM)|
         +-----------------+        +-----------------+
```

### Core Components

1. **API Gateway** -- terminates TLS (Transport Layer Security), validates JWT (JSON Web Token — signed token format used for stateless auth) and 2FA (Two-Factor Authentication), rate-limits per account, runs early OFAC (Office of Foreign Assets Control — US Treasury body maintaining the sanctions list) pre-check on destination addresses.
2. **Withdrawal Service** -- the state machine for outbound transfers. Owns idempotency, retries, and the request lifecycle.
3. **Deposit Service + block scanners** -- one scanner per chain, watches for inbound transfers to known deposit addresses.
4. **Risk Engine** -- computes a risk score for every outbound destination address using Node2Vec (graph-embedding algorithm) graph embeddings on the public address graph plus internal heuristics.
5. **Policy Engine** -- enforces hard limits: per-withdrawal cap ($10K hot), daily velocity, whitelisted destinations, 2FA-required thresholds, country-of-origin gates.
6. **Signing Router** -- routes a signing request to the correct tier based on amount, asset, account type, and risk score. Hot, warm, cold each have different infrastructure.
7. **HSM cluster** (Hardware Security Module — tamper-resistant device that holds keys and performs signing without ever exposing them) -- AWS CloudHSM or on-prem hardware security modules. Keys are generated *on* the HSM and cannot be exported. Signing crosses the boundary; the key never does.
8. **MPC (Multi-Party Computation — multiple parties jointly compute over secret inputs without revealing them) / TSS (Threshold Signing Scheme — k-of-n parties produce one signature indistinguishable from a regular one) signers** -- threshold signing service running Coinbase's open-sourced `cb-mpc` (Coinbase's open-source MPC library released March 2025) library. Shamir secret sharing distributes key shares; partial signatures combine off-HSM into a single on-chain signature. The full private key is never reconstructed at rest or in flight.
9. **Cold storage / CDS** -- cross-domain solution. Signing requests cross an air gap (typically via printed QR or one-way data diode) into a physically isolated network where multi-sig wallets sign offline.
10. **Broadcast Service** -- pushes signed transactions to chain via redundant RPC providers. Tracks mempool state and replacement-by-fee (RBF).
11. **Confirmation Watcher** -- per-chain workers that wait for asset-specific confirmation thresholds before crediting deposits.
12. **Ledger Service** -- the double-entry source of truth for customer balances. Custody touches the ledger only at debit (request) and credit (settlement).
13. **Audit Log** -- WORM (Write Once Read Many) storage of every key operation, signed by the originating service. Time-locked for 7+ years.

---

## Step 3: Data Model

### Core Tables

```sql
-- A wallet groups addresses for one user across one chain.
wallets (
  id              BIGINT PRIMARY KEY,
  user_id         BIGINT NOT NULL,
  chain           VARCHAR(32) NOT NULL,    -- 'bitcoin', 'ethereum', 'solana'
  wallet_type     VARCHAR(16) NOT NULL,    -- 'retail', 'vault', 'institutional'
  hd_xpub         BYTEA,                   -- extended public key for HD derivation
  custody_tier    VARCHAR(8) NOT NULL,     -- default tier for outbound
  created_at      TIMESTAMP NOT NULL,
  UNIQUE (user_id, chain, wallet_type)
);

-- Individual deposit addresses derived from the HD wallet.
addresses (
  id              BIGINT PRIMARY KEY,
  wallet_id       BIGINT NOT NULL REFERENCES wallets(id),
  address         VARCHAR(128) NOT NULL,
  derivation_path VARCHAR(64) NOT NULL,    -- e.g., m/44'/0'/0'/0/137
  status          VARCHAR(16) NOT NULL,    -- 'active', 'rotated', 'archived'
  created_at      TIMESTAMP NOT NULL,
  UNIQUE (chain, address)                  -- a chain address is globally unique
);

-- Key shares stored across HSMs and MPC parties.
key_shares (
  id              BIGINT PRIMARY KEY,
  key_id          UUID NOT NULL,           -- the logical key this share belongs to
  share_index     INT NOT NULL,            -- 1..n in the k-of-n threshold
  custodian       VARCHAR(64) NOT NULL,    -- 'hsm-prod-1', 'mpc-party-2', 'cold-officer-jane'
  hsm_handle      VARCHAR(128),            -- opaque HSM key handle if HSM-resident
  threshold_k     INT NOT NULL,            -- k of n required
  threshold_n     INT NOT NULL,
  created_at      TIMESTAMP NOT NULL,
  rotated_at      TIMESTAMP
);

-- The withdrawal state machine.
withdrawal_requests (
  id              BIGINT PRIMARY KEY,
  idempotency_key VARCHAR(128) NOT NULL UNIQUE,
  user_id         BIGINT NOT NULL,
  asset           VARCHAR(32) NOT NULL,
  amount          NUMERIC(38,18) NOT NULL,
  destination     VARCHAR(128) NOT NULL,
  custody_tier    VARCHAR(8) NOT NULL,     -- 'hot', 'warm', 'cold'
  status          VARCHAR(32) NOT NULL,    -- see state machine, Step 6
  risk_score      NUMERIC(5,2),
  policy_decision VARCHAR(16),             -- 'allow', 'review', 'deny'
  signing_request_id BIGINT,
  tx_hash         VARCHAR(128),
  confirmations   INT DEFAULT 0,
  required_confirmations INT NOT NULL,
  created_at      TIMESTAMP NOT NULL,
  updated_at      TIMESTAMP NOT NULL,
  version         INT NOT NULL DEFAULT 0
);

-- Signing requests sent to a tier; one withdrawal can produce many (retry).
signing_requests (
  id              BIGINT PRIMARY KEY,
  withdrawal_id   BIGINT NOT NULL REFERENCES withdrawal_requests(id),
  tier            VARCHAR(8) NOT NULL,
  unsigned_tx     BYTEA NOT NULL,          -- pre-image, including nonce
  signed_tx       BYTEA,
  nonce           BIGINT,                  -- chain account nonce, must be monotonic
  status          VARCHAR(16) NOT NULL,    -- 'pending', 'signing', 'signed', 'failed'
  attempted_at    TIMESTAMP NOT NULL,
  completed_at    TIMESTAMP
);

-- Append-only audit trail. Hashed and chained for tamper evidence.
audit_log (
  id              BIGINT PRIMARY KEY,
  event_type      VARCHAR(64) NOT NULL,    -- 'key.signed', 'share.rotated', 'ceremony.approved'
  actor           VARCHAR(128) NOT NULL,   -- service identity or human signer
  resource_id     VARCHAR(128),
  payload_hash    BYTEA NOT NULL,          -- SHA-256 of full payload
  prev_hash       BYTEA NOT NULL,          -- chain to previous record
  signature       BYTEA NOT NULL,          -- signed by emitter's identity key
  created_at      TIMESTAMP NOT NULL
);
```

### Key Design Decisions in the Schema

**Idempotency key on `withdrawal_requests`:** Withdrawals are not retry-safe at the chain level (broadcasting the same signed transaction twice can succeed twice if the nonce is reused incorrectly, or fail in confusing ways). The idempotency key turns a retry into a no-op at the API layer.

**Separating `withdrawal_requests` and `signing_requests`:** A withdrawal is a business intent. A signing request is the cryptographic operation that fulfills it. One withdrawal may produce multiple signing requests if the first fails (e.g., nonce conflict, MPC quorum unavailable). Keeping them separate preserves the audit trail of every signing attempt.

**`hd_xpub` stored, no private key in this DB:** The wallet table never stores private keys. Private material lives only inside HSMs and MPC parties. The xpub is enough to derive deposit addresses without exposing spending authority.

**Chain-and-hash on audit log:** Each row's `prev_hash` chains to the prior row, and `payload_hash` is signed by the emitting service. This produces a Merkle-like tamper-evidence chain -- modifying a row in the past invalidates every subsequent row's chain hash. We back it up to WORM storage daily.

**No status-based deletes anywhere:** Audit retention is 7+ years. Custody tables are insert-and-update-status only; row deletion is never legal.

---

## Step 4: The Three-Tier Custody Model

This is the architectural heart of the design. Customer crypto is partitioned across three tiers with very different security postures and operational latencies.

| Tier | % of AUM | Signing Method | Latency | Use Case |
|---|---|---|---|---|
| Hot | 2-5% | HSM + automated policy | Seconds-minutes | Retail withdrawals under $10K, exchange operations |
| Warm | 5-20% | MPC / TSS (k-of-n) | Minutes | Programmatic withdrawals, institutional API, market-maker rails |
| Cold | 75-98% | Multi-sig + air-gap (CDS) | Hours-days | Long-term reserve; refills the warmer tiers |

### Hot Tier

- Online, automated, HSM-resident keys.
- Funds are limited to whatever the system can afford to lose to a worst-case hot-key compromise. With $10K per-withdrawal cap and daily velocity caps, an attacker who exfiltrates a hot key still cannot drain meaningful value before the policy gate triggers and the key is rotated.
- Address pools are pre-generated and rotated; no address is reused for sending.
- Used for: outbound retail withdrawals, exchange operations (trading, hedging).

### Warm Tier

- MPC threshold signing service running `cb-mpc`. Keys are split into n shares; k must cooperate to sign. Shares live across geographically distributed signing servers.
- Used for: institutional API withdrawals, programmatic transfers, market-maker integration, refilling the hot tier.
- Higher-value transfers; more deliberate; quorum of services rather than a single HSM.
- Critical property: the full key never exists in one place. Even root + physical access to one signer yields nothing useful.

### Cold Tier

- Air-gapped. Lives behind a CDS (cross-domain solution) -- a one-way data diode or QR-based ceremony bridge that physically isolates the cold environment.
- Multi-sig wallets (e.g., 3-of-5 across geographically separated officers).
- Funds move only via *promotion ceremonies*: scheduled, multi-sig, multi-human, camera-monitored, and approved through an out-of-band ticketing system.
- Cold-to-warm refills are *not* on-demand. They run on a forecast: "we expect to need X BTC of warm liquidity in the next 7 days; schedule a ceremony for Wednesday."
- Coinbase publicly states ~98% of customer crypto sits here.

### Vault Product (Institutional)

The institutional **Vault** is a customer-facing product that adopts the cold-tier signing pattern: 1 share offline, 1 with the customer's human approvers, 1+ on Coinbase MPC servers. Every Vault withdrawal triggers an email-based 48-hour cooling-off and approval window. This is the same pattern as cold storage promotion, exposed to enterprise customers.

### Why Tiered Instead of Just Cold?

You could put 100% of customer assets in cold storage. The reason to tier is **operational liquidity**: a customer pressing "withdraw" and waiting 48 hours for a multi-sig ceremony is unusable. Tiering lets the system service common-case retail withdrawals in seconds while the vast majority of value remains air-gapped. The size of the hot tier is the explicit knob that trades UX against worst-case loss.

---

## Step 5: Signing Infrastructure

Each tier has a different signing primitive. The Signing Router is responsible for choosing the right one and assembling a signed transaction.

### HSM-Backed Signing (Hot)

```
Signing Router --> HSM Signer --> AWS CloudHSM cluster (FIPS 140-2 Level 3)
                                          |
                                  Key never leaves HSM;
                                  sign(unsigned_tx, handle) returns signature
                                          |
                                          v
                                  Broadcast Service
```

- Key generation: `genkey` runs *inside* the HSM. The HSM returns an opaque handle; the private bytes never touch the network.
- Signing: the unsigned transaction (hashed pre-image) is sent in; the HSM returns the signature. Throughput is bounded by HSM hardware (~1K signatures/sec per cluster member).
- Failure mode: if the HSM cluster is unavailable, hot withdrawals fail closed. Customers see "temporarily unavailable" -- never "your withdrawal was lost."

### MPC / TSS (Warm)

`cb-mpc` is Coinbase's open-source MPC library (March 2025). Key properties:

- Two-party and multi-party signing for ECDSA (Elliptic Curve Digital Signature Algorithm — Bitcoin and Ethereum's signature scheme) + EdDSA (Edwards-curve Digital Signature Algorithm — newer scheme used by Solana) / Schnorr.
- Hierarchical deterministic key derivation under MPC -- you can derive child keys without ever reconstructing the parent.
- Secure backup with ZK (Zero-Knowledge — proof systems that verify a claim without revealing why it's true) proofs of share correctness.
- The full private key is *never* reconstructed at rest or in flight.

```
Signing Router --requests warm signature--> MPC Coordinator
                                                  |
                          +-----------------------+----------------------+
                          |                       |                      |
                          v                       v                      v
                    MPC Party 1            MPC Party 2            MPC Party 3
                    (us-east, HSM)         (us-west, HSM)         (eu-west, HSM)
                          |                       |                      |
                          | partial signature     | partial signature    | (silent)
                          v                       v                      v
                          +------- combine on coordinator ---------------+
                                       |
                                       v
                              single ECDSA signature
                                       |
                                       v
                                 Broadcast Service
```

- **k-of-n threshold:** typical 2-of-3 or 3-of-5. Compromise of (k-1) parties yields nothing.
- **No single key reconstruction:** the combine step produces a signature that is indistinguishable from a normal single-key signature. On-chain, nothing reveals that MPC was used. (This is the key advantage over multi-sig: privacy and no on-chain footprint.)
- **Why not just multi-sig?** Multi-sig is on-chain visible (two outputs to a P2SH/P2WSH script with multiple pubkeys). It also costs more in fees (more script bytes) and breaks per-chain compatibility (multi-sig shapes differ across chains; MPC produces a single signature so any chain that supports the underlying primitive Just Works). MPC is the right choice for a multi-chain custodian.

### Multi-sig + Air-gap (Cold)

```
Promotion Ceremony (every 1-7 days, scheduled)
   |
   1. Treasury team forecasts liquidity need
   2. Operations cuts a ticket; security reviews
   3. Online system constructs unsigned tx (PSBT for BTC, etc.)
   4. Tx + ceremony manifest crosses CDS boundary (printed QR or one-way data diode)
   5. Cold environment (faraday-shielded room, no network):
      - 3-of-5 officers each connect their hardware signer
      - Each verifies on-device that destination, amount match the ticket
      - Each signs; partial signatures aggregated on-device
   6. Fully signed tx exits via the same one-way bridge (printed QR scanned in)
   7. Online system broadcasts and watches for confirmation
```

- **CDS = cross-domain solution.** Military-grade pattern for moving data between security domains. The bridge is one-way (data diode) or human-mediated (QR). No general-purpose network connection ever exists.
- **Camera-monitored, two-officer rule.** Cameras record every action in the cold room. No officer is alone with hardware.
- **Why multi-sig instead of MPC for cold?** Cold storage prioritizes auditability and simplicity over privacy. On-chain multi-sig is independently verifiable from chain data alone -- an auditor can confirm that a signed transaction required 3 signatures from 5 declared keys without trusting Coinbase's software. With MPC there is nothing on-chain to audit; you must trust the implementation. For the "98% of assets" tier, third-party verifiability wins.

### Signing Tier Decision Logic

```
def select_tier(withdrawal):
    if withdrawal.amount > daily_remaining_hot_budget:
        return WARM
    if withdrawal.account.type == INSTITUTIONAL_VAULT:
        return COLD  # vault product always uses cold-tier ceremony
    if withdrawal.risk_score > HIGH_RISK_THRESHOLD:
        return MANUAL_REVIEW
    if withdrawal.amount <= HOT_LIMIT_PER_TX:
        return HOT
    return WARM
```

Selection happens server-side. The customer cannot influence which tier signs.

---

## Step 6: Withdrawal Pipeline State Machine

Every outbound transfer flows through this pipeline. Steps are idempotent; each transition writes an audit log entry.

```
   [received] --validated--> [risk_scoring] --score--> [policy_check]
                                                            |
                                                  +---------+----------+
                                                  | allow   | review   | deny
                                                  v         v          v
                                          [signing_pending] [manual_queue] [rejected]
                                                  |              |
                                                  v              v (after approval)
                                              [signing] -----> [signing_pending]
                                                  |
                                                  v
                                              [signed] --broadcast--> [broadcasting]
                                                                          |
                                                                          v
                                                                   [in_mempool]
                                                                          |
                                                                          v
                                                              [awaiting_confirmations]
                                                                          |
                                                       (per-asset N confirmations reached)
                                                                          v
                                                                     [settled]
```

### Step-by-step

1. **Received.** API gateway accepts the request, validates auth + 2FA, checks idempotency key. Returns 202 with request id. State persisted in `withdrawal_requests`.
2. **Validated.** Server confirms the user's *internal* balance is sufficient via the [[../14-coinbase-financial-ledger/PROMPT|ledger]]. The ledger debit happens here (a hold), not at broadcast time -- this prevents double-spend at the application layer.
3. **Risk scoring.** Risk Engine looks up the destination address. Computes a Node2Vec embedding from the public address graph; compares to clusters of known mixers, sanctioned entities, ransomware wallets, exchange hot wallets. Score 0-100.
4. **Policy check.** Policy Engine evaluates rules: per-tx limit, daily velocity cap, whitelist match, country, time-of-day, KYC (Know Your Customer — identity verification required before account opening) tier, risk-score threshold. Outcomes: `allow`, `review` (humans must approve), `deny`.
5. **Signing.** Signing Router selects tier; constructs unsigned transaction (chain-specific); allocates a nonce (must be monotonic per source address); sends to chosen signer.
6. **Broadcast.** Signed tx pushed to multiple RPC providers in parallel for redundancy. The first to confirm relay wins.
7. **Awaiting confirmations.** Confirmation Watcher tracks the tx hash. Customer balance is *not* finalized until N confirmations -- but their internal balance was already debited at step 2, so they cannot double-spend. The settlement step adjusts the ledger from "pending out" to "out."
8. **Settled.** Final ledger entry written. Customer notified. Audit log stamped.

### Idempotency and Retries

- The API client must supply an `idempotency_key`. Re-submitting the same request returns the existing record's current state; never creates a duplicate.
- Internally, the broadcast step must be idempotent: a signed transaction has a deterministic hash, so re-broadcasting is a no-op at the chain level. The internal state machine guards against double-debit by transitioning `signed -> broadcasting` only via `UPDATE ... WHERE status = 'signed' AND version = :v`.
- If the broadcast step crashes between sign and broadcast: on restart, the watcher sees `status = signed`, the signed tx is in the DB, and the broadcast retries. Same nonce, same signature, same tx hash -- this is safe.
- **Never re-sign a withdrawal.** Re-signing produces a different signature with the same nonce, which on some chains creates a malleability or replay risk. If sign succeeded but we are unsure whether broadcast went out, query the chain by tx hash before re-signing.

### Nonce Management (Ethereum and Account-Based Chains)

The hot wallet has a single nonce sequence per source address. Concurrent withdrawals must serialize nonce allocation:

```sql
BEGIN;
SELECT nonce_counter FROM accounts WHERE address = :hot_addr FOR UPDATE;
-- compute next nonce = nonce_counter
UPDATE accounts SET nonce_counter = nonce_counter + 1 WHERE address = :hot_addr;
INSERT INTO signing_requests (..., nonce = :next_nonce);
COMMIT;
```

A gap in the nonce sequence (caused by a stuck transaction) blocks every subsequent withdrawal. Mitigation: aggressive RBF (replace-by-fee with higher gas) on the stuck tx, and a "nonce repair" runbook for operators.

---

## Step 7: Deposit Pipeline

Deposits are the inbound side. Each chain has its own scanner.

```
+--------------------+        +---------------------+        +---------------+
| Block Scanner      |  ----> | Confirmation        | -----> | Ledger Service|
| (per chain)        |        | Watcher             |        | (credit user) |
+--------------------+        +---------------------+        +---------------+
        |                              |
        |                              v
        |                       Reorg Detector
        |                              |
        v                              v
   Snapchain               Roll back if reorged before
  (node infra)             threshold confirmations
```

### Per-Chain Confirmation Thresholds

| Chain | Confirmations | Approx Time | Why |
|---|---|---|---|
| Bitcoin | 3-6 | 30-60 min | PoW with regular short reorgs |
| Ethereum (PoS) | 12-32 | 3-6 min | PoS with rare deep reorgs; pre-Merge needed more |
| Solana | 32 | 13 sec | Optimistic finality |
| Polygon | 256 | 5-10 min | Cheap gas, more reorg history |
| Arbitrum / OP | until L1 finality | ~15 min | Trust-minimized only at L1 settlement |

The threshold is a per-asset config that is reviewed when chain finality changes (e.g., Ethereum's Merge changed the right number).

### Reorg Handling

A naive deposit pipeline credits at 1 confirmation and gets burned. Coinbase had to handle this for ETC's 100-block reorg in 2020 and others.

```
on new block(block):
  for tx in block.transactions:
    if tx.to in our_addresses:
      record pending_deposit(tx_hash, block_height, amount)

on every block:
  for pending in pending_deposits where confirmations < threshold:
    reload pending.tx from chain
    if tx still in canonical chain:
      pending.confirmations = chain.head - pending.block_height
      if pending.confirmations >= threshold:
        credit_ledger(pending)
        pending.status = 'settled'
    else:
      # the tx was reorged out
      pending.status = 'orphaned'
      audit_log('deposit.reorged', pending)
      # do not credit; if it reappears in canonical chain, treat as new
```

Reorgs are not just BTC's problem. ETH, Solana, Polygon, BSC all have non-trivial reorg histories. Treating broadcast as "done" is among the most common bugs in custody systems.

### Snapchain

Coinbase runs its own blockchain node infrastructure called **Snapchain** (Coinbase's blue/green blockchain node deploy system using EBS snapshots). The pattern is: nodes are immutable, ephemeral, with a 30-day max server lifespan. After 30 days, a node is destroyed and replaced from a fresh image. This bounds long-running node compromise: any malware that landed on a node has at most 30 days before the node is wiped. The block data itself is signed and verified against multiple independent providers, so a single compromised node cannot serve fake blocks for long.

---

## Step 8: Address Generation and Management

Customer-facing deposit addresses are derived from HD (hierarchical deterministic) wallets. Outbound addresses come from rotating pools.

### HD Derivation for Deposits

Per BIP32/BIP44:

```
Root master key (in HSM or MPC, never extracted)
    |
    +-- m/44'/0'/0'  (BTC, account 0)
    |       +-- m/44'/0'/0'/0/0    (user 1, address 1)
    |       +-- m/44'/0'/0'/0/1    (user 1, address 2)
    |       +-- m/44'/0'/0'/0/N    ...
    |
    +-- m/44'/60'/0'  (ETH, account 0)
            +-- m/44'/60'/0'/0/0  (user 1, address 1)
```

The xpub (extended public key) is enough to derive deposit addresses without spending authority. Address derivation runs on the application server; the private spending key never leaves the HSM/MPC store.

`cb-mpc` supports MPC-protected hierarchical key derivation -- you can derive child keys without ever reconstructing the parent. This is essential: the derivation must happen *under MPC* so no party ever sees the parent.

### Address Rotation

- Each deposit address is single-use in spirit. Reusing a deposit address links every prior deposit on-chain to the same wallet, leaking customer privacy and creating clustering targets for chain analysis tools. UTXO (Unspent Transaction Output — Bitcoin's accounting model) chains (BTC) are particularly sensitive.
- Addresses are pre-generated in batches and assigned on demand.
- For outbound, the hot wallet rotates source addresses on a rolling schedule -- so the hot wallet does not become a single static "Coinbase change address" that adversaries can monitor and target.

### Address Pool Pre-Generation

```
Background job: every N hours
  for each chain:
    if pool_size(chain) < low_water_mark:
      derive next 10K addresses
      store with derivation_path, status=available
```

Pre-generation matters because deriving addresses on demand under MPC is expensive (multi-party round-trip). Pre-warming the pool keeps deposit-address creation latency under 50ms.

---

## Step 9: Threat Model and Defense in Depth

The custody system must survive realistic attacks. Each tier and each defense is justified by an explicit threat.

| Threat | Single defense fails | Defense in depth |
|---|---|---|
| External attacker compromises hot signer service | Drains hot tier | Per-tx limits + daily velocity + withdrawal whitelist + risk score gate |
| Insider exfiltrates a key share | One share is useless | k-of-n threshold; need multiple insiders colluding; geo-distribution; segregation of duties |
| Supply chain implant on signing server | Signs adversary-chosen txs | MPC: implant on one party signs nothing alone. Reproducible builds; binary attestation; HSM-rooted code signing |
| Phishing on a customer 2FA token | Attacker requests withdrawal | Address whitelisting + 24-48h cooling-off on new addresses + email confirmation |
| Sanctioned destination (OFAC) | Tx broadcast violates law | Pre-broadcast OFAC screen on every outbound; Node2Vec risk score on indirect taint; manual review queue |
| Coerced single signer ($5 wrench) | Attacker gets that share | Need k participants; cooling-off allows recovery; out-of-band ticketing surface so coerced signer can flag duress |
| DNS / TLS compromise on broadcast RPC | Tx routed to attacker's node | Multi-RPC redundancy; signature is what matters, not the path; auditor-verifiable on-chain confirmation |
| Customer device compromise | Bad actor logs in | Device binding; new-device cooling-off; large-value withdrawals require email + 2FA + sometimes a phone call |
| Storage system tampering (DB row edited) | Custody state corrupted | Append-only audit log with hash chain; daily Merkle root posted to a public chain; mismatch -> incident |
| Cold-room officer corruption | One ceremony signed maliciously | 3-of-5 quorum; cameras; out-of-band ticket review; ceremony manifest cross-checked by separate team before signing |

### The "$5 Wrench Attack"

The XKCD scenario: an attacker physically threatens a single signer to coerce a transaction. The architectural defense is *not* "trust people not to be coerced." It is:

1. No single signer can authorize -- threshold k-of-n means k people must be coerced.
2. Cooling-off periods give time for any one signer to abort.
3. Out-of-band acknowledgment -- the duress channel is separate from the signing channel. Officers have a panic phrase that, if uttered on the ceremony call, halts the operation.

### The Insider Threat as First-Class

Most custody losses historically have involved insiders (Mt. Gox, QuadrigaCX). The architecture treats every operator role -- engineer, treasurer, board member -- as potentially adversarial:

- No production database write privileges for engineers. All changes go through deploys with code review.
- HSM admin credentials are themselves split (k-of-n) and time-locked.
- Promotion ceremonies require approvals from people who cannot also approve their own approvals (separation of duties).
- Audit log is signed by emitters and chained, so a single DBA cannot rewrite history without detection.

---

## Step 10: Compliance Layer

Custody is regulated. Compliance is not a separate service; it is gates inside the withdrawal pipeline.

### KYC Gating

- First withdrawal requires completed KYC. Tracked at the user level by the [[../19-coinbase-kyc-onboarding/PROMPT|onboarding system]].
- Withdrawals to unverified counterparties at large size trigger Travel Rule (FinCEN/FATF rule requiring originator/beneficiary info on transfers above ~$3000) notice.

### OFAC Sanctions Screening

- Every outbound destination is checked against OFAC's SDN list and chain-analytics blocklists (Chainalysis (blockchain analytics vendor), TRM, internal lists).
- Direct hits: hard block. Tx never signs.
- Indirect taint (n-hop path to a sanctioned address): risk score elevated; manual review.

### Travel Rule (FinCEN, FATF)

- Crypto transfers over $3K to/from another VASP must include originator and beneficiary identity info.
- Outbound to a known VASP address (mapped via TRM/Chainalysis VASP database) attaches Travel Rule metadata via the IVMS-101 protocol.
- Outbound to an unhosted wallet at $10K+ may require additional attestation per local jurisdiction.

### SAR (Suspicious Activity Report)

- Daily aggregate withdrawals over thresholds, structuring patterns (just-under thresholds), and behavioral anomalies are flagged.
- The compliance team reviews and files SARs to FinCEN (Financial Crimes Enforcement Network — US Treasury bureau enforcing BSA) within 30 days.
- The detection runs on a separate analytics pipeline reading from the audit log -- not on the hot path.

### Audit Immutability

- All audit log entries are hash-chained.
- Daily, the head hash is committed to a public blockchain (BTC OP_RETURN or ETH calldata) and to an internal WORM bucket. This is the "trusted timestamping" pattern.
- A regulator or auditor can verify any subset of the log against the published root.

---

## Step 11: Operational Procedures

Custody operations are not "click a button." They are procedures with checklists.

### Cold-to-Warm Refill Ceremony

1. Treasury forecasts: "we need to refill warm tier with X BTC by Friday."
2. Operations cuts a ticket; security reviews. The forecast itself must be reasonable (no sudden 10x spikes -- those route to manual investigation).
3. Online side constructs an unsigned PSBT (Partially Signed Bitcoin Transaction) from cold -> warm address.
4. PSBT is rendered as QR; printed.
5. Three of five officers convene in the cold room (camera-monitored). Each scans the QR into their hardware signer, verifies the destination matches the ticket, and signs.
6. Combined PSBT exits via a separate QR. Scanned in by a non-officer to prevent in/out tampering by a single person.
7. Online side broadcasts. Confirmation watcher verifies arrival to the warm address.

### Hot-to-Warm Sweep (Reverse Direction)

When the hot tier accumulates more than its target balance (deposits in, withdrawals out, net positive), excess sweeps up to the warm tier on a schedule. This is automated within hot-tier policy bounds because moving funds *to safer storage* is a benign operation.

### Key Rotation

- HSM keys rotate annually, or immediately on suspected compromise.
- New key generated on HSM; users' addresses gradually migrated as funds are spent (UTXO model) or via in-place rotation (account model).
- Old key kept active until all funds drained, then ceremonially destroyed (HSM zeroize command, witnessed).

### MPC Share Rotation

`cb-mpc` supports proactive secret sharing: shares can be re-randomized periodically without changing the underlying private key. This means a slow-rolling compromise -- where an attacker collects shares one at a time over months -- never accumulates a quorum because shares from different epochs are not compatible.

### HSM Lifecycle

- HSMs have a ~5-year lifespan (vendor support windows + crypto agility).
- Decommissioning requires zeroize, witnessed; the device is then physically destroyed (drilled / shredded).
- Spare HSMs are pre-provisioned with shares so a hardware failure does not leave the cluster below quorum.

---

## Step 12: Failure Modes

### Failure: HSM Cluster Unavailable

- Hot withdrawals fail closed (returns 503 to client). Customer retries; idempotency key prevents duplicates.
- Customer can switch to warm-tier path if eligible (institutional API). Retail customers wait.
- Standby HSM cluster in another region can be promoted, but this is a high-touch operation (requires officer approval to mount HSM keys).

### Failure: MPC Quorum Lost (party permanently down)

- Threshold k-of-n means we tolerate (n-k) failures. With 2-of-3 we tolerate one party down.
- If a party is down past a threshold (24 hours), invoke the `cb-mpc` recovery procedure: the surviving k parties cooperatively generate a new share to restore the quorum, without ever reconstructing the underlying key.
- Audit: every recovery is logged and reviewed.

### Failure: Broadcast Fails / RPC Provider Outage

- Broadcast targets multiple RPC providers in parallel. If all fail, the signed tx remains in `signed` state and the watcher retries.
- If the network is partitioned (we cannot reach any node), customer sees "broadcast pending"; no balance change yet.
- The customer's balance is debited at request time, so they cannot spend it twice while we wait. If the broadcast ultimately fails permanently (e.g., transaction rejected by chain because nonce was reused), the ledger debit is reversed.

### Failure: Mempool Stall / RBF Storm

- The signed tx sits in mempool for hours. Possible causes: gas price too low, nonce gap, congestion.
- Mitigation: monitor mempool age; if a tx exceeds N minutes, broadcast a replacement-by-fee with higher gas (BTC) or higher gasPrice (ETH) and same nonce. This bumps the original out.
- For Solana / chains without RBF: tx auto-expires after a slot window; rebuild and resign with a fresh blockhash.

### Failure: Chain Reorg After Credit

If a deposit was credited at threshold confirmations and the chain reorgs that block out:
- The credit is reversed. The user's balance temporarily decreases. Customer support is notified to handle the user-visible inconsistency.
- Audit log captures the reorg and the reversal.
- This is rare (deep reorgs past confirmation threshold are extreme events). Mitigation: pick conservative confirmation thresholds.

### Failure: Audit Log Corruption Detected

- Hash chain mismatch surfaces during the daily Merkle root calculation.
- Every tier's signing is *halted* automatically until incident response confirms whether the mismatch is a bug or tampering.
- Failing closed on the audit layer is intentional. Custody loss is irreversible; downtime is not.

### Failure: Signer Key Suspected Compromised

- Detected via anomaly (signing volume spike, signature on unexpected destinations) or external alert.
- Immediate response: rotate the key. New address pool. Drain old hot wallet to cold via emergency ceremony.
- Customer impact: brief outage on the affected tier. Funds are safe -- the policy gate would not have signed an unauthorized destination even if the key was used.

---

## Step 13: Tradeoffs Summary

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Custody model | Three-tier (hot/warm/cold) | Single tier (all cold) | UX requires fast withdrawals; tiering bounds risk per tier |
| Hot tier signing | HSM-backed | Software keys | Hardware key extraction is an order of magnitude harder; FIPS (Federal Information Processing Standards — US gov crypto standards, e.g., FIPS 140-2 for HSMs) -validated |
| Warm tier signing | MPC (cb-mpc) | On-chain multi-sig | MPC produces a single signature: no on-chain footprint, lower fees, multi-chain compatible |
| Cold tier signing | On-chain multi-sig + air-gap | MPC + air-gap | Multi-sig is independently auditable from chain data; required for the largest tier |
| Key storage | HSM only, no exfil | Software with backups | Backups are a liability; HSM-rooted keys have a known security boundary |
| Recovery | Threshold k-of-n with proactive resharing | Static shares | Proactive resharing defeats slow share-collection attacks |
| Hot-tier sizing | 2-5% of AUM | "Unlimited" | $320M crime insurance + worst-case loss tolerance bound the cap |
| Confirmation thresholds | Per-asset, conservative | Universal 1-conf | Reorg history differs by chain; ETC 100-block reorg taught the industry |
| Reorg handling | Watch and reverse | Optimistic credit | Customer-visible reversals are bad; phantom credits are worse |
| Address reuse | Rotated pools | Single static address | Privacy + clustering avoidance + makes hot-wallet observation harder |
| Audit log | Hash-chained, externally rooted | Database table | Tamper-evidence and third-party verifiability |
| Promotion ceremonies | Manual quorum + cooling-off | Automated thresholds | Cold-to-warm sweeps are infrequent; deliberate slow process beats availability optimization |
| Withdrawal pipeline | State machine with idempotency | Direct broadcast | Custody must survive crashes mid-flight |
| Compliance | Inline gate | Post-hoc filter | Stopping a violating tx at request time is cheaper than reversing it |

---

## Common Mistakes to Avoid

1. **One big hot wallet.** Putting all customer funds in a single online wallet protected by KMS is the canonical newcomer mistake. A single key compromise is total loss. Tier the custody and bound each tier by what you can afford to lose.

2. **No per-withdrawal limits.** Even with HSM-backed signing, an attacker who hijacks the signing service request path can drain unbounded value. Limits are independent of crypto and are the only guarantee of bounded loss.

3. **No address screening.** Sending to an OFAC-sanctioned address is a federal crime. Screening must be a hard gate, not a "we'll review later" log.

4. **Treating broadcast as "done."** A signed transaction in mempool is not a confirmed transaction. Chains reorg. Mempools stall. The settlement ledger entry must depend on confirmation watcher output, not on broadcast success.

5. **Crediting deposits at 1 confirmation.** This is how Bitcoin Cash and Ethereum Classic exchanges got rekt. Confirmation thresholds are per-asset, conservative, and reviewed when chain consensus changes.

6. **Mutable audit log.** If a DBA can edit the audit log, you have no audit log. Hash-chain it. Sign each entry. Externalize daily roots. This makes forensic review possible after an incident.

7. **MPC for cold storage.** MPC has no on-chain footprint, which is great for warm but hostile for the largest tier where third-party verification matters most. Use multi-sig for cold and accept the on-chain cost.

8. **Single signer for ceremonies.** Even if you have multi-sig in place, if one person can both initiate and approve ceremonies, segregation of duties is broken. Approvals must come from different people than requesters; auditing must come from a third group.

9. **Reusing deposit addresses.** Aside from privacy, reused addresses cluster customer activity for chain-analysis tools and become a target for dust attacks. Pre-generate pools and rotate.

10. **No plan for HSM unavailability.** If HSMs go down, what does the system do? "Halt all withdrawals" is acceptable (fail closed) but only if it is *designed* and tested. Many systems discover this failure mode in production.

11. **Underestimating insiders.** External adversaries get airtime. Statistically, insiders have caused most major exchange losses. The architecture must constrain insiders by default: no single human role can move funds.

12. **Assuming MPC is "as good as" multi-sig.** They have different audit and threat properties. MPC is faster and chain-agnostic; multi-sig is publicly verifiable. Pick by tier requirement, not preference.

---

## Step 14: Smart Wallet (ERC-4337) Note

Coinbase's **Smart Wallet** product is account-abstraction (ERC-4337) wallets with passkeys (secp256r1) scoped to keys.coinbase.com. Pieces: bundler (packages UserOps), paymaster (sponsors gas), UserOp mempool. This is a *customer-facing* non-custodial product -- the user holds the passkey, Coinbase runs the relay. It is out of scope for the three-tier custody model in this exercise but worth naming so the interviewer knows you distinguish custodial vs non-custodial surfaces.

---

## Step 15: Follow-up Questions

These are the natural probes a staff interviewer will use to push the design.

### "How would you add support for a new chain?"

- Add a per-chain module: signer adapter (which signing primitive does it use?), broadcaster (RPC), confirmation watcher (finality model), address derivation (BIP44 path or native scheme).
- Decide tier strategy: does the chain support multi-sig natively for cold? If not, MPC may be the only viable cold option (rare but happens with some non-EVM chains).
- Set conservative initial confirmation thresholds. Tighten over time as you build a reorg history.
- Run a launch ceremony: generate keys under MPC, fund test addresses, run end-to-end deposit and withdrawal under load.

### "How do you handle account abstraction (ERC-4337)?"

- Custodial accounts: AA is irrelevant; we hold EOA keys directly.
- Smart Wallet: user holds the passkey, no custody surface for Coinbase.
- Institutional Smart Account: keys split via MPC across the institution's signers and Coinbase as co-signer; tx approval rules enforced on-chain via the smart contract wallet's policy module.

### "How would you support staking?"

- Staking adds a long-running on-chain commitment on top of custody. Challenges: validator key custody (slashing risk), delegation scope (validator key can stake/unstake but not transfer arbitrarily), withdrawal lockups (ETH 27-hour unstaking).
- Validator signing key lives in its own HSM, separate from master custody keys, with a policy that limits it to consensus signing only.
- Customer staking balances tracked in the ledger as a "staked" tier with appropriate finality (cannot withdraw immediately).

### "What about smart contract exposure on the warm tier?"

- Warm tier might interact with DeFi protocols (e.g., lending idle assets). Each contract interaction is a new attack surface.
- Mitigation: every contract address is whitelisted after a security review (audit reports, formal verification where available). Interactions go through a policy gate restricting the tx to known function selectors and bounded value. Anomalies (unexpected reverts, gas spikes) trigger automatic liquidity withdrawal.
- Fundamentally this is trust transfer: interacting with Aave means trusting Aave's audit and economic security for the position's duration. That trust budget must be explicit, not implicit.

### "What if a regulator demands key recovery?"

- The architecture explicitly does not support a backdoor. There is no "Coinbase master key" that can sign for arbitrary customer assets. Even Coinbase's own engineers cannot move funds without the threshold quorum.
- Lawful demands (e.g., asset seizure under court order) are processed via the same withdrawal pipeline -- the policy engine has a "court-ordered" path that requires the same signing threshold but with documented human approval. The system does not have a faster path for this.

---

## Related Topics

- [[../../../security-and-compliance/index|Security & Compliance]] -- HSM, KMS, key management lifecycle, FIPS 140-2
- [[../../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- threshold recovery, fail-closed semantics, redundancy across regions
- [[../../../distributed-systems-fundamentals/index|Distributed Systems]] -- threshold signatures, Byzantine fault tolerance, consensus across signers
- [[../../../scaling-writes/index|Scaling Writes]] -- idempotency keys, exactly-once semantics, transactional outbox
- [[../../../async-processing/index|Async Processing]] -- block scanners, confirmation watchers, ceremony queues, mempool monitoring
- [[../12-coinbase-trading-engine/PROMPT|Coinbase Trading Engine]] -- order matching that produces settlements that hit custody
- [[../14-coinbase-financial-ledger/PROMPT|Coinbase Financial Ledger]] -- double-entry accounting that custody debits and credits
- [[../15-coinbase-blockchain-indexer/PROMPT|Coinbase Blockchain Indexer]] -- block scanning infrastructure feeding the deposit pipeline
- [[../17-coinbase-fraud-risk-scoring/PROMPT|Coinbase Fraud / Risk Scoring]] -- the risk engine that gates outbound transfers
