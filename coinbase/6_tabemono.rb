# Level 1
# Given a user's location, a list of restaurants with their IDs, 
# coordinates and menu items (different restaurants can sell the same food items, possibly at different prices), 
# write two functions: for a given item (e.g., Burger), find the restaurant that sells it for the cheapest price, 
# and find the closest restaurant that sells it.

# Level 2
# The data format is different from L1. L2 only provides a list of orders. 
# Each order contains: order ID, food item, total price (quantity × unit price), 
# and timestamp. Write a function to compute, within a given time range (start, end), 
# the total number of orders, the total sales amount, and the average price per order.

# Level 3
# Based on L2, find the Top K orders with the highest sales amount.

# Level 4
# Find the most frequently ordered item.
# 
#

## Part 1
Restaurant = Struct.new(:id, :x, :y, :menu)
restaurants = [
  [1, [10, 100], [["burger", 10], ["fries", 5]]],
  [2, [-120, -320], [["burger", 7]]]
].map { |id, (x, y), menu_arr| Restaurant.new(id, x, y, menu_arr.to_h)}

item_by_price = {}
restaurants.each do |r|
  r.menu.each do |item, price|
    item_by_price[item] ||= []
    item_by_price[item] << [price, r]
  end
end

def find_cheapest(item_name, item_by_price)
  prices_for_item = item_by_price[item_name]
  prices_for_item.min_by { |price, _| price }[1]
end

def find_closest(user_x, user_y, item_name, item_by_price)
  find_distance_from_user = ->(x, y) { ((x - user_x) ** 2 + (y - user_y) ** 2) ** 0.5 }

  resturants_with_item = item_by_price[item_name].map(&:last)
  resturants_with_item.min_by { |resturant| find_distance_from_user.call(resturant.x, resturant.y) }
end

puts "cheapest"
puts find_cheapest("burger", item_by_price) # 2
puts find_cheapest("fries", item_by_price) # 1
puts "closest"
puts find_closest(0, 0, "burger", item_by_price) # 1
puts find_closest(-100, -300, "burger", item_by_price) # 2

## Part 2
# - sort by timestamp, then walk forward on that range (bsearch_index)
Order = Struct.new(:id, :item_name, :total_price, :timestamp)
orders = [
  [1, "burger", 100, 123],
  [2, "fries", 35, 124],
  [3, "burger", 10, 125],
  [4, "fries", 70, 126],
  [5, "burger", 20, 127],
  [6, "fries", 14, 128],
  [7, "fries", 20, 129],
].map { |id, name, total, timestamp| Order.new(id, name, total, timestamp) }

def compute_stats(orders, start_time, end_time)
  # assume orders sorted
  start_index = orders.bsearch_index { |o| o.timestamp >= start_time }
  end_index = orders.bsearch_index { |o| o.timestamp > end_time } # first one where this is false
  return [0,0,0] if start_index.nil? || end_index.nil?

  count = 0
  total = 0
  (start_index...end_index).each do |index|
    count += 1
    total += orders[index].total_price
  end

  [count, total, total.to_f / count]
end

puts "part 2"
puts compute_stats(orders, 125, 127).join(", ")

## Part 3
# max_heap pop k
# 

class Heap
  # Block returns true if `a` should come out before `b`.
  # Min-heap: ->(a, b) { a < b }
  # Max-heap: ->(a, b) { a > b }
  # By field: ->(a, b) { a.price < b.price }
  def initialize(&prioritized)
    @arr = []
    @prioritized = prioritized || ->(a, b) { a < b }
  end

  def size = @arr.size
  def empty? = @arr.empty?
  def peek = @arr[0]

  def push(x)
    @arr << x
    sift_up(@arr.size - 1)
  end

  def pop
    return nil if @arr.empty?
    top = @arr[0]
    last = @arr.pop
    unless @arr.empty?
      @arr[0] = last
      sift_down(0)
    end
    top
  end

  private

  def higher?(i, j) = @prioritized.call(@arr[i], @arr[j])

  def sift_up(i)
    while i > 0
      parent = (i - 1) / 2
      break unless higher?(i, parent)
      @arr[parent], @arr[i] = @arr[i], @arr[parent]
      i = parent
    end
  end

  def sift_down(i)
    n = @arr.size
    loop do
      l, r = 2*i + 1, 2*i + 2
      best = i
      best = l if l < n && higher?(l, best)
      best = r if r < n && higher?(r, best)
      break if best == i
      @arr[i], @arr[best] = @arr[best], @arr[i]
      i = best
    end
  end
end

def top_k_orders(orders, start_time, end_time, k)
  max_heap = Heap.new { |a, b| a.total_price > b.total_price }
  start_index = orders.bsearch_index { |o| o.timestamp >= start_time }
  end_index = orders.bsearch_index { |o| o.timestamp > end_time } # first one where this is false 
  return [] if start_index.nil?
  end_index = orders.length - 1 if end_index.nil?

  # Insert
  (start_index...end_index).each do |i|
    max_heap.push(orders[i])
  end

  results = []
  # Pop k
  (0...k).each do |i|
    results << max_heap.pop()
  end

  results
end

puts "part 3"
puts top_k_orders(orders, 123, 128, 3)
## Part 4
#

def most_frequent_order(orders)
  orders.map(&:item_name).tally.max_by { |item, count| count }&.first
end

puts "part 4"
puts most_frequent_order(orders)