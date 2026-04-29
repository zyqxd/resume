# You task is to process the logs and group them by process and thread.

# You need to read the logs from the file, parse the logs, and store the result back into the file system

# Follow-up:

# Given start_time and end_time, determine:

# which threads were active during that time range
# which processes were active during that time range
# the maximum number of concurrent active threads or processes

# Let's split our string by the new line character \n
# Then for each line, let's assume split by comma. Each string is in order
# We'll need solutions (hash) for each process, thread
# We'll also assume that string is not coming in by timestamp, but is a integer string that is parseable

require 'time'
require 'set'

class ParseLogs
  attr_reader :raw_logs, :processed_logs, :thread_logs, :process_logs

  def initialize(raw_logs)
    @raw_logs = raw_logs
    @processed_logs = []
    @thread_logs = {}
    @process_logs = {}

    build_logs
  end

  # "active" = logged in [s,e]
  def point_in_time_count(start_time, end_time) 
    index = @processed_logs.bsearch_index {|log| log[:timestamp] >= start_time }
    return [Set.new, Set.new] if index.nil?

    threads, processes = Set.new, Set.new
    while index < @processed_logs.size && @processed_logs[index][:timestamp] <= end_time
      threads << @processed_logs[index][:thread_id]
      processes << @processed_logs[index][:process_id]
      index+= 1
    end

    [threads, processes]
  end

  # "active" = lifespan
  def active_in_range(start_time, end_time) 
    threads = @thread_intervals.select { |_, (f, l)| f <= end_time && l >= start_time }
    processes = @process_intervals.select { |_, (f, l)| f <= end_time && l >= start_time }
    max_threads = max_concurrent_for(threads.transform_values { |f, l| [[f, start_time].max, [l, end_time].min]})
    max_processes = max_concurrent_for(processes.transform_values { |f, l| [[f, start_time].max, [l, end_time].min]})

    [threads.keys.to_set, processes.keys.to_set, max_threads, max_processes]
  end

  private

  def build_logs
    split_logs = @raw_logs.split(/\n/).compact
    @processed_logs = split_logs.map do |log_line|
      process_id, thread_id, content, timestamp_str = log_line.split(',')

      {
        process_id: process_id,
        thread_id: thread_id,
        content: content,
        timestamp: Time.parse(timestamp_str),
      }
    end.sort_by { |log| log[:timestamp] }
    @thread_logs = @processed_logs.group_by { |log| log[:thread_id] }
    @process_logs = @processed_logs.group_by { |log| log[:process_id] }

    build_intervals
  end

  def build_intervals 
    @thread_intervals = {} # tid => [first, last]
    @process_intervals = {} # pid => [first, last]

    @processed_logs.each do |log|
      tid, pid, ts = log[:thread_id], log[:process_id], log[:timestamp]
      @thread_intervals[tid] ||= [ts, ts]; @thread_intervals[tid][1] = ts
      @process_intervals[pid] ||= [ts, ts]; @process_intervals[pid][1] = ts
    end
  end

  def max_concurrent_for(intervals)
    events = []
    intervals.each_value do |first, last|
      events << [first, 1]
      events << [last, -1]
    end
    # -delta, +1 before -1, so count goes to 2 before 1
    # +delta, -1 before +1, so count goes to -1 and then 0
    events = events.sort_by { |t, delta| [t, -delta] }
    count = 0
    max = 0
    events.each do |_, d| 
      count += d
      max = count if count > max 
    end 
    max
  end
end

garbled_logs = <<-TEXT
1,a,abc,123
2,a,abc,124
3,b,abc,122
4,b,abc,123
TEXT

parsed = ParseLogs.new(garbled_logs)

puts "processed_logs"
puts parsed.processed_logs
puts "thread_logs"
puts parsed.thread_logs
puts "process_logs"
puts parsed.process_logs

