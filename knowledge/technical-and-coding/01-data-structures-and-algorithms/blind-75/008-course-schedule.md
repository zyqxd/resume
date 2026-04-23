# 207. Course Schedule

- **Difficulty:** Medium
- **URL:** https://leetcode.com/problems/course-schedule/
- **Category:** Graph, DFS, Cycle Detection, Topological Sort

## Problem

There are a total of `numCourses` courses you have to take, labeled from `0` to `numCourses - 1`. You are given an array `prerequisites` where `prerequisites[i] = [a, b]` indicates that you must take course `b` before course `a`. Return `true` if you can finish all courses (i.e., no circular dependency).

**Example 1:**
- Input: `numCourses = 2, prerequisites = [[1,0]]`
- Output: `true`

**Example 2:**
- Input: `numCourses = 2, prerequisites = [[1,0],[0,1]]`
- Output: `false`
- Explanation: Cycle — course 0 requires 1 and course 1 requires 0

**Constraints:**
- `1 <= numCourses <= 2000`
- `0 <= prerequisites.length <= 5000`
- `prerequisites[i].length == 2`
- All prerequisite pairs are unique

## Solution

**Approach:** DFS cycle detection with 3-state coloring. Build an adjacency map from prerequisites, then DFS from every course. If we revisit a node that's `IN_PROGRESS`, we've found a back edge (cycle). Nodes marked `COMPLETED` are safe to skip.

**Time:** O(V + E) — each node and edge visited once
**Space:** O(V + E) — adjacency map + visited states + recursion stack

```typescript
type Prerequisite = [number, number];

enum State {
  NOT_VISITED,
  IN_PROGRESS,
  COMPLETED,
}

function canFinish(numCourses: number, prerequisites: Prerequisite[]): boolean {
  // Build adjacency map
  let adjMap: Map<number, Prerequisite[]> = new Map();

  for (let prerequisite of prerequisites) {
    let curEdges: Prerequisite[] = adjMap.get(prerequisite[0]) || [];
    curEdges.push(prerequisite);
    adjMap.set(prerequisite[0], curEdges);
  }

  // DFS search with 3 states
  let initialVisited: Map<number, State> = new Map();
  let dfs = (courseId: number, visited: Map<number, State>): boolean => {
    let currentState = visited.get(courseId);

    if (currentState == State.IN_PROGRESS) {
      return false; // cycle detected
    } else if (currentState == State.COMPLETED) {
      return true; // skip
    }

    visited.set(courseId, State.IN_PROGRESS);

    // currentState == unvisited
    let dependencies = adjMap.get(courseId) || [];
    let result = dependencies.every((dependency: Prerequisite) => {
      return dfs(dependency[1], visited);
    });

    visited.set(courseId, State.COMPLETED);
    return result;
  };

  return Array.from({ length: numCourses }).every((_, x) =>
    dfs(x, initialVisited)
  );
}
```

## Key Takeaways

- **3-state DFS** is the standard directed graph cycle detection:
  - `NOT_VISITED` → haven't seen it
  - `IN_PROGRESS` → on the current DFS path (back edge to this = cycle)
  - `COMPLETED` → fully explored, safe to skip
- Must DFS from every node — the graph may be disconnected
- **From cycle detection to topological sort:** when the problem asks "in what order should I do these things given dependencies?" or "is there a valid sequence that respects all constraints?" — collect nodes into a result array as they're marked `COMPLETED`. If a cycle exists, no topological sort is possible.
- Alternative: Kahn's algorithm (BFS with in-degree tracking) — naturally produces a topological ordering and detects cycles if the result has fewer nodes than expected
