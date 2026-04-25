# Exercise: Design a Multi-Chain Blockchain Indexer / Ingestion Platform (Coinbase)

## Prompt

Design a multi-chain blockchain indexing and ingestion platform like the one Coinbase operates internally. The system must continuously ingest blocks from 60+ heterogeneous blockchains (BTC, ETH, Solana, Polygon, Cosmos, etc.), normalize them into a queryable schema, expose them to a fan-out of internal consumers (deposit detection, search/explorer, analytics, fraud, tax), and reverse safely whenever a chain reorgs -- all while keeping deposit detection latency low enough that customer balances credit in seconds, not minutes.

## Requirements

### Functional Requirements
- Ingest blocks and transactions from 60+ chains (BTC, ETH, EVM L2s, Solana, Cosmos, Polkadot, ...)
- Hybrid ingestion: push streams (Geyser, Erigon stream, Bitcoin ZMQ) for tip + RPC polling for backfill and authoritative reads
- Normalized event schema across chains (universal "asset transfer" with chain-specific extensions)
- Reorg handling as a first-class state transition, not an exception path
- Per-chain confirmation policy (BTC ~3-6, ETH 12+, Solana fast finality, Polygon 256)
- Fan-out to internal consumers via Kafka with per-chain topic isolation
- Backfill of historical data (a year+ of blocks) on demand, without disrupting tip
- Block and transaction query APIs (point lookup + range scan) for explorer / debugging tooling

### Non-Functional Requirements
- Deposit detection p95 latency: tip block produced -> user balance credited in single-digit seconds for fast chains
- Throughput: up to 1500+ blocks/sec aggregate (ChainStorage production target), 8x baseline traffic spikes absorbed
- Reorg correctness: no double-credit, no missed credit, ever
- Per-chain blast radius: a Solana incident must not delay BTC deposits
- 99.99% availability for the deposit detection path; lower bar acceptable for analytics
- Cost-conscious: blockchain nodes dominate spend; fleet must bin-pack across chains intelligently

### Out of Scope (clarify with interviewer)
- Custody / signing infrastructure (separate system; we publish events, custody consumes them)
- The matching engine (covered in trading engine exercise)
- KYC, fraud rules engine, or tax calculation logic (we feed them, we don't host them)
- Smart contract execution / EVM tracing internals beyond what nodes expose
- Light-client consensus verification (assume nodes are trusted infrastructure)

## Constraints
- 60+ chains, each with its own consensus, finality model, and node software
- Chain operators ship breaking upgrades on their own schedule (mandatory hard forks)
- Some chains have probabilistic finality (BTC), some have deterministic (Solana, Cosmos), some hybrid (ETH post-merge)
- Push streams are fast but lossy on restart; RPC is authoritative but slow
- Blockchain nodes are expensive (large EBS volumes, multi-day initial sync) and must be treated as fleet
- New chains get added regularly; the platform must onboard a chain in under a week

## Key Topics Tested
- [[../../../03-scaling-writes/index|Scaling Writes]] -- per-chain Kafka partitioning, idempotent ingestion, reorg replay
- [[../../../01-databases-and-storage/index|Databases & Storage]] -- raw vs derived storage, hot/warm/cold tiering, re-derivation
- [[../../../06-distributed-systems-fundamentals/index|Distributed Systems]] -- finality, consensus, eventually consistent indices
- [[../../../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- node desync, RPC outage, reorg storm, snapshot recovery
- [[../../../07-real-time-systems/index|Real-Time Systems]] -- streaming fan-out, hybrid push/poll, latency budgets
- [[../../../05-async-processing/index|Async Processing]] -- backfill pipelines, derived index rebuilding
