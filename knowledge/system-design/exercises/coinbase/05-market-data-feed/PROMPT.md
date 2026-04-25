# Exercise: Design a Real-Time Market Data Feed (Coinbase)

## Prompt

Design Coinbase's real-time market data system -- the live-price experience powering Coinbase Explore, Advanced Trade, and the public WebSocket API. Hundreds to thousands of trading pairs each emit tick-level price updates, level2 order book diffs, and trade events 24/7. These must fan out to millions of concurrent web and mobile clients with sub-second freshness, per-pair ordering, and graceful degradation under 10x volatility spikes.

## Requirements

### Functional Requirements
- Live ticker (last price, bid/ask, 24h volume, 24h change) per trading pair
- Level2 order book stream: snapshot + incremental updates (50 levels each side)
- Recent trades stream (executed fills with price, size, side, timestamp)
- K-line / candlestick aggregations at multiple intervals (1m, 5m, 15m, 1h, 1d)
- Top-N trending pairs and market summary for the Explore homepage
- Subscribe / unsubscribe by pair and channel over a single WebSocket connection
- Resume after reconnect using sequence numbers; auto-resnapshot on gap detection
- Public REST snapshots for initial page load (top movers, ticker, depth)

### Non-Functional Requirements
- Sub-100ms p99 from matching engine fill to subscriber receipt (same region)
- Per-pair ordering guaranteed; global ordering not required
- Millions of concurrent WebSocket connections across web + mobile
- 10x burst capacity during volatility spikes (BTC pump, regulatory news)
- 99.99% availability for the public market data plane
- Bandwidth-aware: server-side conflation, optional permessage-deflate, partial subs for mobile
- Multi-region: US, EU, Asia each serve local subscribers; K-line history globally consistent

### Out of Scope (clarify with interviewer)
- Order matching engine internals (separate system; this design consumes its output)
- Authenticated user-specific feeds (orders, fills) -- those are a private channel
- Historical backfill API for institutional analytics (separate batch path)
- Custody, ledger, and settlement
- KYC, onboarding, fiat rails

## Constraints
- 500-2000 spot trading pairs, all live 24/7
- Authoritative producer: per-pair matching engines on Aeron Cluster (single writer per pair)
- Trading hot loop must not be slowed by subscriber load (two-path separation)
- Mobile clients are bandwidth and battery constrained; web clients tolerate denser feeds
- Regulatory: timestamps must be monotonic per pair; trade tape is auditable
- Competing on latency with Binance, Kraken, etc. -- subscribers churn to faster feeds

## Key Topics Tested
- [[../../../07-real-time-systems/index|Real-Time Systems]] -- WebSocket fan-out, ring buffers, conflation, backpressure
- [[../../../02-scaling-reads/index|Scaling Reads]] -- multi-tier fan-out, regional edge, CDN-cached snapshots
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- slow-consumer isolation, gap-and-resnapshot, regional failover
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- per-pair sequence numbers, snapshot+diff protocol
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- in-memory ring, Redis ZSET, time-series K-line store
- [[../../../05-async-processing/index|Async Processing]] -- K-line aggregation, cold archive pipeline
