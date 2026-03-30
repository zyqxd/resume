# Data Structures & Algorithms

Data structures and algorithms remain the single most tested topic in technical interviews across every tier of company. Even AI-native companies like Anthropic and OpenAI require strong DSA fundamentals. The post-2025 shift is not away from DSA but toward pattern recognition over memorization: interviewers want to see you identify that a problem is a sliding window variant, not that you memorized the solution to "Longest Substring Without Repeating Characters."

At the staff level, you are expected to solve medium-hard problems cleanly in 20-25 minutes, discuss multiple approaches with trade-offs, and optimize without prompting. The code should be production-quality: good variable names, edge case handling, and clear structure.

---

## Core Data Structures

### Arrays & Strings

Arrays are the most common data structure in interviews. Nearly every string problem is an array problem in disguise. Key operations to know cold: traversal, binary search on sorted arrays, in-place modification, and subarray/substring extraction.

Ruby-specific notes: Ruby arrays are dynamic (backed by a C array that doubles in capacity). `Array#slice` is O(k) where k is slice length. String indexing in Ruby 3+ is Unicode-aware, so `str[i]` returns a character, not a byte. Use `String#bytes` or `String#chars` depending on what you need.

```ruby
# Two-pointer pattern: remove duplicates from sorted array in-place
def remove_duplicates(nums)
  return 0 if nums.empty?

  write = 1
  (1...nums.length).each do |read|
    if nums[read] != nums[read - 1]
      nums[write] = nums[read]
      write += 1
    end
  end
  write
end
```

Common patterns: prefix sums, Kadane's algorithm (max subarray), string reversal, anagram detection via character frequency counting.

### Hash Maps

Hash maps (Ruby `Hash`) are the single most useful data structure in interviews. They turn O(n) lookups into O(1) and are the backbone of frequency counting, two-sum style problems, caching, and graph adjacency lists.

Ruby-specific notes: Ruby hashes maintain insertion order (since Ruby 1.9). `Hash.new(0)` gives you a default value, which is useful for counting. `Hash#fetch` raises on missing keys, which is safer than `Hash#[]` returning nil.

```ruby
# Two Sum: find indices of two numbers that add to target
def two_sum(nums, target)
  seen = {}
  nums.each_with_index do |num, i|
    complement = target - num
    return [seen[complement], i] if seen.key?(complement)
    seen[num] = i
  end
  nil
end

# Group anagrams using sorted-character key
def group_anagrams(strs)
  groups = Hash.new { |h, k| h[k] = [] }
  strs.each { |s| groups[s.chars.sort.join] << s }
  groups.values
end
```

