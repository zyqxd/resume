# frozen_string_literal: true

# A concurrent job processing system with:
# - Thread pool of configurable workers
# - Priority-based job queue
# - Automatic retry with backoff
# - Graceful shutdown
# - Metrics collection
#
# Review this code for concurrency bugs, race conditions, deadlocks,
# and design issues.

require 'thread'
require 'logger'
require 'json'
require 'set'

# ============================================================
# Configuration
# ============================================================

MAX_WORKERS = 8
MAX_RETRIES = 3
RETRY_BACKOFF_BASE = 2
SHUTDOWN_TIMEOUT = 30
MAX_QUEUE_SIZE = 1000

# ============================================================
# Job Definition
# ============================================================

class Job
  attr_accessor :id, :payload, :priority, :attempts, :status,
                :created_at, :started_at, :completed_at, :error

  def initialize(id, payload, priority: 0)
    @id = id
    @payload = payload
    @priority = priority
    @attempts = 0
    @status = :pending
    @created_at = Time.now
    @started_at = nil
    @completed_at = nil
    @error = nil
  end

  def to_s
    "Job##{@id}(priority=#{@priority}, attempts=#{@attempts}, status=#{@status})"
  end
end

# ============================================================
# Priority Queue (not thread-safe -- caller must synchronize)
# ============================================================

class PriorityQueue
  def initialize
    @heap = []
  end

  def push(job)
    @heap << job
    bubble_up(@heap.length - 1)
  end

  def pop
    return nil if @heap.empty?
    swap(0, @heap.length - 1)
    job = @heap.pop
    bubble_down(0)
    job
  end

  def peek
    @heap.first
  end

  def size
    @heap.length
  end

  def empty?
    @heap.empty?
  end

  # B: Returns reference to internal array -- callers can mutate it
  def to_a
    @heap
  end

  private

  def bubble_up(i)
    while i > 0
      parent = (i - 1) / 2
      # B: Higher priority number = higher priority, but comparison is wrong
      # This creates a min-heap (lowest priority first)
      break if @heap[parent].priority >= @heap[i].priority
      swap(i, parent)
      i = parent
    end
  end

  def bubble_down(i)
    loop do
      largest = i
      left = 2 * i + 1
      right = 2 * i + 2

      if left < @heap.length && @heap[left].priority > @heap[largest].priority
        largest = left
      end
      if right < @heap.length && @heap[right].priority > @heap[largest].priority
        largest = right
      end
      break if largest == i
      swap(i, largest)
      i = largest
    end
  end

  def swap(a, b)
    @heap[a], @heap[b] = @heap[b], @heap[a]
  end
end

# ============================================================
# Job Processor
# ============================================================

