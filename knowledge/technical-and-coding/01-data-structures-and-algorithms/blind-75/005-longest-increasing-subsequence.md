# 300. Longest Increasing Subsequence

- **Difficulty:** Medium
- **URL:** https://leetcode.com/problems/longest-increasing-subsequence/
- **Category:** Dynamic Programming, Binary Search

## Problem

Given an integer array `nums`, return the length of the longest strictly increasing subsequence.

**Example 1:**
- Input: `nums = [10,9,2,5,3,7,101,18]`
- Output: `4`
- Explanation: `[2,3,7,101]`

**Example 2:**
- Input: `nums = [0,1,0,3,2,3]`
- Output: `4`

**Example 3:**
- Input: `nums = [7,7,7,7,7,7,7]`
- Output: `1`

**Constraints:**
- `1 <= nums.length <= 2500`
- `-10^4 <= nums[i] <= 10^4`

## Solution (O(n^2) DP)

**Approach:** `dp[i]` = length of LIS ending at index `i`. For each element, look back at all previous elements — if `nums[i] > nums[j]`, we can extend that subsequence. Take the max. Every element is its own LIS of 1 as a base case.

**Time:** O(n^2)
**Space:** O(n)

```typescript
function lengthOfLIS(nums: number[]): number {
  let dp = new Array(nums.length).fill(1);

  for (let i = 0; i < nums.length; i++) {
    let results: number[] = [];
    for (let j = 0; j < i; j++) {
      if (nums[i] > nums[j]) {
        results.push(dp[j]);
      }
    }
    if (results.length > 0) {
      dp[i] = Math.max(...results) + 1;
    }
  }

  return Math.max(...dp);
}
```

## O(n log n) Approach (Patience Sorting — not yet implemented)

Maintain a `tails` array where `tails[i]` is the smallest tail element for an increasing subsequence of length `i+1`. For each element in `nums`:
- If it's larger than the last element in `tails`, append it (extends the longest subsequence)
- Otherwise, binary search `tails` for the first element >= current and replace it (keeps subsequences as "extendable" as possible)

The length of `tails` at the end is the LIS length. Note: `tails` is NOT the actual subsequence.

**Example walkthrough:** `[1, 6, 7, 3, 4, 5]`
- `1` → tails: `[1]`
- `6` → tails: `[1, 6]`
- `7` → tails: `[1, 6, 7]`
- `3` → replace 6 → tails: `[1, 3, 7]`
- `4` → replace 7 → tails: `[1, 3, 4]`
- `5` → append → tails: `[1, 3, 4, 5]`
- Answer: `4`

## Key Takeaways

- The O(n^2) solution is intuitive — "for each element, what's the best LIS I can extend?"
- The answer is `Math.max(...dp)`, not `dp[n-1]` — the LIS doesn't have to end at the last element
- The O(n log n) patience sorting approach is tricky to derive in an interview but worth knowing — binary search on `tails` keeps it sorted
- Follow-up: to reconstruct the actual subsequence, track parent pointers alongside the DP
