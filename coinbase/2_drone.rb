# Drone
# You are designing a drone delivery system that transports a package from position 0 to position target.

# All positions are on a one-dimensional number line. You are given an array stations, where each value represents the position of a charging station.

# A drone can only take off from a charging station. Once launched, it can fly forward at most 10 units. After the drone lands, the package location is updated to the landing position.

# At each step:

# Let current be the current package position.
# Find the nearest charging station ahead of or at the current position, meaning the smallest station position such that station >= current.
# A human carries the package from current to that station.
# A drone launches from that station and flies forward by min(10, target - station) units.
# Update current to the drone’s landing position.
# Repeat this process until the package reaches target.

# Return the total distance that the package is carried by humans. If the package cannot reach target, return -1.

# Note: drones do NOT need to land at stations. They land at whatever position
# their flight puts them. The human then walks forward to the next station.
# Stations behind `current` are skipped -- only stations with position >= current count.

# Example:

# target = 25
# stations = [0, 8, 15, 20]

# Step 1:
# current = 0
# nearest station >= 0 is 0
# human distance += 0     (already at the station)
# drone launches from 0, flies min(10, 25-0) = 10 units, lands at 10

# Step 2:
# current = 10
# nearest station >= 10 is 15     (station 8 is behind us, skipped)
# human distance += 5     (walks 10 -> 15)
# drone launches from 15, flies min(10, 25-15) = 10 units, lands at 25 = target

# Output: 5

# Follow-up:
# - What if you can choose any station ahead of or at the current position instead of always choosing the nearest one?
# - What if there are multiple drones available?

class Delivery
  def initialize(target, stations)
    @target = target
    @stations = stations
    @position = 0
    @can_fly = true # Starts off flyable
    @walked = 0
    @stuck = false
  end

  # Greedy loop
  # start with drone, then if we landed at 
  def run
    while !@stuck && @position < @target
      # puts "==="
      # puts "Start from #{@position}"
      if @can_fly
        do_fly
      else
        do_walk
      end
    end

    @stuck ? -1 : @walked
  end

  # Choose any station -> fly to nearest station less than 10 or go to 10 (greedy)
  def do_fly
    next_station = next_closest_station
    distance_to_next_station = next_station == -1 ? Float::INFINITY : @stations[next_station] - @position
    distance_to_target = @target - @position

    flight_distance = [10, distance_to_next_station, distance_to_target].min
    # puts "Fly from #{@position} to #{@position + flight_distance} - #{flight_distance}"
    @position += flight_distance

    @can_fly = distance_to_next_station <= 10 && distance_to_next_station < distance_to_target
  end

  def do_walk
    next_station = next_closest_station

    if next_station == -1
      @stuck = true 
      return
    end

    @walked += (@stations[next_station] - @position)
    # puts "Walk from #{@position} to #{@stations[next_station]} - #{@stations[next_station] - @position}"
    @position = @stations[next_station]

    @can_fly = true
  end

  def next_closest_station
    lo, hi = 0, @stations.length
    result = -1
    while lo < hi
      mid = (lo + hi) / 2

      if @stations[mid] > @position
        result = mid
        hi = mid
      else
        lo = mid + 1
      end
    end

    result
  end
end

puts "1: #{Delivery.new(25, [0,8,15,20]).run == 0}"
puts "2: #{Delivery.new(25, [0,10,21,30]).run == 1}"
puts "3: #{Delivery.new(0,   [0]).run == 0}"        # already at target
puts "4: #{Delivery.new(10,  [0]).run == 0}"        # drone lands exactly on target
puts "5: #{Delivery.new(11,  [0]).run == -1}"       # one short, no station ahead
puts "6: #{Delivery.new(100, []).run == -1}"        # no stations at all
puts "7: #{Delivery.new(100, [0]).run == -1}"       # one hop, can't reach
puts "8: #{Delivery.new(100, [0, 50]).run == -1}"   # gap > 10, stranded after first hop
puts "9: #{Delivery.new(25,  [0, 10, 20]).run == 0}"
puts "10: #{Delivery.new(5,  [0, 10]).run == 0}"    # target before second station



