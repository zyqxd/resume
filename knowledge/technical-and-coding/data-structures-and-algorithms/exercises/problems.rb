# frozen_string_literal: true

# =============================================================================
# Problem 1: Course Schedule (Medium)
# =============================================================================
#
# There are `num_courses` courses labeled 0 to num_courses-1.
# `prerequisites` is an array of pairs [a, b] meaning: to take course a,
# you must first take course b.
#
# Return an array representing a valid order to take all courses.
# If no valid order exists (cycle), return an empty array.
#
# Examples:
#   course_order(2, [[1, 0]])           => [0, 1]
#   course_order(4, [[1,0],[2,0],[3,1],[3,2]]) => [0, 1, 2, 3] or [0, 2, 1, 3]
#   course_order(2, [[1, 0], [0, 1]])   => []  (cycle)
#
# Constraints:
#   - 1 <= num_courses <= 2000
#   - 0 <= prerequisites.length <= 5000
#   - All pairs are unique
#
def course_order(num_courses, prerequisites)
  # Your solution here
end

# =============================================================================
# Problem 2: Word Break (Medium)
# =============================================================================
#
# Given a string `s` and an array of strings `word_dict`, return true if `s`
# can be segmented into a space-separated sequence of one or more dictionary
# words. The same word may be reused multiple times.
#
# Examples:
#   word_break("leetcode", ["leet", "code"])         => true
#   word_break("applepenapple", ["apple", "pen"])    => true
#   word_break("catsandog", ["cats", "dog", "sand", "and", "cat"]) => false
#
# Follow-up: Return ALL valid segmentations (not just true/false).
#   word_break_all("catsanddog", ["cat", "cats", "and", "sand", "dog"])
#     => ["cats and dog", "cat sand dog"]
#
# Constraints:
#   - 1 <= s.length <= 300
#   - 1 <= word_dict.length <= 1000
#   - 1 <= word_dict[i].length <= 20
#
def word_break(s, word_dict)
  # Your solution here
end

def word_break_all(s, word_dict)
  # Your solution here (follow-up)
end

# =============================================================================
# Problem 3: Cheapest Flights Within K Stops (Hard)
# =============================================================================
#
# There are `n` cities connected by `flights`. Each flight is
# [from, to, price]. Given `src`, `dst`, and `k`, find the cheapest price
# from src to dst with at most k stops (k stops = k+1 edges).
# Return -1 if no such route exists.
#
# Examples:
#   cheapest_flights(4, [[0,1,100],[1,2,100],[2,0,100],[1,3,600],[2,3,200]],
#                    0, 3, 1)
#     => 700 (0 -> 1 -> 3)
#
#   cheapest_flights(3, [[0,1,100],[1,2,100],[0,2,500]],
#                    0, 2, 1)
#     => 200 (0 -> 1 -> 2)
#
#   cheapest_flights(3, [[0,1,100],[1,2,100],[0,2,500]],
#                    0, 2, 0)
#     => 500 (0 -> 2 direct)
#
# Constraints:
#   - 1 <= n <= 100
#   - 0 <= flights.length <= n*(n-1)/2
#   - 0 <= k < n
#   - All prices are positive
#
def cheapest_flights(n, flights, src, dst, k)
  # Your solution here
end

# =============================================================================
# Test Harness
# =============================================================================

def run_tests
  puts "=== Problem 1: Course Schedule ==="

  result = course_order(2, [[1, 0]])
  puts "Test 1: #{result.inspect} (expect [0, 1])"

  result = course_order(4, [[1, 0], [2, 0], [3, 1], [3, 2]])
  puts "Test 2: #{result.inspect} (expect valid topo order like [0, 1, 2, 3])"

  result = course_order(2, [[1, 0], [0, 1]])
  puts "Test 3: #{result.inspect} (expect [] -- cycle)"

  result = course_order(1, [])
  puts "Test 4: #{result.inspect} (expect [0])"

  puts "\n=== Problem 2: Word Break ==="

  puts "Test 1: #{word_break('leetcode', %w[leet code])} (expect true)"
  puts "Test 2: #{word_break('applepenapple', %w[apple pen])} (expect true)"
  puts "Test 3: #{word_break('catsandog', %w[cats dog sand and cat])} (expect false)"
  puts "Test 4: #{word_break('', %w[a])} (expect true -- empty string)"

  puts "\nFollow-up:"
  puts "Test 5: #{word_break_all('catsanddog', %w[cat cats and sand dog]).inspect}"
  puts "  (expect [\"cats and dog\", \"cat sand dog\"] in any order)"

  puts "\n=== Problem 3: Cheapest Flights ==="

  flights = [[0, 1, 100], [1, 2, 100], [2, 0, 100], [1, 3, 600], [2, 3, 200]]
  puts "Test 1: #{cheapest_flights(4, flights, 0, 3, 1)} (expect 700)"
  puts "Test 2: #{cheapest_flights(4, flights, 0, 3, 2)} (expect 400)"

  flights2 = [[0, 1, 100], [1, 2, 100], [0, 2, 500]]
  puts "Test 3: #{cheapest_flights(3, flights2, 0, 2, 1)} (expect 200)"
  puts "Test 4: #{cheapest_flights(3, flights2, 0, 2, 0)} (expect 500)"
  puts "Test 5: #{cheapest_flights(3, [], 0, 2, 1)} (expect -1)"
end

run_tests
