# E-Commerce Order System -- Code Review & Design Exercise

## Setup

You are reviewing `order_system.rb` -- an e-commerce order processing system written by a mid-level engineer. The system handles products, shopping carts, orders, payments, and fulfillment.

## Your task (55 minutes)

### Part 1: Code Review (30 minutes)

1. **Read through the code** and identify bugs, SOLID violations, design pattern misuse, and missed opportunities for better abstractions
2. **Categorize each issue**: bug, SOLID violation (specify which principle), design flaw, missing feature, performance
3. **Prioritize**: P0 (blocks shipping), P1 (causes data issues), P2 (code smell / maintainability)
4. **Propose fixes**: describe or write the fix

### Part 2: Design Extension (25 minutes)

After reviewing, extend the system to support:

1. **Subscription orders** (recurring monthly charges)
2. **Gift cards** as a payment method
3. **Split payments** (part credit card, part gift card)

For each extension, describe which classes change, which new classes you would add, and where the extension points are. Write key method signatures and class outlines.

## Evaluation Criteria (Staff Level)

- Do you catch SOLID violations, not just syntax bugs?
- Can you articulate WHY a design choice is problematic (not just WHAT is wrong)?
- Are your proposed fixes idiomatic Ruby?
- Do your extensions maintain the open/closed principle?
- Do you think about edge cases: partial refunds, failed payments, inventory races?

## Scoring

There are **28+ intentional issues** across bugs, SOLID violations, and design flaws.

| Score | Description |
|---|---|
| Strong hire | 22+ issues found, clean extension design, articulates trade-offs |
| Hire | 16-21 issues, reasonable extensions with minor gaps |
| Lean hire | 10-15 issues, extension design has coupling problems |
| No hire | <10 issues or extensions violate principles they should have caught |

When done, check `ANSWER_KEY.md`.
