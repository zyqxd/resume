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
  n = base_config['size']
  attrs = base_config['attributes']

  (0...n).map do |i| # O(N*M)
    attrs.map do |k, v|
      [k, v.sample] 
    end.to_h
  end
end

# Level 2
# Now you need to randomly generate size number of NFTs without duplicates. 
# Duplicates are defined as two NFTs having the same values for all attributes.

# Level 3
# Now each attribute has a rarity value that represents how likely it appears. 
# You should now add rarity weighting so some attribute values are generated more often than others based on their rarity.