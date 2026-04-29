# You are given a set of transactions, each with: <id, size, fee>

# You also have a block size limit of 100. Your goal is to select a set of transactions whose total 
# size does not exceed the block size while maximizing the total fee. You do not need the exact 
# optimal solution if a scalable heuristic is more appropriate.
  
  

# Follow-ups: Each transaction may have a parent transaction. A child can only be included if its 
# parent is included in the same block. One parent can have multiple children, but each child has only one parent.


# Heuristics -> 
# Sort transaction list by fee/size descending
# Walk array, add to transactions if size_remaining >= tx.size
# Stop when block is full
# This is greedy
# 
# Dynamic P ->
# W = 100 -> very small
# 

# dp[i][w] = max fee using first i transactions with remaining capacity w
# for each tx i, we have s_i and f_i and capacity so far w, we have two choices
# skip it (dp[i-1][w])
# take it (only if s_i <= w) dp[i-1][w-s_i] + f_i
# both are i-1 because we have a limited trx count (0/1 knapsack). If dp[i][w - s_i], it means we have limitless takes
# 
require 'set'

def dp(transactions)
  n = transactions.size
  w = 100
  dp = Array.new(n + 1) { Array.new(w + 1, 0) } # dp[n][w] initialized to 0

  for i in 1..n
    s_i, f_i = transactions[i-1].size, transactions[i-1].fee

    for j in 0..w
      dp[i][j] = [
        dp[i-1][j],                                        # ignore
        s_i <= j ? dp[i-1][j-s_i] + f_i : -Float::INFINITY # take, add value of our fee to pre value
      ].max
    end
  end

  # To get trx, walk back table
  path = []
  capacity = w
  n.downto(1) do |i|
    if dp[i][capacity] != dp[i-1][capacity]
      path << transactions[i-1]
      capacity -= transactions[i-1].size
    end
  end

  [dp[n][w], path]
end

def greedy(transactions)
  # Sort trx,
  # walk array, add to transaction if size_remaining >= tx.size
  sorted = transactions.sort_by { |trx| [-trx.fee.to_f / trx.size] } # fee desc, size asc
  results = []
  capacity_remaining = 100

  (0..sorted.size-1).each do |i|
    trx = sorted[i]
    if trx.size <= capacity_remaining
      results << trx
      capacity_remaining -= trx.size
    end
  end

  [results.sum(&:fee), results]
end

# Each tx has at most 1 parent
# Naive: pre-compute ancestory packages, greedy by package fee rate - this over counts ancestors
# Better: ancestor-fee-rate selection with re-computation after each pick
# Relationships: { cid: pid } => we do more walk-ups
def greedy_with_tree(transactions, relationships)
  results = Set.new
  remaining = transactions.to_h { |trx| [trx.id, trx] }
  capacity = 100

  while remaining.keys.length > 0
    best_ratio, best_pkg = -Float::INFINITY, []

    # compute each pkg
    remaining.each do |_, trx|
      pkg = []
      tid = trx.id
      # Walk up as long as we have a parent and we are not included
      while !results.include?(tid)
        pkg << remaining[tid]
        tid = relationships[tid]
        break if tid.nil?
      end

      pkg_fee = pkg.sum(&:fee)
      pkg_size = pkg.sum(&:size)
      ratio = pkg_fee.to_f / pkg_size
      
      if ratio > best_ratio && pkg_size <= capacity
        best_pkg = pkg
        best_ratio = ratio
      end
    end

    break if best_pkg.empty?
    results.merge(best_pkg.map(&:id))
    capacity -= best_pkg.sum(&:size)
    best_pkg.each { |trx| remaining.delete(trx.id) }
  end

  results.to_a
end

Transaction = Struct.new(:id, :fee, :size)
trx = (1..99).map do |i|
  Transaction.new(i, i, i) 
end

puts dp(trx)
puts greedy(trx)

txs = [
  Transaction.new(:a, 1,  10),  # low fee, big
  Transaction.new(:b, 50, 20),
  Transaction.new(:c, 5,  20),
  Transaction.new(:d, 30, 99),  # standalone, fits
]
rels = { b: :a, c: :a }  # d has no parent
puts greedy_with_tree(txs, rels)