# 56. Merge Intervals

- **Difficulty:** Medium
- **URL:** https://leetcode.com/problems/merge-intervals/
- **Category:** Array, Intervals, Sorting

## Problem

Given an array of intervals, merge all overlapping intervals and return an array of the non-overlapping intervals that cover all the intervals in the input.

**Example 1:**
- Input: `intervals = [[1,3],[2,6],[8,10],[15,18]]`
- Output: `[[1,6],[8,10],[15,18]]`

**Example 2:**
- Input: `intervals = [[1,4],[4,5]]`
- Output: `[[1,5]]`
- Explanation: Intervals touching at a boundary are considered overlapping

**Constraints:**
- `1 <= intervals.length <= 10^4`
- `intervals[i].length == 2`
- `0 <= intervals[i][0] <= intervals[i][1] <= 10^4`

## Solution

**Approach:** Sort by start time, then do a single pass — compare each interval against the last merged result. If they overlap, expand the last interval's end. If not, push as a new interval.

**Overlap condition:** `lastInterval[1] >= currInterval[0]` — sorted order guarantees starts are already ordered, so only the ends need checking.

**Time:** O(n log n) — dominated by sort
**Space:** O(n) — output array

```typescript
function merge(intervals: number[][]): number[][] {
  // Sort by start time
  const ascIntervals = intervals.sort((a, b) => a[0] - b[0]);

  const results = [ascIntervals.shift()!];

  for (let i = 0; i < ascIntervals.length; i++) {
    const lastInterval = results.at(-1)!;
    const currInterval = ascIntervals[i];

    if (lastInterval[1] < currInterval[0]) {
      // No overlap — push as new interval
      results.push(currInterval);
    } else {
      // Overlap — merge by expanding the last interval's end
      results.pop();
      results.push([
        Math.min(lastInterval[0], currInterval[0]),
        Math.max(lastInterval[1], currInterval[1]),
      ]);
    }
  }

  return results;
}
```

## Key Takeaways

- Sort first — this is the key move that makes a single O(n) pass possible
- After sorting, you only ever need to compare against the **last** interval in results (not all previous ones)
- `Math.min` on the start is technically redundant after sorting (current start >= last start), but harmless and makes the merge logic symmetric
- Compare with Insert Interval (no. 57): that problem skips sorting because intervals are pre-sorted and you're inserting one interval — the three-phase approach is cleaner there. Here you must sort first.
- Touching intervals `[1,4],[4,5]` — `4 < 4` is false, so they merge correctly with `<` (strict less than for no-overlap check)
