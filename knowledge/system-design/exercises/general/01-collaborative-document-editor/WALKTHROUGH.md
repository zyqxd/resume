# Walkthrough: Design a Real-Time Collaborative Document Editor

## Step 1: Clarify Requirements and Scope

Before drawing anything, confirm the scope with the interviewer:
- How many concurrent editors per document? (50 max -- not millions)
- Is offline editing required? (Yes -- this changes the architecture significantly)
- What granularity of real-time? (Sub-second, not frame-by-frame)
- Rich text or plain text? (Rich text -- affects the data model)

This scoping eliminates "design a system for millions of concurrent editors on one document" (which would be a very different problem).

---

## Step 2: High-Level Architecture

```
Clients (Browser/Mobile)
    |
    | WebSocket connections
    v
+-------------------+
| WebSocket Gateway |  (stateful, sticky connections)
| (regional)        |
+--------+----------+
         |
    +----v----+
    |Document |  (one per active document, holds operational state)
    |Session  |
    |Service  |
    +----+----+
         |
    +----v---------+    +------------------+
    |Document Store|    | Operation Log    |
    |(PostgreSQL)  |    | (append-only)    |
    +--------------+    +------------------+
```

### Core Components

1. **WebSocket Gateway** -- maintains persistent connections with clients. Routes operations to the correct document session.
2. **Document Session Service** -- the coordination layer. One logical session per active document. Receives operations, resolves conflicts, broadcasts to other participants.
3. **Document Store** -- persistent storage for document content (PostgreSQL).
4. **Operation Log** -- append-only log of all operations for history, undo, and crash recovery.

---

## Step 3: Conflict Resolution -- CRDTs vs OT

This is the key architectural decision. Both CRDTs and OT solve the same problem: multiple users editing simultaneously without conflicts.

### Decision: CRDTs (with Yjs)

For this design, CRDTs are the better choice because:
- They support offline editing natively (edits merge on reconnect)
- No central coordinator required for conflict resolution
- Libraries like Yjs are production-proven (used by many collaborative apps)
- They compose well with rich text (Yjs supports XML-like document structures)

OT would be a valid choice if offline editing is not required and you want simpler reasoning (Google Docs uses OT). Mention this trade-off to the interviewer.

### How CRDTs Work Here

Each character (or block element) in the document has a unique ID composed of (client_id, sequence_number). Insertions and deletions reference these IDs rather than positional indices, making them commutative -- they can be applied in any order and converge to the same result.

```
User A inserts "Hello" at start:
  [A:1]H [A:2]e [A:3]l [A:4]l [A:5]o

User B (concurrently) inserts "Hi" at start:
  [B:1]H [B:2]i

After sync, both clients converge to the same document:
  [B:1]H [B:2]i [A:1]H [A:2]e [A:3]l [A:4]l [A:5]o
  (or the reverse, depending on tie-breaking by client_id)
```

### Yjs Architecture

Yjs uses a CRDT called YATA (Yet Another Transformation Approach):
- Each element stores a reference to its left and right neighbors at insertion time
- Concurrent inserts between the same neighbors are ordered by client ID
- Deletions are tombstoned (marked as deleted but not removed, to preserve structure)

---

## Step 4: Real-Time Communication

### WebSocket Protocol

Clients connect via WebSocket to the nearest regional gateway. The connection lifecycle:

```
1. Client opens document -> HTTP request to get document metadata + initial state
2. Client establishes WebSocket connection to gateway
3. Client sends "join document" message
4. Gateway routes to document session service
5. Session service adds client to participant list
6. Client receives current document state (full CRDT state or snapshot + recent ops)
7. Bidirectional sync begins:
   - Client -> Server: local operations (edits)
   - Server -> Client: remote operations (other users' edits), cursor positions
```

### Operation Flow

```
User A types "x":
  1. Apply locally (instant -- no round trip)
  2. Send operation to server via WebSocket
  3. Server receives operation
  4. Server validates and persists to operation log
  5. Server broadcasts to all other participants (User B, C, ...)
  6. Other clients apply the operation to their local CRDT
  7. All clients converge to the same state
```

**Key insight:** The local apply (step 1) happens immediately. The user never waits for a server round trip. This is why CRDTs are ideal -- they guarantee convergence regardless of operation ordering.

---

## Step 5: Document Session Service

The document session service is the coordination layer. One logical session exists per active document.

### State Management

```
DocumentSession {
  document_id: String
  participants: Set<ClientConnection>
  crdt_state: YDoc  # In-memory CRDT document state
  last_persisted_version: Integer
  cursor_positions: Map<UserId, CursorPosition>
}
```

### Scaling Document Sessions

**Problem:** A single server cannot hold sessions for all active documents.

**Solution:** Consistent hashing to assign documents to session servers. Each document's session lives on exactly one server. If a server fails, its documents are reassigned.

```
Document "doc-abc" -> hash -> Session Server 3
Document "doc-xyz" -> hash -> Session Server 1

All WebSocket connections for "doc-abc" route to Session Server 3
```

