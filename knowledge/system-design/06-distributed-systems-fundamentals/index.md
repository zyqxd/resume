# Distributed Systems Fundamentals

Distributed systems fundamentals underpin every system design discussion. When your system spans multiple machines, you must contend with partial failures, network unreliability, clock skew, and the impossibility of perfect coordination. This section covers **consensus algorithms** (Raft, Paxos), **leader election**, **distributed locks**, **clock synchronization** (Lamport, vector clocks), **partition tolerance**, **two-phase commit**, and **gossip protocols**. A Staff-level answer shows you understand not just the algorithms but *why* they exist -- what problem they solve and what they give up.

---

## Consensus Algorithms

Consensus is the problem of getting multiple nodes to agree on a single value, even when some nodes fail or messages are lost. It is the foundation of replicated state machines, distributed databases, and configuration stores.

### Why Consensus Is Hard

- Nodes can crash at any time
- Messages can be delayed, duplicated, reordered, or lost
- There is no shared clock (nodes cannot agree on "now")
- The FLP impossibility result proves that no deterministic consensus algorithm can guarantee termination in an asynchronous system with even one faulty process

Practical algorithms (Raft, Paxos) work around FLP by using timeouts and randomization to make progress with high probability, even though they cannot guarantee it in every theoretical scenario.

### Paxos

Paxos, introduced by Leslie Lamport, is the original consensus algorithm. It operates in two phases:

**Phase 1 (Prepare):**
1. A proposer selects a proposal number `n` and sends `Prepare(n)` to a majority of acceptors
2. Each acceptor promises not to accept proposals with numbers less than `n`, and returns any previously accepted value

**Phase 2 (Accept):**
1. If the proposer receives promises from a majority, it sends `Accept(n, value)` where `value` is either the highest previously accepted value or the proposer's own value
2. Acceptors accept the proposal if they have not promised to a higher number

**Properties:**
- Safety: Only one value can be chosen
- Liveness: Progress is guaranteed if there is a single distinguished proposer (leader)

**Trade-offs:** Paxos is notoriously difficult to understand and implement correctly. Multi-Paxos (for deciding a sequence of values) is even more complex. Production implementations often diverge from the paper, making verification difficult.

**Used by:** Google's Chubby (lock service), Azure Storage.

### Raft

Raft was designed explicitly to be understandable. It provides the same guarantees as Paxos but decomposes the problem into three cleanly separated subproblems: leader election, log replication, and safety.

**Roles:**
- **Leader:** Handles all client requests. Appends entries to its log and replicates to followers.
- **Follower:** Passive. Responds to leader's append requests.
- **Candidate:** Aspiring leader during an election.

**Leader Election:**
```
1. Followers start an election timer (randomized: 150-300ms)
2. When timer expires without hearing from leader:
   -> Become candidate
   -> Increment term
   -> Vote for self
   -> Request votes from all other nodes
3. If majority of votes received -> become leader
4. If another leader's heartbeat received -> revert to follower
5. If election timeout (split vote) -> restart election with new term
```

**Log Replication:**
```
Client -> Leader: Write "x=5"
Leader: Append to local log (uncommitted)
Leader -> Followers: AppendEntries(term, entry)
Followers: Append to local log, respond OK
Leader: Once majority ack -> commit entry
Leader -> Followers: Notify commit
Followers: Apply committed entry to state machine
```

**Safety guarantee:** If a log entry is committed in a given term, it will be present in the logs of all leaders for higher terms.

**Used by:** etcd (Kubernetes), CockroachDB, TiKV, Consul.

**Interview tip:** Raft is the consensus algorithm you should know best. Be prepared to explain leader election, log replication, and how split-brain is prevented (a leader needs a majority of votes, so only one leader per term). If asked about Paxos, explain the high-level idea and note that Raft is equivalent but more practical.

---

## Leader Election

Leader election is a building block used by consensus algorithms and many other distributed systems. The goal is for a group of nodes to agree on a single node to act as leader.

### Mechanisms

**Consensus-based:** Use Raft/Paxos to elect a leader. Strongest guarantee. Used by etcd, ZooKeeper.

**External coordination:** Use a distributed lock service (ZooKeeper, etcd) to acquire a lease. The node holding the lease is the leader. The lease has a TTL -- if the leader fails to renew, another node can acquire it.

**Bully algorithm:** Each node has a priority (e.g., based on ID). When a leader failure is detected, the highest-priority available node becomes leader. Simple but can oscillate if network is flaky.

### Fencing Tokens

A critical problem: a leader may believe it is still the leader after its lease has expired (due to GC pauses, network delays). It may issue writes that conflict with the new leader.

**Solution:** Assign a monotonically increasing fencing token with each lease. The storage layer rejects writes with stale tokens.

