# 322. Coin Change

- **Difficulty:** Medium
- **URL:** https://leetcode.com/problems/coin-change/
- **Category:** Dynamic Programming

## Problem

You are given an integer array `coins` representing coins of different denominations and an integer `amount` representing a total amount of money. Return the fewest number of coins needed to make up that amount. If that amount cannot be made up by any combination of the coins, return `-1`.

You may assume that you have an infinite number of each kind of coin.

**Example 1:**
- Input: `coins = [1,5,10,25], amount = 49`
- Output: `7`
- Explanation: `25 + 10 + 10 + 1 + 1 + 1 + 1 = 49`

**Example 2:**
- Input: `coins = [2], amount = 3`
- Output: `-1`

**Example 3:**
- Input: `coins = [1], amount = 0`
- Output: `0`

**Constraints:**
- `1 <= coins.length <= 12`
- `1 <= coins[i] <= 2^31 - 1`
- `0 <= amount <= 10^4`

## Solution

**Approach:** Bottom-up DP. `dp[i]` = minimum coins to make amount `i`. For each amount, try every coin and take the minimum. The key insight: the recursive helper has 1 argument (amount), so the DP table is a single-dimensional array.

**Time:** O(amount * coins.length)
**Space:** O(amount)

```typescript
function coinChange(coins: number[], amount: number): number {
  let dp = new Array(amount + 1).fill(Infinity);

  dp[0] = 0;
  for (let i = 1; i <= amount; i++) {
    for (let j = 0; j < coins.length; j++) {
      if (i - coins[j] >= 0) {
        dp[i] = Math.min(dp[i], 1 + dp[i - coins[j]]);
      }
    }
  }

  return dp[amount] === Infinity ? -1 : dp[amount];
}
```

### Recursive version (top-down, no memo — TLE)

```typescript
function coinChange(coins: number[], amount: number): number {
  function helper(coins: number[], amount: number): number {
    if (amount === 0) {
      return 0;
    } else if (amount < 0) {
      return Infinity;
    } else {
      let counts = coins.map((coin) => helper(coins, amount - coin));
      return 1 + Math.min(...counts);
    }
  }

  let result = helper(coins, amount);
  return result === Infinity ? -1 : result;
}
```

## Key Takeaways

- Great example of converting top-down recursion to bottom-up DP — the number of recursive arguments tells you the DP table dimensions (1 arg = 1D array)
- `Infinity` as the initial fill is clean — it naturally propagates "unreachable" states and works with `Math.min`
- Greedy (always pick largest coin) does NOT work here — e.g. `coins = [1,3,4], amount = 6` → greedy gives `4+1+1=3 coins`, optimal is `3+3=2 coins`
- Bottom-up avoids stack overflow risk on large amounts
