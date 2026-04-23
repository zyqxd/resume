# 70. Climbing Stairs

- **Difficulty:** Easy
- **URL:** https://leetcode.com/problems/climbing-stairs/
- **Category:** Dynamic Programming

## Problem

You are climbing a staircase. It takes `n` steps to reach the top. Each time you can either climb 1 or 2 steps. In how many distinct ways can you climb to the top?

**Example 1:**
- Input: `n = 2`
- Output: `2`
- Explanation: `1 + 1` or `2`

**Example 2:**
- Input: `n = 3`
- Output: `3`
- Explanation: `1 + 1 + 1`, `1 + 2`, or `2 + 1`

**Constraints:**
- `1 <= n <= 45`

## Solution

**Approach:** Top-down DP (memoized recursion). The number of ways to reach step `n` is the sum of ways to reach `n-1` (take 1 step) and `n-2` (take 2 steps). This is the Fibonacci recurrence — memoize to avoid recomputation.

**Time:** O(n) — each subproblem computed once
**Space:** O(n) — memo table + call stack

```typescript
let memory: Record<number, number> = {
  1: 1,
  2: 2,
};

function climbStairs(n: number): number {
  if (typeof memory[n] !== "undefined") {
    return memory[n];
  } else {
    let compute = climbStairs(n - 1) + climbStairs(n - 2);
    memory[n] = compute;
    return compute;
  }
}
```

## Key Takeaways

- This is literally Fibonacci — `f(n) = f(n-1) + f(n-2)` with base cases `f(1)=1, f(2)=2`
- Top-down memo vs bottom-up iterative is a style choice here; both are O(n) time
- Could optimize to O(1) space with bottom-up using just two variables, but memo is clearer
- Classic DP gateway problem — if you see "how many ways", think DP immediately