```
Leader A: lease expires, token = 42
Leader B: acquires lease, token = 43

Leader A: writes to DB with token 42
DB: rejects (42 < current token 43)

Leader B: writes to DB with token 43
DB: accepts
```

---

## Distributed Locks

Distributed locks provide mutual exclusion across multiple processes/machines. They are used to protect shared resources (e.g., "only one process should process this order at a time").

### Redis-Based Locks (Redlock)

The simplest approach uses Redis with `SET key value NX EX ttl` (set if not exists, with expiry):

```ruby
class DistributedLock
  LOCK_TTL = 10  # seconds

  def acquire(resource_id, owner_id)
    acquired = redis.set(
      "lock:#{resource_id}",
      owner_id,
      nx: true,  # only set if not exists
      ex: LOCK_TTL
    )
    acquired == true
  end

  def release(resource_id, owner_id)
    # Only release if we still own the lock (Lua for atomicity)
    script = <<~LUA
      if redis.call("get", KEYS[1]) == ARGV[1] then
        return redis.call("del", KEYS[1])
      else
        return 0
      end
    LUA
    redis.eval(script, keys: ["lock:#{resource_id}"], argv: [owner_id])
  end
end
```

**Redlock** extends this to multiple independent Redis instances -- acquire the lock on a majority of instances for stronger guarantees.

### Challenges

- **Lock expiry before work completes:** The lock TTL expires while the holder is still working (due to GC pause, slow network). Another process acquires the lock. Now two processes believe they hold the lock.
  - **Mitigation:** Use fencing tokens (as above). Or use lock extension (renew TTL periodically while working).

- **Clock drift:** If TTL is based on wall clock time, clock drift between nodes can cause early or late expiry.

- **Split brain:** Network partition means different sides of the partition may each elect a lock holder.

**Interview tip:** Martin Kleppmann's critique of Redlock is important to know. For strong mutual exclusion, prefer consensus-based systems (ZooKeeper, etcd) over Redis. For "best effort" mutual exclusion (e.g., deduplication), Redis locks are often sufficient.

---

## Clock Synchronization

In a distributed system, there is no global clock. Each node has its own clock that may drift. This creates problems for ordering events, lease expiry, and determining causality.

### Physical Clocks (NTP)

Nodes synchronize their clocks via NTP (Network Time Protocol). NTP can typically achieve accuracy within a few milliseconds over the internet and sub-millisecond on a LAN.

**Problems:** Clock skew still exists. Clocks can jump forward or backward (during NTP sync). Using wall clock time to order events is unreliable.

### Lamport Clocks (Logical Clocks)

A Lamport clock is a simple counter that establishes a partial ordering of events:

1. Each process increments its counter before each event
2. When sending a message, include the current counter
3. When receiving a message, set counter = max(local, received) + 1

**Property:** If event A happened before event B, then `L(A) < L(B)`. But the converse is not true -- `L(A) < L(B)` does not mean A happened before B (concurrent events may have any Lamport ordering).

### Vector Clocks

Vector clocks extend Lamport clocks to capture causality precisely. Each process maintains a vector of counters (one per process):

```
Process A: [A:1, B:0, C:0]  -- A did something
Process B: [A:0, B:1, C:0]  -- B did something independently
Process A sends to B:
Process B: [A:1, B:2, C:0]  -- B received A's message, knows A:1 happened before
```

**Property:** Event X happened before event Y if and only if X's vector is strictly less than Y's vector in all components. If neither is strictly less, the events are concurrent.

**Used by:** DynamoDB (to detect conflicting writes), Riak.

**Trade-off:** Vector clocks grow with the number of processes. For large systems, this metadata overhead becomes significant. Solutions include version vectors and dotted version vectors.

### Hybrid Logical Clocks (HLC)

HLCs combine physical timestamps with logical counters. They provide the benefits of Lamport clocks (causality tracking) while staying close to real wall clock time. Used by CockroachDB.

---

## Partition Tolerance

Network partitions are unavoidable in distributed systems. A partition occurs when two groups of nodes cannot communicate with each other.

### Split Brain

During a partition, each side may believe it is the only surviving group and act independently -- including electing its own leader and accepting writes. This causes data divergence.

**Prevention:**
- **Quorum-based systems:** Require a majority (N/2 + 1) of nodes to agree. Only one side of a partition can have a majority. The minority side refuses writes.
- **Fencing:** Use epoch/term numbers so stale leaders cannot make progress.
- **External arbiter:** A witness node in a third availability zone breaks the tie.

### Handling Partitions in Practice

| Strategy | Behavior | Used By |
|---|---|---|
| Refuse writes (CP) | Minority partition returns errors | etcd, ZooKeeper |
| Accept writes, reconcile later (AP) | Both sides accept writes, merge on healing | Cassandra, DynamoDB |
| Leader in majority partition | Only the partition with the leader accepts writes | Raft-based systems |

