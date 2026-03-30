# Testing a Payment Service -- Exercise

## Setup

You are given `payment_service.rb`, a Ruby payment processing service that handles charges, refunds, webhook processing, and retry logic. The service integrates with an external payment gateway (Stripe-like API) and a database.

Your task is to write a comprehensive test suite for this service. The file `payment_service_spec.rb` contains stubs and hints for the tests you need to write.

## Your task (50 minutes)

1. **Read the service code** (10 min): understand the public API, error paths, and edge cases
2. **Write the test suite** (35 min): implement all the test cases in `payment_service_spec.rb`
3. **Identify untestable code** (5 min): note any parts of the service that are hard to test and propose refactoring

### What to test

- Happy paths: successful charge, successful refund
- Error paths: gateway errors, network timeouts, invalid input
- Retry logic: verify backoff behavior, max retry limits
- Idempotency: same idempotency key should not charge twice
- Webhook processing: valid signature, invalid signature, duplicate events
- State transitions: charge -> refund, charge -> already refunded
- Concurrency: what happens with two simultaneous charges for the same order?

### What you should mock

- The external payment gateway (HTTP calls)
- The database (or use an in-memory store)
- Time (for retry backoff and token expiry)
- Logging (verify log messages for observability)

### What you should NOT mock

- The PaymentService itself (that is what you are testing)
- Ruby standard library (unless specifically testing time or randomness)

## Evaluation Criteria (Staff Level)

- **Coverage of edge cases**: do you test boundaries, nil inputs, concurrent access?
- **Test isolation**: are tests independent? Can they run in any order?
- **Mocking discipline**: do you mock at the right boundaries? Not over-mocking?
- **Assertion quality**: do you test behavior (outputs) or implementation (internals)?
- **Readability**: is each test self-documenting? Clear arrange-act-assert?

## Scoring

| Score | Description |
|---|---|
| Strong hire | 20+ well-structured tests covering all categories, identifies design issues |
| Hire | 15-19 tests, covers happy and error paths, reasonable mocking |
| Lean hire | 10-14 tests, misses some edge cases or over-mocks |
| No hire | <10 tests or tests that verify implementation instead of behavior |

When done, check `ANSWER_KEY.md` for the reference test suite and discussion.
