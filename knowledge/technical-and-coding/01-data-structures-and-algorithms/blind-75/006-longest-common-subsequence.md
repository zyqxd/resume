# 1143. Longest Common Subsequence

- **Difficulty:** Medium
- **URL:** https://leetcode.com/problems/longest-common-subsequence/
- **Category:** Dynamic Programming (2D)

## Problem

Given two strings `text1` and `text2`, return the length of their longest common subsequence. If there is no common subsequence, return `0`.

A subsequence is a sequence that can be derived from another sequence by deleting some or no elements without changing the order of the remaining elements.

**Example 1:**
- Input: `text1 = "abcde", text2 = "ace"`
- Output: `3`
- Explanation: `"ace"` is the longest common subsequence

**Example 2:**
- Input: `text1 = "abc", text2 = "abc"`
- Output: `3`

**Example 3:**
- Input: `text1 = "abc", text2 = "def"`
- Output: `0`

**Constraints:**
- `1 <= text1.length, text2.length <= 1000`
- `text1` and `text2` consist of only lowercase English characters

## Solution

**Approach:** Bottom-up 2D DP. `dp[i][j]` = LCS of `text1[0..i]` and `text2[0..j]`. If characters match, extend the diagonal (`1 + dp[i-1][j-1]`). If they don't, take the best from dropping either character (`max(dp[i-1][j], dp[i][j-1])`).

**Time:** O(m * n)
**Space:** O(m * n)

```typescript
function longestCommonSubsequence(text1: string, text2: string): number {
  let dp = Array.from({ length: text1.length }, () =>
    Array(text2.length).fill(0)
  );

  for (let i = 0; i < text1.length; i++) {
    for (let j = 0; j < text2.length; j++) {
      if (text1[i] == text2[j]) {
        if (i == 0 || j == 0) {
          dp[i][j] = 1;
        } else {
          dp[i][j] = 1 + dp[i - 1][j - 1];
        }
      } else {
        dp[i][j] = Math.max(
          i > 0 ? dp[i - 1][j] : 0,
          j > 0 ? dp[i][j - 1] : 0
        );
      }
    }
  }

  return dp[text1.length - 1][text2.length - 1];
}
```

## Key Takeaways

- **Two-string DP pattern:** when two things must be "used together" (matching a character from both strings), the subproblem shrinks both dimensions. When skipping one element, only that dimension shrinks. This same pattern appears in edit distance, string interleaving, and other two-string DP problems.
- The recurrence:
  - Match: `1 + dp[i-1][j-1]` (consume from both strings)
  - No match: `max(dp[i-1][j], dp[i][j-1])` (skip one or the other)
- Boundary handling: using 0-indexed DP requires the `i == 0 || j == 0` guard. Alternative: use a `(m+1) x (n+1)` table with a padding row/column of zeros to avoid the edge cases entirely.
- Can optimize space to O(min(m,n)) since each row only depends on the current and previous row
