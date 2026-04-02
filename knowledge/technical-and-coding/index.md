# Technical & Coding Interview Prep

The technical interview landscape has shifted significantly in the post-AI era (2025-2026). While data structures and algorithms remain the foundation at every major company (including AI-native companies like Anthropic and OpenAI), the emphasis has moved from rote algorithmic cleverness toward reasoning under constraints, real-world system thinking, and AI-augmented problem solving. Meta now pilots AI-enabled coding rounds where candidates use an AI assistant in CoderPad. Google has returned to in-person interviews with broader scope. Nearly half of hiring managers prefer real-world coding tasks over abstract puzzles. For staff-level roles, the bar continues to rise: you are expected to demonstrate architectural fluency, articulate trade-offs, and operate across the full stack of concerns from concurrency to API design to AI integration.

This knowledge bank is organized into nine core topic areas. Each contains a primer with key concepts and at least one hands-on exercise following the code-review or implementation format.

---

## Topics

### 1. [[01-data-structures-and-algorithms/index|Data Structures & Algorithms]] `core` `high-frequency`

The evergreen foundation. Every company still tests DSA regardless of their stance on AI in interviews. The key shift: interviewers care less about whether you memorized Dijkstra's and more about whether you can recognize patterns (sliding window, two pointers, BFS/DFS, dynamic programming) and reason about trade-offs in time/space complexity. Covers arrays, hash maps, trees, graphs, heaps, tries, and the major algorithmic patterns.

### 2. [[02-object-oriented-design/index|Object-Oriented Design]] `core` `medium-frequency`

SOLID principles, Gang of Four patterns (strategy, observer, factory, decorator), and modeling real-world systems. Staff-level interviews often include a 45-60 minute OOD round where you design a system like a parking lot, elevator, or card game from scratch. The emphasis is on clean abstractions, extensibility, and demonstrating that you think about maintenance and change over time.

### 3. [[03-api-design/index|API Design]] `core` `high-frequency`

REST best practices, GraphQL trade-offs, versioning strategies, pagination, rate limiting, and idempotency. Backend-heavy roles almost always include an API design component, either as a standalone round or embedded in system design. Includes a code review exercise with a buggy Ruby API covering authentication, error handling, and resource modeling.

### 4. [[04-concurrency-and-parallelism/index|Concurrency & Parallelism]] `core` `staff-level`

Critical for staff-level backend roles. Covers threads, mutexes, race conditions, deadlocks, and async patterns. Includes Ruby-specific concurrency: the GIL (GVL), Ractors, Fibers, and how to achieve true parallelism in MRI vs JRuby. Understanding concurrency primitives and being able to reason about thread safety separates senior from staff candidates.

### 5. [[05-testing-and-quality/index|Testing & Quality]] `core` `medium-frequency`

Unit vs integration vs e2e testing, TDD workflow, mocking strategies, property-based testing, and mutation testing. Staff engineers are expected to have strong opinions on test architecture and to write tests that catch real bugs without being brittle. Includes an exercise on testing a complex Ruby service with external dependencies.

### 6. [[06-ai-llm-integration/index|AI & LLM Integration]] `emerging` `high-value`

The hottest topic in 2025-2026 interviews. Prompt engineering, RAG (Retrieval-Augmented Generation) patterns, embedding-based search, AI agent architectures, and evaluating LLM outputs. Over 60% of ML-adjacent technical interviews now include LLM-related questions. Even for backend roles, companies want to see that you can integrate AI capabilities into production systems. Includes a coding exercise building a RAG pipeline in Ruby.

### 7. [[07-advanced-data-structures/index|Advanced Data Structures]] `core` `staff-level`

Beyond the basics: Union-Find, segment trees, Fenwick trees, monotonic stacks/queues, LRU cache, skip lists, Bloom filters, and B-trees. These structures separate staff from senior in coding rounds — Union-Find and monotonic stacks appear directly as problems, while segment trees and Bloom filters demonstrate depth in system design discussions. Includes mermaid visualizations and Ruby implementations.

### 8. [[08-search-algorithms/index|Search Algorithms]] `core` `high-frequency`

Deep dive into binary search (standard, rotated, bisect left/right, search on answer space), DFS (cycle detection, topological sort, traversals), BFS (multi-source, 0-1 BFS, bidirectional), Dijkstra's, Bellman-Ford, and A*. Covers when to use which algorithm, why negative weights break Dijkstra's, and the binary-search-on-answer-space pattern that solves a surprising number of problems.

### 9. [[09-dynamic-programming/index|Dynamic Programming]] `core` `high-frequency`

The hardest pattern for most candidates, given its own comprehensive treatment. Covers all major DP families: 1D, 2D/grid, string, knapsack, interval, tree, bitmask, and state machine DP. Includes a recognition cheat sheet for identifying which pattern applies, mermaid diagrams for visualizing subproblem structure, and space optimization techniques.

---

## How to Use This Bank

1. **Start with DSA** if you are rusty on fundamentals. Spend 60% of prep time here.
2. **Prioritize by role**: backend-heavy roles weight Concurrency and API Design; full-stack roles weight OOD and Testing.
3. **Do the exercises timed**. Staff-level interviews are 45-60 minutes. Practice under pressure.
4. **Cross-reference with System Design**: many topics overlap with [[../system-design/index|System Design]] concepts. API Design feeds into system design rounds. Concurrency is critical for distributed systems.
5. **AI/LLM Integration** is a differentiator. If a company builds AI products, expect questions here.

## Related

- [[../system-design/index|System Design Interview Prep]]
- [[../records/ebay/ebay-staff-fe-prep|eBay Staff FE Interview Prep]]
