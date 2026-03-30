# Live Auction Code Review Exercise

## Setup

You are reviewing `app.js` — a vanilla JavaScript module for eBay Live's
real-time auction system. A junior engineer submitted this for code review.

## Your task (50 minutes)

1. **Read through the code** and identify as many issues as you can
2. **Categorize each issue**: bug, security, performance, memory leak, maintainability, missing error handling
3. **Prioritize**: which issues are P0 ship-blockers vs nice-to-haves?
4. **Propose fixes**: describe or write the fix for each issue
5. **System-level suggestions**: what architectural improvements would you recommend?

## Evaluation criteria (staff-level)

- Can you find issues across ALL categories, not just syntax bugs?
- Do you explain WHY each issue matters (impact, failure scenario)?
- Can you articulate trade-offs in your proposed fixes?
- Do you think about scale (10k concurrent users, 1000 auctions)?

## Scoring

There are **35 intentional issues** embedded in the code, including
WebSocket-specific bugs in the ConnectionMonitor and LiveStreamSync modules.
A strong staff-level candidate should find 25+ and articulate the impact of each.

When you're done, check the answer key in `ANSWER_KEY.md`.
