# Answer Key -- Graph & DP Problem Set

---

## Problem 1: Course Schedule (Topological Sort)

### Approach: Kahn's Algorithm (BFS-based topological sort)

Build a directed graph from prerequisites. Track in-degrees. Start BFS from all nodes with in-degree 0. Each time you process a node, decrement in-degrees of its neighbors. If you process all nodes, no cycle exists.

**Why Kahn's over DFS-based topo sort?** Both are O(V + E). Kahn's is often cleaner to implement and naturally detects cycles (if the result has fewer nodes than expected, there is a cycle). DFS-based requires tracking three states (unvisited, in-progress, visited) to detect back edges.

**Time:** O(V + E) where V = num_courses, E = prerequisites.length
**Space:** O(V + E) for the graph and in-degree array

```ruby
def course_order(num_courses, prerequisites)
  graph = Array.new(num_courses) { [] }
  in_degree = Array.new(num_courses, 0)

  prerequisites.each do |course, prereq|
    graph[prereq] << course
    in_degree[course] += 1
  end

  queue = (0...num_courses).select { |i| in_degree[i] == 0 }
  order = []

  until queue.empty?
    node = queue.shift
    order << node

    graph[node].each do |neighbor|
      in_degree[neighbor] -= 1
      queue << neighbor if in_degree[neighbor] == 0
    end
  end

  order.length == num_courses ? order : []
end
```

### Alternative: DFS-based topological sort

```ruby
def course_order_dfs(num_courses, prerequisites)
  graph = Array.new(num_courses) { [] }
  prerequisites.each { |c, p| graph[p] << c }

  # 0 = unvisited, 1 = in-progress, 2 = visited
  state = Array.new(num_courses, 0)
  order = []
  has_cycle = false

  dfs = lambda do |node|
    return if has_cycle

    state[node] = 1

    graph[node].each do |neighbor|
      if state[neighbor] == 1
        has_cycle = true
        return
      end
      dfs.call(neighbor) if state[neighbor] == 0
    end

    state[node] = 2
    order.unshift(node) # prepend to get correct order
  end

  (0...num_courses).each do |i|
    dfs.call(i) if state[i] == 0
  end

  has_cycle ? [] : order
end
```

### Edge cases to watch

- Single course, no prerequisites: return `[0]`
- Self-loop `[0, 0]`: cycle, return `[]`
- Disconnected components: all nodes must still appear in the result
- Multiple valid orderings: any topological order is acceptable

---

## Problem 2: Word Break

### Part 1: Boolean check (DP)

**Approach:** Bottom-up DP. `dp[i]` is true if `s[0...i]` can be segmented. For each position i, check all possible last words ending at i.

**Time:** O(n^2 * m) where n = s.length, m = max word length (for substring comparison)
**Space:** O(n)

**Optimization:** Use a Set for O(1) word lookup. Only check substrings up to the maximum word length.

```ruby
def word_break(s, word_dict)
  return true if s.empty?

  dict = Set.new(word_dict)
  max_len = word_dict.map(&:length).max
  dp = Array.new(s.length + 1, false)
  dp[0] = true

  (1..s.length).each do |i|
    (1..[i, max_len].min).each do |len|
      if dp[i - len] && dict.include?(s[i - len...i])
        dp[i] = true
        break
      end
    end
  end

  dp[s.length]
end
```

### Part 2: All segmentations (Backtracking + Memoization)

**Approach:** DFS with memoization. For each position, try every word that matches starting at that position. Cache results to avoid recomputation.

**Time:** O(n * 2^n) worst case (exponential number of valid segmentations), but memoization makes practical cases fast.
**Space:** O(n * 2^n) for storing all results

