# Advanced Data Structures

The basic toolkit (arrays, hash maps, trees, heaps) handles 80% of interview problems. The remaining 20% — and most staff-level differentiators — require specialized structures. You won't implement a segment tree from scratch in a 45-minute round, but you need to know when one is the right tool and be able to sketch the approach. More importantly, structures like Union-Find, monotonic stacks, and LRU caches show up directly as interview problems. Knowing these cold signals depth.

---

## Union-Find (Disjoint Set Union)

Union-Find tracks a collection of disjoint sets and supports two operations: **find** (which set does this element belong to?) and **union** (merge two sets). With path compression and union by rank, both operations run in nearly O(1) amortized — technically O(α(n)) where α is the inverse Ackermann function, which is effectively constant for any practical input.

This is the go-to structure for connected components, cycle detection in undirected graphs, and Kruskal's MST algorithm.

```mermaid
graph TD
    subgraph "Before Union(1,5)"
        A0((0)) --> A1((1))
        A2((2)) --> A1
        A3((3)) --> A4((4))
        A5((5)) --> A4
    end
```

```mermaid
graph TD
    subgraph "After Union(1,5) with path compression"
        B0((0)) --> B1((1))
        B2((2)) --> B1
        B3((3)) --> B1
        B5((5)) --> B1
        B4((4)) --> B1
    end
```

```typescript
class UnionFind {
  parent: number[];
  rank: number[];
  count: number; // number of connected components

  constructor(n: number) {
    this.parent = Array.from({ length: n }, (_, i) => i);
    this.rank = new Array(n).fill(0);
    this.count = n;
  }

  find(x: number): number {
    // Iterative path compression — flattens the tree
    let root = x;
    while (this.parent[root] !== root) root = this.parent[root];
    while (this.parent[x] !== root) {
      const next = this.parent[x];
      this.parent[x] = root;
      x = next;
    }
    return root;
  }

  union(x: number, y: number): boolean {
    let rx = this.find(x);
    let ry = this.find(y);
    if (rx === ry) return false;

    // Union by rank — attach shorter tree under taller
    if (this.rank[rx] < this.rank[ry]) [rx, ry] = [ry, rx];
    this.parent[ry] = rx;
    if (this.rank[rx] === this.rank[ry]) this.rank[rx] += 1;
    this.count -= 1;
    return true;
  }

  connected(x: number, y: number): boolean {
    return this.find(x) === this.find(y);
  }
}
```

**Interview problems:** Number of Islands (alternative to DFS), Redundant Connection (cycle detection), Accounts Merge, Earliest Moment When Everyone Becomes Friends, Number of Provinces.

---

## Monotonic Stack

A monotonic stack maintains elements in strictly increasing or decreasing order. When a new element violates the ordering, you pop until the invariant is restored. This gives you O(n) solutions to problems that naively require O(n^2) — specifically "next greater/smaller element" patterns.

The key insight: each element is pushed and popped at most once, so despite the inner while loop, total work is O(n).

```typescript
// Next Greater Element: for each element, find the first larger element to its right
function nextGreaterElements(nums: number[]): number[] {
  const n = nums.length;
  const result = new Array(n).fill(-1);
  const stack: number[] = []; // stores indices, monotonically decreasing values

  for (let i = 0; i < n; i++) {
    while (stack.length > 0 && nums[stack[stack.length - 1]] < nums[i]) {
      result[stack.pop()!] = nums[i];
    }
    stack.push(i);
  }
  return result;
}

// Largest Rectangle in Histogram — classic monotonic stack problem
function largestRectangleArea(heights: number[]): number {
  const stack: number[] = []; // indices of increasing heights
  let maxArea = 0;

  for (let i = 0; i <= heights.length; i++) {
    const h = i === heights.length ? 0 : heights[i];
    while (stack.length > 0 && heights[stack[stack.length - 1]] > h) {
      const height = heights[stack.pop()!];
      const width = stack.length === 0 ? i : i - stack[stack.length - 1] - 1;
      maxArea = Math.max(maxArea, height * width);
    }
    stack.push(i);
  }
  return maxArea;
}
```

**Monotonic Queue** extends this pattern for sliding window problems. Use a deque where the front always holds the current window's max/min.

```typescript
// Sliding Window Maximum — O(n) with monotonic deque
function maxSlidingWindow(nums: number[], k: number): number[] {
  const deque: number[] = []; // stores indices, values are monotonically decreasing
  const result: number[] = [];

  for (let i = 0; i < nums.length; i++) {
    // Remove elements outside the window
    if (deque.length > 0 && deque[0] <= i - k) deque.shift();
    // Maintain decreasing order
    while (deque.length > 0 && nums[deque[deque.length - 1]] <= nums[i]) deque.pop();
    deque.push(i);
    if (i >= k - 1) result.push(nums[deque[0]]);
  }
  return result;
}
```