class JobProcessor
  attr_reader :metrics

  def initialize(num_workers: 4)
    @num_workers = num_workers
    @queue = PriorityQueue.new
    @workers = []
    @running = false
    @mutex = Mutex.new
    @job_available = ConditionVariable.new
    @processed_jobs = {}
    @active_jobs = Set.new
    @metrics = {
      total_enqueued: 0,
      total_processed: 0,
      total_failed: 0,
      total_retried: 0,
      processing_times: []
    }
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::INFO
    @retry_queue = []
    @callbacks = {}
  end

  def start
    @running = true
    spawn_workers
    start_retry_processor
    start_metrics_reporter
    @logger.info("JobProcessor started with #{@num_workers} workers")
  end

  def stop
    @logger.info("Initiating graceful shutdown...")
    @running = false

    # B: Signal all waiting workers to wake up and check @running
    # But only signals ONE worker, not all
    @job_available.signal

    # Wait for workers to finish current jobs
    deadline = Time.now + SHUTDOWN_TIMEOUT
    @workers.each do |worker|
      remaining = deadline - Time.now
      if remaining > 0
        worker.join(remaining)
      else
        # B: Thread#kill is unsafe -- can leave mutex locked, data corrupted
        worker.kill
      end
    end

    # B: Not stopping the retry processor or metrics reporter threads
    @logger.info("Shutdown complete. Processed #{@metrics[:total_processed]} jobs.")
  end

  def enqueue(job)
    # B: No mutex -- reading @running and modifying @queue without synchronization
    return false unless @running

    if @queue.size >= MAX_QUEUE_SIZE
      @logger.warn("Queue full, rejecting #{job}")
      return false
    end

    @queue.push(job)
    @metrics[:total_enqueued] += 1

    # B: Signaling outside of mutex -- may be lost if no thread is waiting yet
    @job_available.signal
    true
  end

  def on_complete(&block)
    @callbacks[:complete] = block
  end

  def on_failure(&block)
    @callbacks[:failure] = block
  end

  def status
    {
      running: @running,
      queue_size: @queue.size,
      active_jobs: @active_jobs.size,
      # B: Returning reference to mutable internal set
      active_job_ids: @active_jobs,
      workers_alive: @workers.count(&:alive?),
      metrics: @metrics
    }
  end

  def cancel_job(job_id)
    # B: Not synchronized -- iterating @queue internals without lock
    @queue.to_a.reject! { |j| j.id == job_id }
    # B: Also doesn't cancel actively running jobs
  end

  def get_job(job_id)
    @processed_jobs[job_id]
  end

  private

  def spawn_workers
    @num_workers.times do |i|
      @workers << Thread.new do
        Thread.current.name = "worker-#{i}"
        worker_loop
      end
    end
  end

  def worker_loop
    while @running
      job = nil

      @mutex.synchronize do
        # B: Using 'if' instead of 'while' -- spurious wakeups will proceed with nil job
        if @queue.empty?
          @job_available.wait(@mutex, 1)
        end
        # B: No check for @running after waking up -- will try to pop from queue during shutdown
        job = @queue.pop
      end

      # B: job can be nil if woken spuriously or during shutdown
      process_job(job)
    end
  end

  def process_job(job)
    job.status = :running
    job.started_at = Time.now
    job.attempts += 1
    @active_jobs.add(job.id)

    @logger.info("Processing #{job} on #{Thread.current.name}")

    begin
      result = execute_job(job)
      job.status = :completed
      job.completed_at = Time.now

      # B: Not synchronized -- concurrent hash writes
      @processed_jobs[job.id] = job
      @active_jobs.delete(job.id)

      # B: Not synchronized -- race on counter increment
      @metrics[:total_processed] += 1
      # B: Not synchronized -- race on array append
      @metrics[:processing_times] << (job.completed_at - job.started_at)

      fire_callback(:complete, job, result)

    rescue StandardError => e
      job.error = e.message
      @active_jobs.delete(job.id)

      if job.attempts < MAX_RETRIES
        job.status = :retry
        @metrics[:total_retried] += 1
        schedule_retry(job)
      else
        job.status = :failed
        @processed_jobs[job.id] = job
        @metrics[:total_failed] += 1
        fire_callback(:failure, job, e)
      end

    rescue Exception => e
      # B: Catching Exception is too broad -- catches SystemExit, Interrupt, etc.
      # This prevents clean shutdown via Ctrl+C
      @logger.error("Fatal error processing #{job}: #{e.message}")
      job.status = :failed
      @processed_jobs[job.id] = job
    end
  end

  def execute_job(job)
    case job.payload[:type]
    when :http_request
      # Simulate HTTP request
      sleep(rand(0.1..2.0))
      { status: 200, body: "OK" }
    when :db_query
      sleep(rand(0.05..0.5))
      { rows: rand(100) }
    when :email
      sleep(rand(0.1..1.0))
      # B: Simulating occasional failure, but rand is not thread-safe on older Rubys
      raise "SMTP connection refused" if rand < 0.3
      { delivered: true }
    when :compute
      # CPU-bound work -- GVL means this blocks all other workers
      (1..1_000_000).sum
    else
      raise "Unknown job type: #{job.payload[:type]}"
    end
  end

  def schedule_retry(job)
    delay = RETRY_BACKOFF_BASE ** job.attempts
    retry_at = Time.now + delay

    # B: Not synchronized -- concurrent array modification
    @retry_queue << { job: job, retry_at: retry_at }

    @logger.info("Scheduling retry for #{job} in #{delay}s")
  end

  def start_retry_processor
    Thread.new do
      loop do
        sleep(1)

        # B: Not synchronized -- reading and modifying @retry_queue from another thread
        now = Time.now
        ready = @retry_queue.select { |entry| entry[:retry_at] <= now }

        ready.each do |entry|
          @retry_queue.delete(entry)  # B: Modifying array during iteration context
          enqueue(entry[:job])
        end
      end
      # B: No rescue -- unhandled exception silently kills this thread
    end
  end

  def start_metrics_reporter
    Thread.new do
      loop do
        sleep(10)

        # B: Reading metrics without synchronization
        times = @metrics[:processing_times]
        if times.any?
          avg = times.sum / times.length
          p50 = percentile(times, 50)
          p99 = percentile(times, 99)

          @logger.info(
            "Metrics: processed=#{@metrics[:total_processed]}, " \
            "failed=#{@metrics[:total_failed]}, " \
            "avg=#{avg.round(3)}s, p50=#{p50.round(3)}s, p99=#{p99.round(3)}s"
          )
        end

        # B: Never clears processing_times -- unbounded memory growth
      end
    end
  end

  def percentile(array, pct)
    # B: sort! mutates the original metrics array -- corrupts data for other readers
    sorted = array.sort!
    index = (pct / 100.0 * sorted.length).ceil - 1
    sorted[[index, 0].max]
  end

  def fire_callback(event, job, data)
    callback = @callbacks[event]
    # B: Callback runs in the worker thread -- if it raises, it kills the worker
    # B: If callback is slow, it blocks the worker from processing other jobs
    callback.call(job, data) if callback
  end