---

## Two-Phase Commit (2PC)

2PC is a protocol for atomic commits across multiple participants (e.g., multiple database shards or services). It ensures all participants either commit or abort.

### Protocol

```
Phase 1 (Prepare):
  Coordinator -> all Participants: "Can you commit?"
  Participants: Acquire locks, write to WAL
  Participants -> Coordinator: "Yes (prepared)" or "No (abort)"

Phase 2 (Commit/Abort):
  If all voted Yes:
    Coordinator -> all Participants: "Commit"
    Participants: Commit and release locks
  If any voted No:
    Coordinator -> all Participants: "Abort"
    Participants: Rollback and release locks
```

### The Blocking Problem

If the coordinator crashes after Phase 1 but before Phase 2, participants are stuck: they have voted "yes" and are holding locks, but do not know whether to commit or abort. They are **blocked** until the coordinator recovers.

**Mitigations:**
- **Three-phase commit (3PC):** Adds a "pre-commit" phase to avoid blocking, but requires synchronous communication (impractical in most systems).
- **Coordinator recovery:** Persist the decision in a WAL; on recovery, replay the decision.
- **Timeouts:** Participants abort if they do not hear from the coordinator within a timeout (risks inconsistency).

**Interview tip:** 2PC is a classic interview topic. Know its protocol, the blocking problem, and why distributed systems often prefer saga patterns (eventual consistency) over 2PC (strong consistency but fragile). 2PC is used within a single database for cross-shard transactions but is generally avoided across services.

---

## Gossip Protocols

Gossip (epidemic) protocols propagate information through a network by having each node periodically share state with a random subset of peers. Information spreads exponentially, reaching all nodes in O(log N) rounds.

### How It Works

```
Round 1: Node A tells Node B about update X
Round 2: A tells C, B tells D about update X
Round 3: A tells E, B tells F, C tells G, D tells H about update X
  -> After O(log N) rounds, all nodes know about X
```

### Use Cases

- **Membership detection:** Nodes gossip about which nodes are alive/dead (SWIM protocol)
- **Metadata propagation:** Distribute cluster metadata (Cassandra's ring topology)
- **Failure detection:** Nodes track heartbeat counters; if a node's counter stops incrementing, it is suspected dead
- **Aggregate computation:** Compute cluster-wide statistics (average load) without a coordinator

### Properties

- **Probabilistic guarantees** -- not guaranteed to reach all nodes, but probability of missing a node is vanishingly small
- **Scalable** -- each node only communicates with a constant number of peers per round
- **Robust** -- no single point of failure, works well with network partitions and node failures
- **Eventually consistent** -- information takes time to propagate

**Used by:** Cassandra (ring topology), Consul (membership), Redis Cluster (node state), Amazon S3 (replication metadata).

---

## Quorums

A quorum is the minimum number of nodes that must participate in an operation for it to be valid. Quorum-based systems ensure that any two quorums overlap, guaranteeing that reads see the latest writes.

### Read/Write Quorums

For a system with N replicas:
- **W** = number of nodes that must acknowledge a write
- **R** = number of nodes that must respond to a read
- **Guarantee:** If W + R > N, every read quorum overlaps with every write quorum, ensuring the read sees the latest write

```
N = 3 replicas
W = 2 (write to majority)
R = 2 (read from majority)
W + R = 4 > 3 -> guaranteed overlap
```

### Sloppy Quorums

In a sloppy quorum, if the designated nodes for a key are unavailable, the system writes to other nodes temporarily (hinted handoff). This improves availability but weakens consistency.

---

## Putting It Together

```
Need strong consistency across replicas?
  -> Consensus (Raft/Paxos) for leader election + replicated log
  -> Quorum reads/writes (W + R > N)

Need to coordinate across services atomically?
  -> 2PC (within a DB, across shards)
  -> Sagas (across services, eventual consistency)

Need to detect failures?
  -> Gossip protocols + heartbeats
  -> Health checks + liveness probes

Need to order events?
  -> Lamport clocks (partial order)
  -> Vector clocks (causal order)
  -> HLC (causal order close to wall time)

Need mutual exclusion?
  -> Distributed locks (etcd/ZooKeeper for strong, Redis for best-effort)
  -> Always use fencing tokens
```

---

## Related Topics

- [[../01-databases-and-storage/index|Databases & Storage]] -- CAP theorem, consistency models, replication
- [[../04-fault-tolerance-and-reliability/index|Fault Tolerance]] -- handling failures in distributed systems
- [[../03-scaling-writes/index|Scaling Writes]] -- sharding and cross-shard coordination
- [[../05-async-processing/index|Async Processing]] -- distributed queues and ordering
- [[../07-real-time-systems/index|Real-Time Systems]] -- CRDTs for conflict-free replication