**Alternative:** Use a pub/sub layer (Redis) so that any server can receive operations and broadcast to other participants. This avoids sticky routing but adds latency and complexity.

### Persistence Strategy

- **Operation log:** Every operation is appended to a durable log (Kafka or PostgreSQL append-only table). This is the source of truth.
- **Periodic snapshots:** Every N operations (or every M seconds), serialize the full CRDT state and store it. This bounds recovery time.
- **Document store:** The latest snapshot is stored in PostgreSQL for serving initial document loads.

```
Recovery after crash:
  1. Load latest snapshot (version 1000)
  2. Replay operations from log after version 1000
  3. Reconstructed state = snapshot + replayed ops
```

---

## Step 6: Cursor and Presence

### Cursor Positions

Each client sends its cursor position (as a CRDT-relative position, not a character index) with every operation or on a separate heartbeat (every 100-200ms).

The server broadcasts cursor positions to all participants. Clients render colored cursors/selections for each remote user.

**Optimization:** Cursor updates are ephemeral -- they do not need to be persisted. Use the WebSocket connection directly, no need to write to the operation log.

### Presence

Track who is viewing/editing the document:
- Client sends heartbeat every 15 seconds
- Server removes from participant list after 60 seconds without heartbeat
- Participant list is broadcast to all connected clients

---

## Step 7: Offline Editing

This is where CRDTs shine. When a client goes offline:

1. Client continues editing locally, applying operations to its local CRDT
2. Operations are queued in local storage (IndexedDB)
3. On reconnect:
   a. Client sends all queued operations to the server
   b. Server sends all operations that occurred while client was offline
   c. Both sides apply received operations to their CRDTs
   d. CRDTs guarantee convergence -- no manual conflict resolution needed

**Edge case:** If the offline period is very long (days), the queued operations and missed operations may be large. Send a full state sync (snapshot exchange) rather than individual operations.

---

## Step 8: Rich Text Data Model

Rich text adds formatting (bold, italic, headings) to the CRDT. Yjs supports this through shared types:

```
YDoc
  └── YXmlFragment (document root)
       ├── YXmlElement (paragraph)
       │    └── YXmlText ("Hello ")
       │         └── attributes: {}
       │    └── YXmlText ("world")
       │         └── attributes: {bold: true}
       ├── YXmlElement (heading, level: 2)
       │    └── YXmlText ("Section Title")
       └── YXmlElement (list-item)
            └── YXmlText ("Item 1")
```

Formatting attributes (bold, italic) are stored on text ranges and merge correctly under concurrent edits.

---

## Step 9: Storage and Scale Estimates

### Write Volume

- 50 concurrent editors per document
- ~2 operations/second per active editor (typing, formatting)
- 500K concurrent documents
- Total: 50 * 2 * 500K = 50M operations/second (peak)

This is high. Not every operation needs synchronous database persistence:
- Batch writes to the operation log (flush every 100ms or every 100 ops)
- Persist snapshots less frequently (every 1000 ops or every 30 seconds)
- Use Kafka for the operation log (designed for this throughput)

### Storage

- Average document: 50KB
- 100M documents total: 5TB of document data
- Operation log retention: 30 days (for undo/history), then compact
- Snapshots: ~2x document size (CRDT metadata overhead)

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Conflict resolution | CRDTs (Yjs) | OT | Offline support, no central coordinator |
| Real-time transport | WebSockets | SSE | Need bidirectional (client sends edits) |
| Operation log | Kafka | PostgreSQL append | Higher throughput, partition by document |
| Document store | PostgreSQL | MongoDB | Rich text is structured, benefits from SQL |
| Session routing | Consistent hashing | Pub/sub broadcast | Lower latency, simpler reasoning per document |

---

## Common Mistakes to Avoid

1. **Using positional indices for operations.** "Insert 'x' at position 5" breaks under concurrent edits. Use CRDTs or OT -- never raw positional indices.

2. **Ignoring offline editing.** If the interviewer asks about it, you need a strategy. CRDTs handle it naturally; OT requires significant additional work.

3. **Single point of failure in the session layer.** If the session server for a document crashes, clients lose their connection. Design for failover: operation log enables recovery, clients reconnect and resync.

4. **Treating cursor sync like document sync.** Cursor positions are ephemeral and high-frequency. Do not persist them or route them through the operation log. Send them over WebSockets directly.

5. **Forgetting about the initial document load.** A new client joining a document with 10,000 operations needs a snapshot, not a full replay of all operations.

6. **Oversimplifying the data model.** Plain text CRDTs are simpler than rich text CRDTs. If the interviewer asks about rich text, discuss how formatting attributes are handled (Yjs XML model or Peritext approach).

---

## Related Topics

- [[../../../real-time-systems/index|Real-Time Systems]] -- WebSockets, CRDTs, OT
- [[../../../scaling-writes/index|Scaling Writes]] -- handling high write throughput, event sourcing
- [[../../../distributed-systems-fundamentals/index|Distributed Systems]] -- consistency, convergence
- [[../../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- offline support, crash recovery
- [[../../../databases-and-storage/index|Databases & Storage]] -- PostgreSQL for documents, Kafka for operation log