**Interview problems:** Daily Temperatures, Trapping Rain Water, Sliding Window Maximum, Stock Span, Sum of Subarray Minimums.

---

## LRU Cache

The most classic design-style data structure problem. An LRU (Least Recently Used) cache combines a hash map for O(1) lookups with a doubly-linked list for O(1) insertion/deletion and ordering. Every `get` and `put` runs in O(1).

```mermaid
graph LR
    subgraph "LRU Cache (capacity=3)"
        HM[Hash Map] -->|key: 'a'| N1
        HM -->|key: 'b'| N2
        HM -->|key: 'c'| N3

        HEAD[Head<br>dummy] <--> N3["Node C<br>most recent"] <--> N2["Node B"] <--> N1["Node A<br>least recent"] <--> TAIL[Tail<br>dummy]
    end

    style HEAD fill:#555,color:#fff
    style TAIL fill:#555,color:#fff
```

```typescript
class LRUNode {
  key: number;
  val: number;
  prev: LRUNode | null = null;
  next: LRUNode | null = null;

  constructor(key = 0, val = 0) {
    this.key = key;
    this.val = val;
  }
}

class LRUCache {
  private cap: number;
  private map: Map<number, LRUNode>;
  private head: LRUNode; // dummy head (most recent side)
  private tail: LRUNode; // dummy tail (least recent side)

  constructor(capacity: number) {
    this.cap = capacity;
    this.map = new Map();
    this.head = new LRUNode();
    this.tail = new LRUNode();
    this.head.next = this.tail;
    this.tail.prev = this.head;
  }

  get(key: number): number {
    if (!this.map.has(key)) return -1;
    const node = this.map.get(key)!;
    this.moveToFront(node);
    return node.val;
  }

  put(key: number, value: number): void {
    if (this.map.has(key)) {
      const node = this.map.get(key)!;
      node.val = value;
      this.moveToFront(node);
    } else {
      if (this.map.size >= this.cap) this.evict();
      const node = new LRUNode(key, value);
      this.map.set(key, node);
      this.addToFront(node);
    }
  }

  private addToFront(node: LRUNode): void {
    node.next = this.head.next;
    node.prev = this.head;
    this.head.next!.prev = node;
    this.head.next = node;
  }

  private remove(node: LRUNode): void {
    node.prev!.next = node.next;
    node.next!.prev = node.prev;
  }

  private moveToFront(node: LRUNode): void {
    this.remove(node);
    this.addToFront(node);
  }

  private evict(): void {
    const lru = this.tail.prev!;
    this.remove(lru);
    this.map.delete(lru.key);
  }
}
```

**Interview tip:** Interviewers love follow-ups: "What if this needs to be thread-safe?" (add a mutex around get/put), "What about TTL-based expiration?" (add timestamps, lazy eviction on access or background sweep), "LFU instead?" (add frequency counter + min-frequency tracking).

---

## Segment Tree

Segment trees answer range queries (sum, min, max) and handle point/range updates in O(log n). If an interviewer gives you a problem with repeated range queries on a mutable array, segment tree is likely the answer.

```mermaid
graph TD
    N1["[0,3] sum=10"] --> N2["[0,1] sum=3"]
    N1 --> N3["[2,3] sum=7"]
    N2 --> N4["[0,0] val=1"]
    N2 --> N5["[1,1] val=2"]
    N3 --> N6["[2,2] val=3"]
    N3 --> N7["[3,3] val=4"]

    style N1 fill:#4a90d9,color:#fff
    style N2 fill:#7ab648,color:#fff
    style N3 fill:#7ab648,color:#fff
```

