# TypeScript Snippets

Idiomatic TypeScript implementations of common interview data structures and algorithms. Written for Node 18+ / modern TS with strict mode.

---

## Data Structures

- [[min-heap|MinHeap]] — generic binary heap with custom comparator

---

## Notes

- All snippets are generic (`<T>`) where the shape permits, accepting a `compare` function in the style of `Array.prototype.sort`.
- Prefer zero-dependency implementations — no `lodash`, no external heap libraries — since interviews typically disallow them.
- Return `undefined` (not `null`) for missing values, matching TypeScript/JS conventions.
