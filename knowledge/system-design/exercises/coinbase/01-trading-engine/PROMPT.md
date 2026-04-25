# Exercise: Design a Crypto Order Matching Engine / Trading Platform (Coinbase)

## Prompt

Design the order matching engine and trading platform for a crypto exchange like Coinbase. The system must accept orders for spot trading pairs (BTC-USD, ETH-USD, etc.), match them with price-time priority, durably record every fill, and stream market data to thousands of subscribers -- all under sub-millisecond p99 latency, 24/7, with zero tolerance for double-spends or lost orders.

## Requirements

### Functional Requirements
- Accept order types: limit, market, stop-limit, post-only, IOC (immediate-or-cancel), FOK (fill-or-kill)
- Continuous order book with price-time priority (FIFO at each price level)
- Cancel and replace existing orders within the same priority window
- Pre-trade risk check: verify balance / margin before the order touches the book
- Atomic settlement: matched fills produce events for the ledger (double-entry bookkeeping)
- Real-time market data fan-out: ticker, trades, level2 (incremental order book) over WebSocket
- Circuit breakers: auto-halt trading on >10% price move within a configurable window
- Per-trading-pair isolation: BTC-USD outage must not impact ETH-USD

### Non-Functional Requirements
- Sub-50us internal matching latency (sequencer to fill emission)
- Sub-1ms p99 wire latency for order acknowledgment
- 100K-2M orders/sec aggregate throughput across all pairs
- RPO = 0 (zero data loss), RTO = seconds (failover within seconds)
- 24/7/365 operations -- no daily reset like TradFi exchanges
- Deterministic replay: any node can rebuild book state from the WAL
- Regulatory: full audit trail of every order, cancel, and fill; post-trade transparency for some markets

### Out of Scope (clarify with interviewer)
- Custody / wallet infrastructure (separate system)
- KYC and onboarding flows
- Fiat on-ramp / off-ramp (deposits, withdrawals)
- Derivatives (perpetuals, futures, options) -- spot only
- Tax reporting and 1099 generation
- Mobile / web client UX

## Constraints
- Global customer base: order entry from any region, all timezones
- Customers' balances move continuously (deposits/withdrawals settle 24/7), so inventory is non-static
- Best-execution regulatory requirements: must match orders fairly, no front-running
- Must survive AZ failure with sub-second failover; region failure with documented degradation
- Competing exchanges (Binance, Kraken) win or lose on latency -- this is a latency-arbitrage market

## Key Topics Tested
- [[../../../03-scaling-writes/index|Scaling Writes]] -- single-writer matching, deterministic ordering, WAL durability
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- RAFT consensus, leader election, deterministic replay
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- consensus, sequencing, exactly-once via idempotency
- [[../../../07-real-time-systems/index|Real-Time Systems]] -- WebSocket fan-out, ring buffers, market data streaming
- [[../../../05-async-processing/index|Async Processing]] -- settlement pipeline, ledger projection
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- NVMe-backed WAL, Aurora for settlement state
