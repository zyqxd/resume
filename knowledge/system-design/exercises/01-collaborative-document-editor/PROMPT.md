# Exercise: Design a Real-Time Collaborative Document Editor

## Prompt

Design a system like Google Docs that allows multiple users to simultaneously edit the same document in real time. Changes made by one user should appear on all other users' screens within a few hundred milliseconds.

## Requirements

### Functional Requirements
- Multiple users can open and edit the same document simultaneously
- Changes appear in real time (< 500ms) on all connected clients
- Users can see each other's cursors and selections
- The document converges to a consistent state regardless of edit ordering
- Support for rich text (bold, italic, headings, lists)
- Edit history and undo/redo
- Offline editing with sync on reconnect

### Non-Functional Requirements
- Up to 50 concurrent editors per document
- Millions of documents total
- Sub-second latency for edit propagation
- No data loss -- every keystroke is preserved
- Available globally (multi-region)

### Out of Scope (clarify with interviewer)
- Comments and suggestions
- Version history / named versions
- Access control and permissions
- Image and table support
- Spell check / grammar check

## Constraints
- Assume a user base of 100M registered users
- 10M daily active users
- Average document size: 50KB
- Peak concurrent editors per document: 50
- Peak concurrent documents being edited: 500K

## Key Topics Tested
- [[../../real-time-systems/index|Real-Time Systems]] -- WebSockets, CRDTs vs OT
- [[../../scaling-writes/index|Scaling Writes]] -- handling concurrent writes, conflict resolution
- [[../../distributed-systems-fundamentals/index|Distributed Systems]] -- consistency, ordering
- [[../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- offline support, reconnection
