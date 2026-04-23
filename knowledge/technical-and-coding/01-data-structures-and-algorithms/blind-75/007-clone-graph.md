# 133. Clone Graph

- **Difficulty:** Medium
- **URL:** https://leetcode.com/problems/clone-graph/
- **Category:** Graph, DFS, Hash Map

## Problem

Given a reference of a node in a connected undirected graph, return a deep copy (clone) of the graph. Each node contains a value and a list of its neighbors.

**Example 1:**
- Input: `adjList = [[2,4],[1,3],[2,4],[1,3]]`
- Output: `[[2,4],[1,3],[2,4],[1,3]]`

**Example 2:**
- Input: `adjList = [[]]`
- Output: `[[]]`

**Example 3:**
- Input: `adjList = []`
- Output: `[]`

**Constraints:**
- Number of nodes is in the range `[0, 100]`
- `1 <= Node.val <= 100`
- Node values are unique
- No repeated edges or self-loops
- The graph is connected and all nodes can be visited starting from the given node

## Solution

**Approach:** DFS with a map of already-cloned nodes. For each node, create a clone and store it in the map keyed by value. Then recursively clone each neighbor — if already cloned, return the existing clone (this handles cycles).

**Time:** O(V + E) — visit every node and edge once
**Space:** O(V) — clone map + recursion stack

```typescript
function cloneGraph(node: _Node | null): _Node | null {
  function dfsClone(node: _Node, cloned: Map<number, _Node>): _Node {
    if (cloned.has(node.val)) return cloned.get(node.val);

    let newNode = new _Node(node.val, []);
    cloned.set(node.val, newNode);

    for (let neighbor of node.neighbors) {
      newNode.neighbors.push(dfsClone(neighbor, cloned));
    }
    return newNode;
  }

  if (node == null) return null;
  else {
    let cloned: Map<number, _Node> = new Map();
    return dfsClone(node, cloned);
  }
}
```

## Key Takeaways

- The `cloned` map serves double duty: it's both the visited set and the old→new node mapping
- Must add the node to the map **before** recursing into neighbors — otherwise cycles cause infinite recursion
- BFS works equally well here (queue + same map pattern), DFS is just cleaner recursively
- This "clone with a visited map" pattern applies to any graph/linked structure with cycles (e.g., copy list with random pointer)
