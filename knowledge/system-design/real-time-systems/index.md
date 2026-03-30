# Real-Time Systems

Real-time communication is a core system design topic because many modern products require instant feedback: chat applications, collaborative editing, live dashboards, notifications, gaming, and financial trading. The key technologies are **WebSockets**, **Server-Sent Events (SSE)**, **long polling**, **pub/sub architectures**, and **fan-out patterns**. Advanced topics include **presence systems** and **real-time sync** via CRDTs and Operational Transformation. The Staff-level differentiator is understanding the scaling challenges: how do you fan out a message to millions of subscribers with low latency?

---

## WebSockets

WebSockets provide a persistent, full-duplex TCP connection between client and server. After an HTTP upgrade handshake, both sides can send messages at any time without the overhead of new HTTP requests.

### How It Works

```
Client                          Server
  |  -- HTTP GET /ws (Upgrade) -->  |
  |  <-- 101 Switching Protocols -- |
  |                                 |
  |  <-- message (server push) --   |
  |  -- message (client send) -->   |
  |  <-- message (server push) --   |
  |          ...                    |
  |  -- close frame -->             |
  |  <-- close frame --             |
```

### Strengths

- True bidirectional communication
- Very low latency (no HTTP overhead per message)
- Efficient for high-frequency updates (chat, gaming, trading)
- Native browser support

### Challenges

- **Stateful connections** -- each connection is pinned to a specific server, complicating load balancing. Sticky sessions or a connection registry are required.
- **Connection limits** -- each WebSocket consumes a file descriptor. A single server can typically handle 50K-500K connections depending on hardware and message rates.
- **Reconnection logic** -- the client must handle disconnects, reconnect with backoff, and replay missed messages (requires server-side message buffering or a message broker).
- **Load balancer support** -- not all LBs handle WebSocket upgrades well. Layer 4 (TCP) load balancing or explicit WebSocket support is needed.
- **Firewall/proxy issues** -- some corporate proxies and firewalls may drop WebSocket connections.

### Scaling WebSockets

```
                    +-------------------+
                    |   Load Balancer   |
                    | (Layer 4 / sticky)|
                    +--------+----------+
                             |
              +--------------+--------------+
              |              |              |
        +-----v----+  +-----v----+  +------v---+
        |  WS Srv 1 |  |  WS Srv 2 |  |  WS Srv 3 |
        +-----+----+  +-----+----+  +------+---+
              |              |              |
              +--------------+--------------+
                             |
                     +-------v-------+
                     |  Pub/Sub Bus  |
                     |  (Redis/Kafka)|
                     +---------------+

  When Server 1 receives a message for a user connected to Server 3:
  1. Publish message to pub/sub bus
  2. Server 3 picks it up from the bus
  3. Server 3 pushes to the connected client
```

The pub/sub bus (Redis Pub/Sub, Kafka, NATS) decouples message routing from connection management. Each WebSocket server subscribes to channels relevant to its connected clients.

---

## Server-Sent Events (SSE)

SSE is a one-directional protocol where the server pushes events to the client over a single long-lived HTTP connection. The client uses the `EventSource` API.

### How It Works

```
Client                           Server
  |  -- GET /events (Accept: text/event-stream) -->  |
  |  <-- 200 OK (Content-Type: text/event-stream) -- |
  |  <-- data: {"msg": "hello"}\n\n                  |
  |  <-- data: {"msg": "update"}\n\n                 |
  |          ... (connection stays open)              |
```

### When to Choose SSE Over WebSockets

- **Server-to-client only** -- notifications, live feeds, dashboards, stock tickers
- **Simpler infrastructure** -- works over standard HTTP, no upgrade handshake, friendly to proxies and CDNs
- **Automatic reconnection** -- the `EventSource` API handles reconnection and provides a `Last-Event-ID` header for resuming
- **HTTP/2 multiplexing** -- SSE connections share the same TCP connection under HTTP/2, avoiding the connection-per-stream overhead

### Limitations

- Unidirectional (server to client only)
- Limited to text data (no binary)
- Maximum of ~6 connections per domain in HTTP/1.1 browsers (not an issue with HTTP/2)
- No built-in support in some older environments

