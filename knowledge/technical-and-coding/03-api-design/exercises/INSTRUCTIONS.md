# Buggy API Code Review Exercise

## Setup

You are reviewing `product_api.rb` -- a Sinatra-based REST API for an e-commerce product catalog. The API handles product CRUD, search, authentication, rate limiting, and pagination. A mid-level engineer submitted this for code review before deployment.

## Your task (50 minutes)

1. **Read through the code** and identify bugs, security vulnerabilities, API design mistakes, and performance issues
2. **Categorize each issue**: bug, security, API design, performance, error handling, missing feature
3. **Prioritize**: P0 (blocks deployment), P1 (causes issues in production), P2 (maintainability/best practice)
4. **Propose fixes**: describe or write the fix for each issue
5. **API design critique**: beyond bugs, what would you change about the API contract itself?

## Evaluation Criteria (Staff Level)

- Do you catch security vulnerabilities (SQL injection, auth bypass, IDOR)?
- Do you identify API design anti-patterns (wrong status codes, inconsistent responses)?
- Can you reason about pagination edge cases?
- Do you consider backward compatibility and versioning?
- Do you think about the API from the consumer's perspective?

## Scoring

There are **35+ intentional issues** across security, design, and implementation.

| Score | Description |
|---|---|
| Strong hire | 28+ issues found, proposes concrete API redesign |
| Hire | 20-27 issues, catches all security issues |
| Lean hire | 14-19 issues, misses some subtle design problems |
| No hire | <14 issues or misses critical security vulnerabilities |

When done, check `ANSWER_KEY.md`.