end

# ============================================================
# Job Scheduler (Cron-like)
# ============================================================

class JobScheduler
  def initialize(processor)
    @processor = processor
    @schedules = []
    @running = false
  end

  def every(interval, payload, priority: 0)
    @schedules << {
      interval: interval,
      payload: payload,
      priority: priority,
      last_run: nil
    }
  end

  def start
    @running = true

    # B: Spawns a thread per schedule -- wasteful and no join on stop
    @schedules.each do |schedule|
      Thread.new do
        while @running
          # B: No synchronization on schedule[:last_run]
          schedule[:last_run] = Time.now
          job = Job.new(
            # B: Using object_id for job ID -- can collide after GC reclaims objects
            "scheduled-#{schedule.object_id}-#{Time.now.to_i}",
            schedule[:payload],
            priority: schedule[:priority]
          )
          @processor.enqueue(job)
          sleep(schedule[:interval])
          # B: sleep is not interruptible -- stop takes up to interval seconds
        end
      end
    end
  end

  def stop
    @running = false
    # B: Doesn't join or kill the schedule threads
    # They will keep running until their sleep completes
  end
end

# ============================================================
# Dead Letter Queue
# ============================================================

class DeadLetterQueue
  def initialize
    @jobs = []
    @max_size = 10_000
  end

  def add(job)
    # B: Not thread-safe -- called from worker threads
    if @jobs.length >= @max_size
      # B: Silently drops oldest job without logging
      @jobs.shift
    end
    @jobs << job
  end

  def retry_all(processor)
    # B: Not thread-safe
    # B: Modifying @jobs while potentially being written to by workers
    jobs_to_retry = @jobs.dup
    @jobs.clear

    jobs_to_retry.each do |job|
      job.attempts = 0
      job.status = :pending
      processor.enqueue(job)
    end
  end

  def size
    @jobs.length
  end

  # B: Returns mutable internal reference
  def all
    @jobs
  end
end

# ============================================================
# Initialization Example
# ============================================================

def main
  processor = JobProcessor.new(num_workers: MAX_WORKERS)
  dlq = DeadLetterQueue.new

  processor.on_complete do |job, result|
    puts "Completed: #{job} => #{result}"
  end

  processor.on_failure do |job, error|
    puts "Failed: #{job} => #{error.message}"
    dlq.add(job)
  end

  processor.start

  # Enqueue some jobs
  50.times do |i|
    job_type = [:http_request, :db_query, :email, :compute].sample
    processor.enqueue(
      Job.new(i, { type: job_type, data: "payload-#{i}" }, priority: rand(1..10))
    )
  end

  # Let it run
  sleep(15)

  # Check status
  puts processor.status.to_json

  # Shutdown
  processor.stop

  puts "DLQ size: #{dlq.size}"
  puts "Final metrics: #{processor.metrics}"
end

main if __FILE__ == $PROGRAM_NAME
