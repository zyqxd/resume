# 347. Top K Frequent Elements

- **Difficulty:** Medium
- **URL:** https://leetcode.com/problems/top-k-frequent-elements/
- **Category:** Array, Hash Map, Heap

## Problem

Given an integer array `nums` and an integer `k`, return the `k` most frequent elements. You may return the answer in any order.

**Example 1:**
- Input: `nums = [1,1,1,2,2,3], k = 2`
- Output: `[1,2]`

**Example 2:**
- Input: `nums = [1], k = 1`
- Output: `[1]`

**Constraints:**
- `1 <= nums.length <= 10^5`
- `-10^4 <= nums[i] <= 10^4`
- `k` is in the range `[1, number of unique elements]`
- The answer is guaranteed to be unique

## Solution

**Approach:** Frequency map + max-heap. Count frequencies in O(n), push all unique elements into a max-heap keyed by count, then pop k times.

Includes a full generic `MaxHeap` implementation using an array — useful to know cold.

**Time:** O(n + m log m) where m = number of unique elements (heap build) + O(k log m) for k pops
**Space:** O(m) for heap + frequency map

```typescript
class NumCount {
  public num: number;
  public count: number;

  constructor(num: number, count: number) {
    this.num = num;
    this.count = count;
  }

  toString(): string {
    return `${this.num}: ${this.count}`;
  }
}

class MaxHeap<T> {
  public data: T[] = [];
  private compare: (a: T, b: T) => number;

  constructor(compareFn: (a: T, b: T) => number) {
    this.compare = compareFn;
  }

  push(val: T) {
    this.data.push(val);

    // Bubble up
    let i = this.size() - 1;
    while (i > 0) {
      const parent = Math.floor((i - 1) / 2);
      if (this.compare(this.data[parent], this.data[i]) >= 0) break;
      [this.data[parent], this.data[i]] = [this.data[i], this.data[parent]];
      i = parent;
    }
  }

  pop(): T | undefined {
    if (this.size() === 0) return undefined;
    if (this.size() === 1) return this.data.pop();

    // Swap root with last, pop last, bubble down
    [this.data[0], this.data[this.size() - 1]] = [
      this.data[this.size() - 1],
      this.data[0],
    ];
    const popped = this.data.pop();

    let i = 0;
    while (i < this.size()) {
      const left = i * 2 + 1;
      const right = i * 2 + 2;
      let largest = i;

      if (
        left < this.size() &&
        this.compare(this.data[left], this.data[largest]) > 0
      ) {
        largest = left;
      }
      if (
        right < this.size() &&
        this.compare(this.data[right], this.data[largest]) > 0
      ) {
        largest = right;
      }

      if (largest === i) break;
      [this.data[i], this.data[largest]] = [this.data[largest], this.data[i]];
      i = largest;
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

function topKFrequent(nums: number[], k: number): number[] {
  // Tally frequencies O(n)
  const freqMap = new Map<number, number>();
  nums.forEach((num) => freqMap.set(num, (freqMap.get(num) || 0) + 1));

  // Push all into max-heap by count O(m log m)
  const maxHeap = new MaxHeap<NumCount>(
    (a, b) => a.count - b.count
  );
  freqMap.forEach((count, num) => maxHeap.push(new NumCount(num, count)));

  // Pop k times O(k log m)
  const results: number[] = [];
  for (let i = 0; i < k; i++) {
    results.push(maxHeap.pop()!.num);
  }
  return results;
}
```

## MaxHeap Array Layout

```
Index:     0    1    2    3    4    5    6
           [root] [L]  [R]  [LL] [LR] [RL] [RR]

Parent of i:      floor((i-1) / 2)
Left child of i:  2i + 1
Right child of i: 2i + 2
```

## Key Takeaways

- **Max-heap** gives you the top-k in O(n + m log m). A **min-heap of size k** gives the same result in O(n + m log k) — better when k << m, since you maintain only k elements and pop the min when size exceeds k
- The comparator convention: positive return = first arg wins (goes higher in max-heap), matching `Array.sort`'s convention
- **Bubble up** on push (new element at end, swap with parent while larger). **Bubble down** on pop (root removed, last element moved to root, swap with largest child while smaller)
- Alternative O(n) approach: bucket sort by frequency — create buckets indexed by count, fill from freq map, read top-k from the end
