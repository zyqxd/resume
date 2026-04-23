# 1. Two Sum

- **Difficulty:** Easy
- **URL:** https://leetcode.com/problems/two-sum/
- **Category:** Array, Hash Table

## Problem

Given an array of integers `nums` and an integer `target`, return indices of the two numbers such that they add up to `target`.

You may assume that each input has exactly one solution, and you may not use the same element twice. You can return the answer in any order.

**Example 1:**
- Input: `nums = [2,7,11,15], target = 9`
- Output: `[0,1]`
- Explanation: `nums[0] + nums[1] = 2 + 7 = 9`

**Example 2:**
- Input: `nums = [3,2,4], target = 6`
- Output: `[1,2]`

**Example 3:**
- Input: `nums = [3,3], target = 6`
- Output: `[0,1]`

**Constraints:**
- `2 <= nums.length <= 10^4`
- `-10^9 <= nums[i] <= 10^9`
- `-10^9 <= target <= 10^9`
- Only one valid answer exists.

## Solution

**Approach:** Hash map lookup — for each number, check if `target - num` already exists in the map. If so, return both indices. Otherwise, store the current number and its index.

**Time:** O(n) — single pass  
**Space:** O(n) — hash map storage

```typescript
function twoSum(nums: number[], target: number): number[] {
  if (nums.length == 2) return [0, 1];

  let hash: Record<string, number> = {};

  for (let i = 0; i < nums.length; i++) {
    let num = nums[i];
    let remainder = target - num;

    if (typeof hash[String(remainder)] !== "undefined") {
      return [i, hash[target - num]];
    } else {
      hash[String(num)] = i;
    }
  }
}
```

## Key Takeaways

- Classic "complement lookup" pattern — whenever you need to find pairs that satisfy a condition, think hash map
- Single-pass is possible because by the time you find a match, the earlier element is already stored
- Early return for length-2 input is a nice micro-optimization
