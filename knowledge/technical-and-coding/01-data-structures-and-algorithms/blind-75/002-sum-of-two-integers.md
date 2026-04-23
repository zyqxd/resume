# 371. Sum of Two Integers

- **Difficulty:** Medium
- **URL:** https://leetcode.com/problems/sum-of-two-integers/
- **Category:** Bit Manipulation

## Problem

Given two integers `a` and `b`, return the sum of the two integers without using the operators `+` and `-`.

**Example 1:**
- Input: `a = 1, b = 2`
- Output: `3`

**Example 2:**
- Input: `a = 2, b = 3`
- Output: `5`

**Constraints:**
- `-1000 <= a, b <= 1000`

## Solution

**Approach:** Simulate binary addition using bitwise operators. XOR gives the sum without carries, AND gives the carry bits, left shift positions the carry for the next addition. Repeat until there are no more carries.

**Time:** O(1) — bounded by integer bit width (32 iterations max)
**Space:** O(1)

```typescript
function getSum(a: number, b: number): number {
  while (b != 0) {
    let carry = a & b;   // bits where both are 1 → produces a carry
    a = a ^ b;           // sum without carries (XOR)
    b = carry << 1;      // shift carry left to add in next iteration
  }
  return a;
}
```

## Key Takeaways

- This is how addition works at the hardware level — a half-adder circuit
- XOR = addition without carry, AND = carry detection, left shift = carry propagation
- The loop terminates because each iteration pushes carry bits left until they overflow out
- Works for negative numbers too since JS uses 32-bit two's complement for bitwise ops
