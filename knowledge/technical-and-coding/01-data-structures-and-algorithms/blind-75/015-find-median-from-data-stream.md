# 295. Find Median from Data Stream

- **Difficulty:** Hard
- **URL:** https://leetcode.com/problems/find-median-from-data-stream/
- **Category:** Heap, Design, Two Heaps

## Problem

Design a data structure that supports:
- `addNum(num)` — add an integer to the data structure
- `findMedian()` — return the median of all elements so far

**Example:**
```
MedianFinder mf = new MedianFinder()
mf.addNum(1)   // [1]
mf.addNum(2)   // [1, 2]
mf.findMedian() // 1.5
mf.addNum(3)   // [1, 2, 3]
mf.findMedian() // 2.0
```

**Constraints:**
- `-10^5 <= num <= 10^5`
- At most `5 * 10^4` calls to `addNum` and `findMedian`
- At least one element before `findMedian` is called

## Solution

**Approach:** Two heaps. A **max-heap** holds the lower half, a **min-heap** holds the upper half. The median is always at the tops of these heaps. After each insert, rebalance so sizes differ by at most 1.

```
lower half  │  upper half
 max-heap   │   min-heap
[... 3, 4]  │  [5, 6, ...]
         ↑  │  ↑
       max  │  min  ← median lives here
```

**addNum:** O(log n) — one heap push + possibly one pop+push to rebalance  
**findMedian:** O(1) — peek both heap tops

```typescript
class MedianFinder {
  private minHeap = new Heap<number>((a, b) => a - b); // upper half
  private maxHeap = new Heap<number>((a, b) => b - a); // lower half

  addNum(num: number): void {
    // Bootstrap: always start in minHeap
    if (this.minHeap.size() === 0 && this.maxHeap.size() === 0) {
      this.minHeap.push(num);
      return;
    }

    const maxPeek = this.maxHeap.peek() ?? -Infinity;

    if (num <= maxPeek) {
      this.maxHeap.push(num); // belongs in lower half
    } else {
      this.minHeap.push(num); // belongs in upper half
    }

    // Rebalance: sizes must stay within 1
    if (this.minHeap.size() > this.maxHeap.size() + 1) {
      this.maxHeap.push(this.minHeap.pop()!);
    } else if (this.maxHeap.size() > this.minHeap.size() + 1) {
      this.minHeap.push(this.maxHeap.pop()!);
    }
  }

  findMedian(): number {
    const minPeek = this.minHeap.peek() ?? 0;
    const maxPeek = this.maxHeap.peek() ?? 0;

    if (this.minHeap.size() === this.maxHeap.size()) {
      return (minPeek + maxPeek) / 2;
    } else if (this.minHeap.size() > this.maxHeap.size()) {
      return minPeek;
    } else {
      return maxPeek;
    }
  }
}

// Generic heap — compareFn(a, b) < 0 means a has higher priority
class Heap<T> {
  private data: T[] = [];
  private compareFn: (a: T, b: T) => number;

  constructor(compareFn: (a: T, b: T) => number) {
    this.compareFn = compareFn;
  }

  push(val: T) {
    this.data.push(val);

    let i = this.size() - 1;
    while (i > 0) {
      const parent = Math.floor((i - 1) / 2);
      if (this.compareFn(this.data[parent], this.data[i]) <= 0) break;
      [this.data[parent], this.data[i]] = [this.data[i], this.data[parent]];
      i = parent;
    }
  }

  pop(): T | undefined {
    if (this.size() === 0) return undefined;
    if (this.size() === 1) return this.data.pop();

    [this.data[0], this.data[this.size() - 1]] = [
      this.data[this.size() - 1],
      this.data[0],
    ];
    const popped = this.data.pop();

    let i = 0;
    while (i < this.size()) {
      const left = i * 2 + 1;
      const right = i * 2 + 2;
      let swap = i;

      if (left < this.size() && this.compareFn(this.data[swap], this.data[left]) > 0) {
        swap = left;
      }
      if (right < this.size() && this.compareFn(this.data[swap], this.data[right]) > 0) {
        swap = right;
      }

      if (swap === i) break;
      [this.data[swap], this.data[i]] = [this.data[i], this.data[swap]];
      i = swap;
    }

    return popped;
  }

  peek(): T | undefined {
    return this.data[0];
  }

  size(): number {
    return this.data.length;
  }
}
```

## Key Takeaways

- **Two heaps** is the canonical median-from-stream pattern — lower half in max-heap, upper half in min-heap, always rebalance to within 1
- Comparator convention for this `Heap` class: `compareFn(a, b) < 0` means `a` wins (has higher priority)
  - Min-heap: `(a, b) => a - b` (smaller values win)
  - Max-heap: `(a, b) => b - a` (larger values win)
- The rebalance invariant: `|minSize - maxSize| <= 1`. When equal sizes, median = average of both tops. When unequal, median = top of the larger heap.
- Routing logic: if `num <= maxHeap.peek()`, it belongs in the lower half. Otherwise upper half. Rebalance handles any size violations.