Watch for: hash collision behavior (Ruby uses open addressing since 2.4), using mutable objects as keys (don't), and the difference between `Hash#[]` and `Hash#dig` for nested access.

### Trees & Graphs

Trees (especially binary trees and BSTs) and graphs are high-frequency. You must be able to implement BFS and DFS from scratch, handle recursive and iterative traversals, and reason about tree balancing.

For graphs, know adjacency list representation, cycle detection (both directed and undirected), topological sort, and shortest path (BFS for unweighted, Dijkstra's for weighted).

```ruby
# Binary tree node
class TreeNode
  attr_accessor :val, :left, :right

  def initialize(val = 0, left = nil, right = nil)
    @val = val
    @left = left
    @right = right
  end
end

# BFS level-order traversal
def level_order(root)
  return [] unless root

  result = []
  queue = [root]

  until queue.empty?
    level = []
    queue.length.times do
      node = queue.shift
      level << node.val
      queue << node.left if node.left
      queue << node.right if node.right
    end
    result << level
  end
  result
end

# DFS: check if path exists in directed graph (adjacency list)
def has_path?(graph, source, target, visited = Set.new)
  return true if source == target
  return false if visited.include?(source)

  visited.add(source)
  (graph[source] || []).any? { |neighbor| has_path?(graph, neighbor, target, visited) }
end
```

Key patterns: lowest common ancestor, tree serialization/deserialization, diameter of tree, validate BST, graph coloring (bipartite check).

### Linked Lists

Less common at senior/staff level but still appear. Key operations: reversal, cycle detection (Floyd's tortoise and hare), merge sorted lists, find middle node.

```ruby
class ListNode
  attr_accessor :val, :next

  def initialize(val = 0, nxt = nil)
    @val = val
    @next = nxt
  end
end

# Reverse a linked list iteratively
def reverse_list(head)
  prev = nil
  current = head
  while current
    nxt = current.next
    current.next = prev
    prev = current
    current = nxt
  end
  prev
end

# Detect cycle using Floyd's algorithm
def has_cycle?(head)
  slow = fast = head
  while fast&.next
    slow = slow.next
    fast = fast.next.next
    return true if slow == fast
  end
  false
end
```

Pro tip: always use a dummy head node when building a new list to avoid special-casing the first insertion.

### Stacks & Queues

Stacks are critical for parsing problems (valid parentheses, expression evaluation), monotonic stack patterns (next greater element, largest rectangle in histogram), and DFS simulation. Queues power BFS.

```ruby
# Valid parentheses
def valid_parentheses?(s)
  stack = []
  pairs = { ')' => '(', ']' => '[', '}' => '{' }

  s.each_char do |c|
    if pairs.values.include?(c)
      stack.push(c)
    elsif pairs.key?(c)
      return false if stack.empty? || stack.pop != pairs[c]
    end
  end
  stack.empty?
end

# Monotonic stack: next greater element
def next_greater_element(nums)
  result = Array.new(nums.length, -1)
  stack = [] # stores indices

  nums.each_with_index do |num, i|
    while !stack.empty? && nums[stack.last] < num
      result[stack.pop] = num
    end
    stack.push(i)
  end
  result
end
```

Ruby note: Ruby arrays work as both stacks (`push`/`pop`) and queues (`push`/`shift`), but `shift` is O(n). For performance-critical queues, use a ring buffer or `Queue` from the standard library.

### Heaps (Priority Queues)

Heaps appear in top-k problems, merge-k-sorted-lists, median finding, and scheduling. Ruby does not have a built-in heap, so you need to implement one or know how to simulate it.

```ruby
# Min-heap implementation
class MinHeap
  def initialize
    @data = []
  end

  def push(val)
    @data << val
    bubble_up(@data.length - 1)
  end

  def pop
    return nil if @data.empty?

    swap(0, @data.length - 1)
    val = @data.pop
    bubble_down(0) unless @data.empty?
    val
  end

  def peek
    @data.first
  end

  def size
    @data.length
  end

  def empty?
    @data.empty?
  end

  private

  def bubble_up(i)
    while i > 0
      parent = (i - 1) / 2
      break if @data[parent] <= @data[i]

      swap(i, parent)
      i = parent
    end
  end

  def bubble_down(i)
    loop do
      smallest = i
      left = 2 * i + 1
      right = 2 * i + 2

      smallest = left if left < @data.length && @data[left] < @data[smallest]
      smallest = right if right < @data.length && @data[right] < @data[smallest]
      break if smallest == i

      swap(i, smallest)
      i = smallest
    end
  end

  def swap(a, b)
    @data[a], @data[b] = @data[b], @data[a]
  end
end

# Find k-th largest element
def find_kth_largest(nums, k)
  heap = MinHeap.new
  nums.each do |num|
    heap.push(num)
    heap.pop if heap.size > k
  end
  heap.peek
end
```

### Tries (Prefix Trees)

Tries appear in autocomplete, spell checking, and word search problems. They offer O(m) lookup where m is word length, regardless of dictionary size.

```ruby
class TrieNode
  attr_accessor :children, :end_of_word

  def initialize
    @children = {}
    @end_of_word = false
  end
end

class Trie
  def initialize
    @root = TrieNode.new
  end

  def insert(word)
    node = @root
    word.each_char do |c|
      node.children[c] ||= TrieNode.new
      node = node.children[c]
    end
    node.end_of_word = true
  end

  def search(word)
    node = find_node(word)
    node&.end_of_word == true
  end

  def starts_with?(prefix)
    !find_node(prefix).nil?
  end

  private

  def find_node(prefix)
    node = @root
    prefix.each_char do |c|
      return nil unless node.children[c]
      node = node.children[c]
    end
    node
  end
end
```

---

## Algorithmic Patterns

### Sliding Window

Used for subarray/substring problems with a contiguous constraint. Two variants: fixed-size window and variable-size window.

```ruby
# Longest substring without repeating characters (variable window)
def length_of_longest_substring(s)
  char_index = {}
  max_len = 0
  left = 0

  s.each_char.with_index do |c, right|
    if char_index.key?(c) && char_index[c] >= left
      left = char_index[c] + 1
    end
    char_index[c] = right
    max_len = [max_len, right - left + 1].max
  end
  max_len
end

# Maximum sum subarray of size k (fixed window)
def max_sum_subarray(nums, k)
  window_sum = nums[0...k].sum
  max_sum = window_sum

  (k...nums.length).each do |i|
    window_sum += nums[i] - nums[i - k]
    max_sum = [max_sum, window_sum].max
  end
  max_sum
end
```

Signal words: "contiguous subarray," "substring," "window of size k," "at most k distinct."

### Two Pointers

Used on sorted arrays or when you need to compare elements from different positions. Variants: opposite-end (two sum on sorted), same-direction (fast/slow for linked lists), and partition (Dutch national flag).

```ruby
# Three sum: find all unique triplets that sum to zero
def three_sum(nums)
  nums.sort!
  result = []

  (0...nums.length - 2).each do |i|
    next if i > 0 && nums[i] == nums[i - 1] # skip duplicates

    left = i + 1
    right = nums.length - 1

    while left < right
      total = nums[i] + nums[left] + nums[right]

      if total == 0
        result << [nums[i], nums[left], nums[right]]
        left += 1
        left += 1 while left < right && nums[left] == nums[left - 1]
      elsif total < 0
        left += 1
      else
        right -= 1
      end
    end
  end
  result
end
```

### BFS & DFS

BFS finds shortest paths in unweighted graphs and processes nodes level-by-level. DFS explores as deep as possible and is natural for backtracking, tree traversals, and cycle detection.

```ruby
# BFS: shortest path in unweighted grid
def shortest_path(grid, start, target)
  rows, cols = grid.length, grid[0].length
  queue = [[start[0], start[1], 0]]
  visited = Set.new([start])
  directions = [[0, 1], [0, -1], [1, 0], [-1, 0]]

  until queue.empty?
    r, c, dist = queue.shift

    return dist if [r, c] == target

    directions.each do |dr, dc|
      nr, nc = r + dr, c + dc
      next unless nr.between?(0, rows - 1) && nc.between?(0, cols - 1)
      next if visited.include?([nr, nc]) || grid[nr][nc] == 1

      visited.add([nr, nc])
      queue << [nr, nc, dist + 1]
    end
  end
  -1
end

# DFS: number of islands
def num_islands(grid)
  return 0 if grid.empty?

  count = 0
  rows, cols = grid.length, grid[0].length

  dfs = lambda do |r, c|
    return if r < 0 || r >= rows || c < 0 || c >= cols || grid[r][c] != '1'

    grid[r][c] = '0' # mark visited
    dfs.call(r + 1, c)
    dfs.call(r - 1, c)
    dfs.call(r, c + 1)
    dfs.call(r, c - 1)
  end

  (0...rows).each do |r|
    (0...cols).each do |c|
      if grid[r][c] == '1'
        count += 1
        dfs.call(r, c)
      end
    end
  end
  count
end
```

### Dynamic Programming

The hardest pattern for most candidates. Key insight: DP is just recursion with memoization (top-down) or building a table from base cases (bottom-up). Identify the subproblem, the recurrence relation, and the base cases.

```ruby
# Coin change: minimum coins to make amount (bottom-up)
def coin_change(coins, amount)
  dp = Array.new(amount + 1, Float::INFINITY)
  dp[0] = 0

  (1..amount).each do |a|
    coins.each do |coin|
      dp[a] = [dp[a], dp[a - coin] + 1].min if coin <= a
    end
  end
  dp[amount] == Float::INFINITY ? -1 : dp[amount]
end

# Longest increasing subsequence (O(n log n) with patience sorting)
def length_of_lis(nums)
  tails = []

  nums.each do |num|
    pos = tails.bsearch_index { |x| x >= num } || tails.length
    tails[pos] = num
  end
  tails.length
end

# 0/1 Knapsack
def knapsack(weights, values, capacity)
  n = weights.length
  dp = Array.new(n + 1) { Array.new(capacity + 1, 0) }

  (1..n).each do |i|
    (0..capacity).each do |w|
      dp[i][w] = dp[i - 1][w]
      if weights[i - 1] <= w
        dp[i][w] = [dp[i][w], dp[i - 1][w - weights[i - 1]] + values[i - 1]].max
      end
    end
  end
  dp[n][capacity]
end
```

Common DP families: linear (climbing stairs, house robber), grid (unique paths, min path sum), string (edit distance, LCS), interval (matrix chain, burst balloons), knapsack variants.

### Greedy

Greedy algorithms make locally optimal choices at each step. They work when the problem has the greedy-choice property (a local optimum leads to a global optimum). Always prove correctness by exchange argument or contradiction before assuming greedy works.

```ruby
# Activity selection: max non-overlapping intervals
def max_non_overlapping(intervals)
  intervals.sort_by! { |s, e| e }
  count = 0
  last_end = -Float::INFINITY

  intervals.each do |s, e|
    if s >= last_end
      count += 1
      last_end = e
    end
  end
  count
end

# Jump game: can you reach the last index?
def can_jump?(nums)
  max_reach = 0
  nums.each_with_index do |jump, i|
    return false if i > max_reach
    max_reach = [max_reach, i + jump].max
  end
  true
end
```

### Backtracking

Backtracking is DFS with pruning. Used for combinatorial problems: permutations, combinations, subsets, N-queens, Sudoku solving. The pattern is always: choose, explore, unchoose.

```ruby
# Generate all valid combinations of n pairs of parentheses
def generate_parentheses(n)
  result = []

  backtrack = lambda do |current, open_count, close_count|
    if current.length == 2 * n
      result << current.dup
      return
    end

    if open_count < n
      backtrack.call(current + '(', open_count + 1, close_count)
    end

    if close_count < open_count
      backtrack.call(current + ')', open_count, close_count + 1)
    end
  end

  backtrack.call('', 0, 0)
  result
end

# N-Queens
def solve_n_queens(n)
  solutions = []
  cols = Set.new
  diag1 = Set.new # row - col
  diag2 = Set.new # row + col

  backtrack = lambda do |row, queens|
    if row == n
      solutions << queens.map { |c| '.' * c + 'Q' + '.' * (n - c - 1) }
      return
    end

    (0...n).each do |col|
      next if cols.include?(col) || diag1.include?(row - col) || diag2.include?(row + col)

      cols.add(col)
      diag1.add(row - col)
      diag2.add(row + col)

      backtrack.call(row + 1, queens + [col])

      cols.delete(col)
      diag1.delete(row - col)
      diag2.delete(row + col)
    end
  end

  backtrack.call(0, [])
  solutions
end
```

---

## Complexity Cheat Sheet

| Structure | Access | Search | Insert | Delete | Notes |
|---|---|---|---|---|---|
| Array | O(1) | O(n) | O(n) | O(n) | O(1) amortized append |
| Hash Map | - | O(1) avg | O(1) avg | O(1) avg | O(n) worst case |
| BST (balanced) | - | O(log n) | O(log n) | O(log n) | Degrades to O(n) if unbalanced |
| Heap | - | O(n) | O(log n) | O(log n) | O(1) peek |
| Trie | - | O(m) | O(m) | O(m) | m = key length |
| Stack/Queue | O(1) top | O(n) | O(1) | O(1) | LIFO / FIFO |

| Algorithm | Time | Space | Notes |
|---|---|---|---|
| Binary search | O(log n) | O(1) | Requires sorted input |
| BFS/DFS | O(V + E) | O(V) | V vertices, E edges |
| Merge sort | O(n log n) | O(n) | Stable |
| Quick sort | O(n log n) avg | O(log n) | O(n^2) worst |
| Dijkstra's | O((V+E) log V) | O(V) | Non-negative weights |
| Topological sort | O(V + E) | O(V) | DAG only |

---

## Study Strategy

1. **Pattern first, problems second.** Learn the seven patterns above. For each, solve 3-5 representative problems.
2. **Implement from scratch in Ruby.** Don't rely on library methods you can't reproduce. Know how to build a heap, a trie, and a graph from scratch.
3. **Time yourself.** 20 minutes for medium, 30 for hard. If stuck after 10 minutes, look at a hint (not the solution).
4. **Verbalize trade-offs.** For every solution, articulate: time complexity, space complexity, and what alternative approaches exist.
5. **Practice the "optimize" step.** Interviewers often ask "can you do better?" after a brute force. Have a mental checklist: can I sort first? Use a hash map? Use a heap? Binary search on the answer?

---

## Exercises

- [[exercises/INSTRUCTIONS|Graph & DP Problem Set]] -- A timed set of three progressively harder problems covering graph traversal, dynamic programming, and optimization.

## Related Topics

- [[../04-concurrency-and-parallelism/index|Concurrency & Parallelism]] -- concurrent data structure access patterns
- [[../03-api-design/index|API Design]] -- pagination and filtering often involve tree/graph traversal
- [[../system-design/index|System Design]] -- distributed data structures, consistent hashing, B-trees
