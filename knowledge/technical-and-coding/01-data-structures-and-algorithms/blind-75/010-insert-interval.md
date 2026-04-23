# 57. Insert Interval

- **Difficulty:** Medium
- **URL:** https://leetcode.com/problems/insert-interval/
- **Category:** Array, Intervals

## Problem

You are given an array of non-overlapping intervals `intervals` sorted by start time, and a `newInterval` to insert. Insert `newInterval` into `intervals` such that the result is still sorted and non-overlapping (merge if necessary). Return the resulting array.

**Example 1:**
- Input: `intervals = [[1,3],[6,9]], newInterval = [2,5]`
- Output: `[[1,5],[6,9]]`

**Example 2:**
- Input: `intervals = [[1,2],[3,5],[6,7],[8,10],[12,16]], newInterval = [4,8]`
- Output: `[[1,2],[3,10],[12,16]]`

**Constraints:**
- `0 <= intervals.length <= 10^4`
- `intervals[i].length == 2`
- `0 <= intervals[i][0] <= intervals[i][1] <= 10^5`
- `intervals` is sorted by start time and non-overlapping
- `newInterval.length == 2`

## Solution

**Approach:** Three-phase linear scan — collect intervals that end before the new one starts, merge all overlapping intervals into `newInterval`, then collect the rest.

**Overlap condition:** `intervals[i][0] <= newInterval[1]` — the existing interval starts before or at the new interval's end.

**Time:** O(n)
**Space:** O(n) — output array

```typescript
function insert(intervals: number[][], newInterval: number[]): number[][] {
  let i = 0;
  let result: number[][] = [];
  const n = intervals.length;

  // Phase 1: intervals that end before newInterval starts — no overlap
  while (i < n && intervals[i][1] < newInterval[0]) {
    result.push(intervals[i]);
    i++;
  }

  // Phase 2: merge all overlapping intervals into newInterval
  while (i < n && intervals[i][0] <= newInterval[1]) {
    newInterval[0] = Math.min(intervals[i][0], newInterval[0]);
    newInterval[1] = Math.max(intervals[i][1], newInterval[1]);
    i++;
  }
  result.push(newInterval);

  // Phase 3: intervals that start after newInterval ends — no overlap
  while (i < n) {
    result.push(intervals[i]);
    i++;
  }

  return result;
}
```

## Key Takeaways

- The three-phase structure maps cleanly to the three possible positions of an interval relative to the new one: before, overlapping, after
- Overlap detection: an existing interval overlaps `newInterval` if its **start** `<=` new interval's **end** (and since we already passed phase 1, its end is also >= new interval's start)
- Mutating `newInterval` in place during the merge phase is clean — expand its bounds as you consume each overlapping interval
- Edge cases handled naturally: empty `intervals`, `newInterval` before all, `newInterval` after all, total overlap
