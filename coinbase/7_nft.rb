# Level 1
# Given a NFT config such as:

# {
#   "name": "collection_name",
#   "size": 1000,
#   "attributes": {
#     "nose": ["pointy", "tiny"],
#     "mouth": ["smile", "flat"]
#   }
# }
# your task is to randomly generate size number of NFTs, by randomly selecting one value for each attribute.

# simple loop to n, choose a random answer, normal distribution
def generate_nfts(base_config)
  n = base_config[:size]
  attrs = base_config[:attributes]

  (0...n).map do |i| # O(N*M)
    attrs.map do |k, v|
      attrs.transform_values(&:sample).values
    end
  end
end

# Level 2
# Now you need to randomly generate size number of NFTs without duplicates. 
# Duplicates are defined as two NFTs having the same values for all attributes.
# 
# We care about 2 parameters
# Total possibilities T
# Request size K
# For K > T -> We return everything - max compute
# For K < T 
#   If T is small -> We can materialize the cartesian product (every combination), then sample K
#   Else -> rejection sampling
#   For large T this becomes slow (as rejection set increases)


# Level 3
# Now each attribute has a rarity value that represents how likely it appears. 
# You should now add rarity weighting so some attribute values are generated more often than others based on their rarity.

# use binary search with cumulative weights
def build_sampler(weighted_values)
  values = weighted_values.map(&:first)
  weights = weighted_values.map(&:last)
  total = weights.sum
  cumulative = weights.reduce([]) do |acc, w|
    acc << (acc.last || 0) + w
  end

  # i.e [70, 100]
  [values, cumulative, total]
end

def sample(values, cumulative, total)
  r = rand(total)
  idx = cumulative.bsearch_index { |c| c > r }
  values[idx]
end


def generate_unique_nfts(base_config)
  n = base_config[:size]
  attrs = base_config[:attributes]
  total = attrs.reduce(1) { |a, (_k, v)| a * v.size }
  generated = Set.new
  results = []

  samplers = attrs.transform_values { |v| build_sampler(v) }

  while results.size < n
    combo = attrs.keys.map do |k|
      values, cumulative, total = samplers[k]
      sample(values, cumulative, total)
    end
    key = combo

    next if generated.include?(key)
    generated << key
    results << combo.join(', ')
  end

  results
end

puts generate_unique_nfts({
  "name": "collection_name",
  "size": 3,
  "attributes": {
    "nose": [["pointy", 70], ["tiny", 30]],
    "mouth": [["smile", 40], ["flat", 60]]
  }
})

# Radix sampling
# Assign a number range for each attr
#  - nose: 3 options → ["pointy", "tiny", "round"]
#  - mouth: 2 options → ["smile", "flat"]
#  - hat: 4 options → ["red", "blue", "green", "yellow"]
# Total = 3 * 2 * 4 = 24
# Sample random number -> 17
# 17 % 3 => R 2 => nose[2]
# 5 % 2 => R 1 => mouth[1]
# 2 % 4 => R 4 => hat[4]
# For K unqiue answers -> (0...24).sample(k)