```ruby
def word_break_all(s, word_dict)
  dict = Set.new(word_dict)
  memo = {}

  backtrack = lambda do |start|
    return [''] if start == s.length
    return memo[start] if memo.key?(start)

    results = []

    (start...s.length).each do |i|
      word = s[start..i]
      next unless dict.include?(word)

      suffixes = backtrack.call(i + 1)
      suffixes.each do |suffix|
        if suffix.empty?
          results << word
        else
          results << "#{word} #{suffix}"
        end
      end
    end

    memo[start] = results
  end

  backtrack.call(0)
end
```

### Edge cases

- Empty string: should return `true` (can be segmented into zero words)
- Single character matching: `"a"` with dict `["a"]`
- Overlapping words: `"cats"` with dict `["cat", "cats"]` -- both valid prefixes
- No match possible: `"catsandog"` -- "og" cannot be formed

---

## Problem 3: Cheapest Flights Within K Stops

### Approach: Modified Bellman-Ford

Standard Bellman-Ford relaxes all edges V-1 times. Here, we relax all edges K+1 times (since K stops means K+1 edges). Crucially, we must use the costs from the *previous* iteration (not the current one) to avoid propagating updates within the same iteration.

**Why not Dijkstra's?** Standard Dijkstra's does not respect the K-stops constraint. You could modify it with a priority queue storing `(cost, node, stops_remaining)`, but that is more complex and can be slower due to duplicate state exploration.

**Time:** O(K * E) where E = flights.length
**Space:** O(n) for the cost array

```ruby
def cheapest_flights(n, flights, src, dst, k)
  costs = Array.new(n, Float::INFINITY)
  costs[src] = 0

  (k + 1).times do
    # Copy costs from previous iteration to avoid using
    # updates from this iteration (critical correctness point)
    prev_costs = costs.dup

    flights.each do |from, to, price|
      next if prev_costs[from] == Float::INFINITY

      new_cost = prev_costs[from] + price
      costs[to] = new_cost if new_cost < costs[to]
    end
  end

  costs[dst] == Float::INFINITY ? -1 : costs[dst]
end
```

### Alternative: BFS with pruning

```ruby
def cheapest_flights_bfs(n, flights, src, dst, k)
  graph = Hash.new { |h, key| h[key] = [] }
  flights.each { |f, t, p| graph[f] << [t, p] }

  # [node, cost, stops_used]
  queue = [[src, 0, 0]]
  best = Array.new(n, Float::INFINITY)
  best[src] = 0
  min_cost = Float::INFINITY

  until queue.empty?
    node, cost, stops = queue.shift

    graph[node].each do |neighbor, price|
      new_cost = cost + price
      next if new_cost >= min_cost # prune: already worse than best known
      next if stops > k           # prune: too many stops

      if neighbor == dst
        min_cost = [min_cost, new_cost].min
      elsif new_cost < best[neighbor]
        best[neighbor] = new_cost
        queue << [neighbor, new_cost, stops + 1]
      end
    end
  end

  min_cost == Float::INFINITY ? -1 : min_cost
end
```

### Critical detail: why `prev_costs = costs.dup`?

Without the copy, consider flights `[0->1, 100]` and `[1->2, 100]` with K=0 (direct flights only). If we update costs in-place, processing flight `0->1` sets `costs[1] = 100`, then processing `1->2` in the same iteration sees `costs[1] = 100` and sets `costs[2] = 200`. But with K=0, we should only allow direct flights -- `0->2` only. The copy ensures we only use costs from the previous round.

### Edge cases

- K=0: only direct flights allowed
- No path exists: return -1
- Multiple paths with same cost but different stops
- src == dst: return 0 (though not typically tested)
- Negative prices: not in constraints, but Bellman-Ford handles them naturally (unlike Dijkstra)

---

## Summary

| Problem | Key Pattern | Key Insight |
|---|---|---|
| Course Schedule | Topological sort (Kahn's) | In-degree tracking detects cycles naturally |
| Word Break | DP + Set lookup | Limit inner loop to max word length for efficiency |
| Cheapest Flights | Modified Bellman-Ford | Must copy cost array between iterations to respect K constraint |
