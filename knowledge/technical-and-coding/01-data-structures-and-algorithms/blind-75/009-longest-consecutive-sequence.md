# 128. Longest Consecutive Sequence

- **Difficulty:** Medium
- **URL:** https://leetcode.com/problems/longest-consecutive-sequence/
- **Category:** Array, Hash Map, Union Find

## Problem

Given an unsorted array of integers `nums`, return the length of the longest consecutive elements sequence. Must run in O(n) time.

**Example 1:**
- Input: `nums = [100,4,200,1,3,2]`
- Output: `4`
- Explanation: `[1,2,3,4]`

**Example 2:**
- Input: `nums = [0,3,7,2,5,8,4,6,0,1]`
- Output: `9`

**Constraints:**
- `0 <= nums.length <= 10^5`
- `-10^9 <= nums[i] <= 10^9`

## Solution

**Approach:** Union Find (Disjoint Set Union). Each number starts as its own group. For each `num`, if `num+1` exists, union them into the same group. Track group sizes — the max size is the answer.

Two optimizations keep the tree flat and operations near O(1):
- **Union by size:** always attach the smaller group under the larger
- **Path compression:** during `find`, flatten the path by pointing each node directly to its grandparent (`parents[num] = parents[parents[num]]`)

**Time:** O(n · α(n)) ≈ O(n) — α is the inverse Ackermann function, effectively constant
**Space:** O(n)

```typescript
function longestConsecutive(nums: number[]): number {
  if (nums.length == 0) return 0;

  const parents: Map<number, number> = new Map();
  nums.forEach((num) => parents.set(num, num));

  // Follow parents until we reach the group leader (key == value)
  const find = (num: number): number => {
    while (parents.get(num) !== num) {
      // Path compression: point to grandparent to flatten the tree
      parents.set(num, parents.get(parents.get(num)!));
      num = parents.get(num)!;
    }
    return num;
  };

  const size: Map<number, number> = new Map();
  nums.forEach((num) => size.set(num, 1));

  const union = (a: number, b: number) => {
    const groupA = find(a);
    const groupB = find(b);
    if (groupA === groupB) return; // already in same group

    // Union by size: attach smaller group under larger
    if (size.get(groupA)! > size.get(groupB)!) {
      size.set(groupA, size.get(groupA)! + size.get(groupB)!);
      parents.set(groupB, groupA);
    } else {
      size.set(groupB, size.get(groupB)! + size.get(groupA)!);
      parents.set(groupA, groupB);
    }
  };

  for (const num of nums) {
    if (parents.has(num + 1)) {
      union(num, num + 1);
    }
  }

  return Math.max(...size.values());
}
```

## Alternative: Hash Set O(n)

Simpler to implement — put all numbers in a set. For each number that has no left neighbor (`num-1` not in set), walk right counting the streak.

```typescript
function longestConsecutive(nums: number[]): number {
  const set = new Set(nums);
  let best = 0;

  for (const num of set) {
    if (!set.has(num - 1)) { // only start counting from sequence heads
      let len = 1;
      while (set.has(num + len)) len++;
      best = Math.max(best, len);
    }
  }

  return best;
}
```

## Key Takeaways

- **Union Find** is the advanced solution — great for streaming/incremental data where you also need to check `num-1` (you don't know where you are in the sequence yet)
- **Hash Set** is simpler and also O(n) — only start a count from sequence heads (no left neighbor)
- Union Find building blocks: `parents` map (group identity) + `size` map (group weight) + path compression in `find`
- `Math.max([])` returns `-Infinity`, not `0` — handle the empty input case explicitly
