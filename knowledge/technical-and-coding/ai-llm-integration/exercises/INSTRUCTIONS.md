# Build a RAG Pipeline -- Coding Exercise

## Setup

You are given `rag_pipeline.rb`, a partially implemented RAG (Retrieval-Augmented Generation) system in Ruby. The system has document ingestion, chunking, embedding, vector search, and question-answering components. Some parts are implemented, some have bugs, and some are stubs that you need to complete.

You also have `rag_test_data.rb` which provides test documents, test questions with expected answers, and fake API clients for testing without real LLM calls.

## Your task (55 minutes)

### Part 1: Debug and Fix (15 minutes)

The existing code has **15+ intentional bugs** across the pipeline. Find and fix them. Categories include:
- Chunking edge cases (empty docs, overlap > chunk_size)
- Embedding normalization errors
- Vector search scoring bugs
- Prompt construction issues
- Context window management bugs

### Part 2: Implement Missing Features (25 minutes)

Complete the stub methods:
1. **`HybridSearcher#search`**: combine vector search with keyword (BM25) search using reciprocal rank fusion
2. **`RagEvaluator#evaluate_faithfulness`**: check if the answer only uses information from the provided context
3. **`ConversationalRag#query`**: support multi-turn conversation with context windowing

### Part 3: Write Tests (15 minutes)

Write tests for:
- The chunking logic (edge cases: empty text, very short text, overlap boundaries)
- The vector search (verify ranking correctness)
- The faithfulness evaluator (hallucinated vs grounded answers)

## Evaluation Criteria (Staff Level)

- Can you identify subtle bugs in the numerical computations (normalization, similarity)?
- Do you handle edge cases in text processing (empty strings, Unicode, very long inputs)?
- Is your hybrid search implementation sound (correct fusion scoring)?
- Do you understand the trade-offs in your design decisions?
- Are your tests meaningful (not just smoke tests)?

## Scoring

| Score | Description |
|---|---|
| Strong hire | 12+ bugs found, all stubs implemented, 5+ meaningful tests |
| Hire | 8-11 bugs, 2/3 stubs implemented, basic tests |
| Lean hire | 5-7 bugs, 1-2 stubs partially implemented |
| No hire | <5 bugs found, or fundamental misunderstanding of RAG |

When done, check `ANSWER_KEY.md`.