**Interview tip:** SSE is often the better choice when you only need server-to-client push. It is simpler, cheaper, and better supported by existing HTTP infrastructure. Reserve WebSockets for truly bidirectional use cases.

---

## Long Polling

Long polling is a technique where the client makes an HTTP request, and the server holds the request open until new data is available (or a timeout occurs). When data arrives, the server responds, and the client immediately opens a new request.

### How It Works

```
Client                          Server
  |  -- GET /poll -->               |
  |         (server holds request)  |
  |         ... (waiting for data)  |
  |  <-- 200 OK {new data}     --  |
  |  -- GET /poll (immediately) --> |
  |         (server holds again)    |
```

### Trade-offs vs WebSockets and SSE

| Feature | Long Polling | SSE | WebSockets |
|---|---|---|---|
| Direction | Server -> Client | Server -> Client | Bidirectional |
| Connection | New HTTP per response | Persistent HTTP | Persistent TCP |
| Latency | Higher (reconnect overhead) | Low | Lowest |
| Compatibility | Universal | Good | Good |
| Server load | Higher (constant reconnects) | Moderate | Moderate |
| Complexity | Simple | Simple | Complex |

**When to use:** Long polling is a fallback when WebSockets and SSE are not available (legacy environments, restrictive firewalls). Modern systems should prefer SSE or WebSockets.

---

## Pub/Sub Architectures

Pub/Sub decouples message producers from consumers. Publishers emit messages to topics/channels; subscribers receive messages from topics they have subscribed to. This is the backbone of scalable real-time systems.

### In-Memory Pub/Sub (Redis Pub/Sub)

- Ultra-low latency (sub-millisecond)
- No message persistence -- if a subscriber is offline, it misses the message
- Best for ephemeral real-time data (typing indicators, presence, cursor positions)

### Persistent Pub/Sub (Kafka, Pulsar)

- Messages are durably stored in an ordered log
- Consumers can replay from any offset
- Higher latency than in-memory (milliseconds)
- Best for event streams that need durability and replay

### Channel Design Patterns

```
Per-user channel:    user:{user_id}:notifications
Per-room channel:    room:{room_id}:messages
Per-topic channel:   feed:{topic}:updates
Wildcard patterns:   user:*:status (subscribe to all user statuses)
```

**Interview tip:** Redis Pub/Sub does not persist messages. If a subscriber disconnects and reconnects, it misses messages sent during the gap. For guaranteed delivery, use Redis Streams, Kafka, or a dedicated message broker. See [[../async-processing/index|Async Processing]] for durable messaging patterns.

---

## Fan-Out Patterns

Fan-out is the problem of delivering a single message to many recipients. This is central to social feeds, group chats, and notification systems.

### Fan-Out on Write (Push Model)

When a user posts content, immediately write it to the feed/inbox of every follower. Reads are simple key lookups.

```
User posts tweet -> write to timelines of all 10K followers
Read timeline -> simple key lookup, already precomputed
```

**Pros:** Fast reads (O(1) lookup). **Cons:** High write amplification for users with many followers. A celebrity with 10M followers means 10M writes per post.

### Fan-Out on Read (Pull Model)

When a user reads their feed, query all accounts they follow and merge results at read time.

```
User opens timeline -> query posts from all 500 accounts they follow -> merge & sort
```

**Pros:** No write amplification. **Cons:** Slow reads (must query and merge from many sources). High read-time computation.

### Hybrid Approach (Used by Twitter/X)

- **Fan-out on write** for users with few followers (the common case)
- **Fan-out on read** for celebrity accounts (avoid 10M write fan-out)
- Merge both at read time

This is the canonical answer for "Design a Twitter feed" interview questions.

---

## Presence Systems

Presence tracks whether a user is online, offline, idle, or in a specific state. Presence is deceptively hard to scale because it requires frequent updates (heartbeats) and broad visibility (all your contacts need to see your status).

### Heartbeat-Based Presence

Clients send periodic heartbeats (every 15-30 seconds). If the server does not receive a heartbeat within a timeout window, it marks the user as offline.

