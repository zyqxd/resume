# Concurrent Job Processor Exercise

## Setup

You are reviewing and debugging `job_processor.rb` -- a concurrent job processing system written in Ruby. A mid-level engineer submitted this for code review. The system is supposed to handle a multi-threaded worker pool with a priority queue, job retries, graceful shutdown, and metrics collection.

## Your task (50 minutes)

1. **Read through the code** and identify as many concurrency bugs, race conditions, deadlocks, and design issues as you can
2. **Categorize each issue**: race condition, deadlock, memory safety, performance, design flaw, missing error handling
3. **Prioritize**: which issues would cause data corruption or crashes in production vs. are nice-to-haves?
4. **Propose fixes**: describe or write the fix for each issue
5. **Architectural suggestions**: what would you change about the overall design?

## Evaluation criteria (staff-level)

- Can you identify subtle race conditions that would only manifest under load?
- Do you understand the interaction between Ruby's GVL and the bugs present?
- Can you reason about ordering guarantees and memory visibility?
- Do you consider edge cases like shutdown during processing, retry storms, and queue starvation?

## Scoring

There are **30+ intentional issues** embedded in the code across race conditions, deadlocks, resource leaks, and design flaws.

| Score | Found | Notes |
|---|---|---|
| Strong hire | 25+ | Identifies subtle timing issues, proposes architectural fixes |
| Hire | 18-24 | Catches most race conditions and deadlocks |
| Lean hire | 12-17 | Gets the obvious bugs but misses subtle timing issues |
| No hire | <12 | Misses fundamental concurrency issues |

When done, check `ANSWER_KEY.md` for the full list.