```typescript
class SegmentTree {
  private n: number;
  private tree: number[];

  constructor(arr: number[]) {
    this.n = arr.length;
    this.tree = new Array(4 * this.n).fill(0);
    this.build(arr, 1, 0, this.n - 1);
  }

  update(idx: number, val: number, node = 1, lo = 0, hi = this.n - 1): void {
    if (lo === hi) {
      this.tree[node] = val;
      return;
    }
    const mid = Math.floor((lo + hi) / 2);
    if (idx <= mid) {
      this.update(idx, val, 2 * node, lo, mid);
    } else {
      this.update(idx, val, 2 * node + 1, mid + 1, hi);
    }
    this.tree[node] = this.tree[2 * node] + this.tree[2 * node + 1];
  }

  query(ql: number, qr: number, node = 1, lo = 0, hi = this.n - 1): number {
    if (ql > hi || qr < lo) return 0;          // no overlap
    if (ql <= lo && hi <= qr) return this.tree[node]; // total overlap
    const mid = Math.floor((lo + hi) / 2);
    return this.query(ql, qr, 2 * node, lo, mid) + this.query(ql, qr, 2 * node + 1, mid + 1, hi);
  }

  private build(arr: number[], node: number, lo: number, hi: number): void {
    if (lo === hi) {
      this.tree[node] = arr[lo];
      return;
    }
    const mid = Math.floor((lo + hi) / 2);
    this.build(arr, 2 * node, lo, mid);
    this.build(arr, 2 * node + 1, mid + 1, hi);
    this.tree[node] = this.tree[2 * node] + this.tree[2 * node + 1];
  }
}
```

**When to use Segment Tree vs Fenwick Tree:** Fenwick trees (BIT) are simpler and use less memory, but only handle prefix-based operations. Segment trees are more flexible — they support arbitrary range queries, lazy propagation for range updates, and can be adapted for min/max queries. If the problem is just prefix sums with point updates, use Fenwick. Otherwise, segment tree.

---

## Fenwick Tree (Binary Indexed Tree)

A Fenwick tree supports prefix sum queries and point updates in O(log n) with minimal code. It exploits the binary representation of indices — each index is responsible for a range determined by its lowest set bit.

```typescript
class FenwickTree {
  private n: number;
  private tree: number[];

  constructor(n: number) {
    this.n = n;
    this.tree = new Array(n + 1).fill(0); // 1-indexed
  }

  update(i: number, delta: number): void {
    i += 1; // convert to 1-indexed
    while (i <= this.n) {
      this.tree[i] += delta;
      i += i & -i; // add lowest set bit
    }
  }

  prefixSum(i: number): number {
    i += 1; // convert to 1-indexed
    let sum = 0;
    while (i > 0) {
      sum += this.tree[i];
      i -= i & -i; // remove lowest set bit
    }
    return sum;
  }

  rangeSum(l: number, r: number): number {
    return l === 0 ? this.prefixSum(r) : this.prefixSum(r) - this.prefixSum(l - 1);
  }
}
```

**Interview problems:** Count of Smaller Numbers After Self, Range Sum Query (Mutable), Count Inversions.

---

## Bloom Filter

A Bloom filter is a space-efficient probabilistic data structure that tests whether an element is a member of a set. It can produce false positives ("maybe in set") but never false negatives ("definitely not in set"). Uses k hash functions mapping to a bit array of size m.

**False positive rate:** approximately (1 - e^(-kn/m))^k where n is the number of inserted elements.

```typescript
import { createHash } from "crypto";

class BloomFilter {
  private size: number;
  private numHashes: number;
  private bits: boolean[];

  constructor(size: number, numHashes: number) {
    this.size = size;
    this.numHashes = numHashes;
    this.bits = new Array(size).fill(false);
  }

  add(item: string): void {
    for (const i of this.hashIndices(item)) this.bits[i] = true;
  }

  possiblyContains(item: string): boolean {
    return this.hashIndices(item).every((i) => this.bits[i]);
  }

  private hashIndices(item: string): number[] {
    return Array.from({ length: this.numHashes }, (_, i) => {
      const hex = createHash("md5").update(`${i}:${item}`).digest("hex");
      return Number(BigInt("0x" + hex) % BigInt(this.size));
    });
  }
}
```

**Production uses:** Cassandra uses Bloom filters to avoid unnecessary disk reads. Chrome used one for malicious URL detection. Redis has built-in Bloom filter support via RedisBloom. Any "check before expensive lookup" scenario is a candidate.

**Interview context:** Bloom filters rarely appear as standalone coding problems but come up heavily in system design rounds. Know the trade-offs and be ready to suggest one when designing a system with expensive membership checks.

---

## Skip List

A skip list is a probabilistic alternative to balanced BSTs. It maintains multiple layers of linked lists where each higher layer skips over more elements, giving O(log n) expected search, insert, and delete. Redis uses skip lists for its sorted set implementation.