```ruby
class PresenceTracker
  TIMEOUT = 60 # seconds

  def heartbeat(user_id)
    redis.setex("presence:#{user_id}", TIMEOUT, "online")
    publish_status_change(user_id, "online")
  end

  def status(user_id)
    redis.get("presence:#{user_id}") || "offline"
  end

  private

  def publish_status_change(user_id, status)
    redis.publish("presence:#{user_id}", status)
  end
end
```

### Scaling Presence

- **Storage:** Redis with TTL-based keys (automatic expiry = offline detection)
- **Distribution:** Pub/sub for propagating status changes to interested parties
- **Optimization:** Only notify when status *changes*, not on every heartbeat. Batch presence queries for contact lists.

---

## Real-Time Sync: CRDTs and Operational Transformation

When multiple users edit the same data simultaneously (collaborative editing, shared whiteboards), you need a conflict resolution strategy.

### Operational Transformation (OT)

OT transforms concurrent operations against each other so they can be applied in any order and converge to the same result. Used by Google Docs.

**How it works:** When two users simultaneously insert text at different positions, the server transforms the operations so their effects are correct regardless of arrival order.

```
User A inserts "X" at position 5
User B inserts "Y" at position 3
  -> B's insert shifts A's position to 6
  -> Transformed: A inserts "X" at position 6, B inserts "Y" at position 3
```

**Trade-offs:** Requires a central server to coordinate transformations. Complex to implement correctly (many edge cases). Proven at scale (Google Docs has used it for 15+ years).

### CRDTs (Conflict-free Replicated Data Types)

CRDTs are data structures that can be merged without coordination. Any replica can accept writes independently, and merging replicas always converges to the same state.

**Types of CRDTs:**
- **G-Counter** -- grow-only counter. Each node maintains its own count; merge = take max per node.
- **PN-Counter** -- supports increment and decrement (two G-Counters).
- **LWW-Register** -- last-writer-wins based on timestamps.
- **OR-Set** -- observed-remove set. Supports add and remove without conflicts.
- **RGA (Replicated Growable Array)** -- for collaborative text editing.

**Trade-offs:**
- No central coordinator needed (truly peer-to-peer)
- Automatically convergent (strong eventual consistency)
- Higher storage overhead (metadata for conflict resolution)
- Not all data structures have natural CRDT equivalents
- More complex to reason about than OT for text editing

### OT vs CRDTs Comparison

| Aspect | OT | CRDTs |
|---|---|---|
| Architecture | Centralized server | Decentralized / P2P |
| Consistency | Immediate (via server) | Eventual (converges) |
| Offline support | Limited | Excellent |
| Complexity | Algorithm complexity | Data structure complexity |
| Proven at scale | Google Docs | Figma, Yjs, Automerge |
| Best for | Document editing | Distributed state, offline-first |

---

## Putting It Together: Choosing a Real-Time Strategy

```
Need bidirectional communication?
  YES -> WebSockets
    + Pub/Sub bus for multi-server routing
  NO  -> Is it server-to-client push only?
    YES -> SSE (simpler, HTTP-native)
    NO  -> REST with polling (rare in modern systems)

Need to handle millions of concurrent connections?
  -> Shard connections across servers
  -> Use pub/sub for cross-server message routing
  -> Consider edge/regional deployment

Need collaborative editing?
  -> Online-first: OT (proven, centralized)
  -> Offline-first: CRDTs (decentralized, convergent)
  -> Consider libraries: Yjs (CRDT), ShareDB (OT)

Need presence?
  -> Heartbeat + Redis TTL + pub/sub for status propagation
```

---

## Related Topics

- [[../scaling-reads/index|Scaling Reads]] -- caching and replication for read-heavy real-time feeds
- [[../scaling-writes/index|Scaling Writes]] -- fan-out on write for feeds and notifications
- [[../async-processing/index|Async Processing]] -- durable messaging with Kafka/queues
- [[../fault-tolerance-and-reliability/index|Fault Tolerance]] -- handling connection failures and reconnection
- [[../distributed-systems-fundamentals/index|Distributed Systems]] -- consistency models for real-time sync