```mermaid
graph LR
    subgraph "Skip List"
        direction LR

        L3H["L3: Head"] --> L3_6["6"] --> L3T["∞"]
        L2H["L2: Head"] --> L2_3["3"] --> L2_6["6"] --> L2_9["9"] --> L2T["∞"]
        L1H["L1: Head"] --> L1_1["1"] --> L1_3["3"] --> L1_5["5"] --> L1_6["6"] --> L1_7["7"] --> L1_9["9"] --> L1T["∞"]
    end

    L3_6 -.-> L2_6
    L2_3 -.-> L1_3
    L2_6 -.-> L1_6
    L2_9 -.-> L1_9
```

**Why skip lists over balanced BSTs?** Simpler to implement, easier to reason about concurrently (no rotations), and range queries are trivial (just walk the bottom level). The trade-off is higher memory usage (average 2x pointers per node) and probabilistic rather than guaranteed O(log n).

**Interview context:** Skip lists are more of a system design discussion point than a coding problem. Know why Redis chose them over red-black trees (simplicity, concurrent access, range queries) and be ready to compare them.

---

## B-Trees / B+ Trees

B-trees are self-balancing search trees designed for disk-based storage. Each node holds multiple keys and has a high branching factor, minimizing disk I/O. B+ trees (the variant used in virtually all databases) store all values in leaf nodes, with internal nodes serving only as an index.

```mermaid
graph TD
    R["[17 | 35]"] --> C1["[3 | 8 | 12]"]
    R --> C2["[20 | 27]"]
    R --> C3["[38 | 45 | 52]"]

    C1 --> L1["1,2,3"]
    C1 --> L2["5,6,8"]
    C1 --> L3["10,12"]
    C2 --> L4["18,20"]
    C2 --> L5["22,25,27"]
    C3 --> L6["36,38"]
    C3 --> L7["40,42,45"]
    C3 --> L8["48,50,52"]

    L1 --- L2 --- L3 --- L4 --- L5 --- L6 --- L7 --- L8

    style R fill:#4a90d9,color:#fff
    style C1 fill:#7ab648,color:#fff
    style C2 fill:#7ab648,color:#fff
    style C3 fill:#7ab648,color:#fff
```

**Key properties:** A B-tree of order m has at most m children per node, at least ⌈m/2⌉ children (except root), and all leaves at the same depth. B+ trees add leaf-level linked list for efficient range scans — this is why `SELECT * WHERE id BETWEEN 100 AND 200` is fast in PostgreSQL.

**Interview context:** You won't implement a B-tree in a coding round. But in system design, you should know: why databases use B+ trees (disk I/O optimization, sequential access for range queries), how index lookups work (O(log_m n) disk reads), and when an index helps vs hurts (write amplification, space overhead).

---

## Complexity Cheat Sheet

| Structure | Search | Insert | Delete | Space | Notes |
|---|---|---|---|---|---|
| Union-Find | O(α(n)) | O(α(n)) | — | O(n) | α(n) ≈ O(1) in practice |
| Monotonic Stack | — | O(1) amort | O(1) amort | O(n) | Each element pushed/popped once |
| LRU Cache | O(1) | O(1) | O(1) | O(n) | Hash map + doubly linked list |
| Segment Tree | O(log n) query | O(log n) update | — | O(4n) | Range queries, point/range updates |
| Fenwick Tree | O(log n) prefix | O(log n) update | — | O(n) | Simpler than segment tree |
| Bloom Filter | O(k) | O(k) | — | O(m) bits | Probabilistic, no false negatives |
| Skip List | O(log n) exp | O(log n) exp | O(log n) exp | O(n) avg | Probabilistic balancing |
| B-Tree | O(log n) | O(log n) | O(log n) | O(n) | Optimized for disk I/O |

---

## Study Strategy

1. **Must-know for coding rounds:** Union-Find, Monotonic Stack/Queue, LRU Cache. These appear directly as interview problems. Implement each from memory.
2. **Must-know conceptually:** Segment Tree, Fenwick Tree, Bloom Filter. You should recognize when a problem calls for them and sketch the approach, even if you don't have every line memorized.
3. **System design ammo:** Skip Lists, B-Trees, Bloom Filters. These demonstrate depth in design discussions. Know the "why" behind each — what problem they solve that simpler structures don't.
4. **Practice pattern:** For each structure, solve 2-3 LeetCode problems. Focus on Union-Find and Monotonic Stack — they appear most often.

---

## Related Topics

- [[../01-data-structures-and-algorithms/index|Data Structures & Algorithms]] — foundational structures this builds on
- [[../09-dynamic-programming/index|Dynamic Programming]] — segment trees often optimize DP range queries
- [[../../system-design/01-databases-and-storage/index|Databases & Storage]] — B-trees, Bloom filters in production systems
