# Concurrency & Parallelism

Concurrency and parallelism are critical topics for staff-level backend interviews. The distinction matters: concurrency is about managing multiple tasks that can be in progress simultaneously (interleaved execution), while parallelism is about executing multiple tasks at the exact same time on multiple cores. You can have concurrency without parallelism (single-core OS, cooperative multitasking) and parallelism without concurrency (SIMD instructions).

Staff engineers are expected to reason about race conditions, deadlocks, and memory visibility without hand-holding. Interviewers will ask you to design thread-safe data structures, identify bugs in concurrent code, and articulate the trade-offs between different synchronization primitives. For Ruby-focused roles, you must understand the GVL and know when to reach for Ractors, Fibers, or external concurrency tools.

---

## Threads

A thread is the smallest unit of execution scheduled by the OS. Threads within a process share the same memory space, which makes communication easy but synchronization hard.

In Ruby (MRI/CRuby), threads are OS-native threads, but the Global VM Lock (GVL, formerly GIL) ensures only one thread executes Ruby code at a time. This means Ruby threads provide concurrency (useful for I/O-bound work) but not parallelism for CPU-bound work. JRuby and TruffleRuby do not have a GVL and provide true parallelism.

```ruby
# Basic thread creation and joining
threads = 5.times.map do |i|
  Thread.new(i) do |num|
    sleep(rand(0.1..0.5))  # simulate I/O
    puts "Thread #{num} done"
  end
end

threads.each(&:join)  # wait for all to finish
```

Key interview questions around threads:
- What happens if you forget to join? (The main thread may exit, killing child threads.)
- What is a daemon thread? (Ruby: thread dies when the main thread exits unless you join it.)
- How do you handle exceptions in threads? (Ruby silently swallows them by default; use `Thread.abort_on_exception = true` or `Thread#value` which re-raises.)

```ruby
# Exception handling in threads
Thread.abort_on_exception = true  # global: any thread exception kills the process

t = Thread.new do
  raise "something went wrong"
end

begin
  t.join  # or t.value -- both re-raise the exception in the joining thread
rescue => e
  puts "Caught: #{e.message}"
end
```

## Mutexes & Synchronization

A mutex (mutual exclusion) is the most basic synchronization primitive. It ensures only one thread can execute a critical section at a time. In Ruby, use `Mutex`.

```ruby
counter = 0
mutex = Mutex.new

threads = 10.times.map do
  Thread.new do
    1000.times do
      mutex.synchronize do
        counter += 1
      end
    end
  end
end

threads.each(&:join)
puts counter  # always 10000 with mutex, potentially less without
```

Beyond mutexes, know these primitives:

- **Read-Write Lock**: allows multiple concurrent readers but exclusive writers. Use when reads vastly outnumber writes. Ruby does not have a built-in RWLock but `concurrent-ruby` provides `Concurrent::ReadWriteLock`.
- **Semaphore**: a counter-based lock that allows N concurrent accesses. Useful for connection pools, rate limiting. Ruby: `Thread::Queue` can simulate, or use `Concurrent::Semaphore`.
- **Condition Variable**: allows threads to wait for a specific condition. Used with a mutex to avoid busy-waiting. Ruby: `ConditionVariable`.

```ruby
# Producer-consumer with condition variable
queue = []
mutex = Mutex.new
cv = ConditionVariable.new
max_size = 5

producer = Thread.new do
  20.times do |i|
    mutex.synchronize do
      cv.wait(mutex) while queue.size >= max_size  # wait if full
      queue << i
      puts "Produced: #{i}"
      cv.signal  # wake a consumer
    end
  end
end

consumer = Thread.new do
  20.times do
    mutex.synchronize do
      cv.wait(mutex) while queue.empty?  # wait if empty
      item = queue.shift
      puts "Consumed: #{item}"
      cv.signal  # wake the producer
    end
  end
end

[producer, consumer].each(&:join)
```

## Race Conditions

A race condition occurs when the correctness of a program depends on the timing of thread scheduling. They are notoriously hard to reproduce and debug because they are non-deterministic.

Classic categories:

**Check-then-act (TOCTOU):**
```ruby
# BROKEN: race between check and update
if !hash.key?(key)
  hash[key] = expensive_compute(key)
end
# Two threads could both see the key missing and both compute

# FIX: use mutex or atomic operation
mutex.synchronize do
  hash[key] ||= expensive_compute(key)
end
```

**Read-modify-write:**
```ruby
# BROKEN: counter += 1 is three operations (read, add, write)
counter += 1

# FIX: use mutex or atomic integer
mutex.synchronize { counter += 1 }
# Or: Concurrent::AtomicFixnum from concurrent-ruby
```

**Data race vs race condition:** A data race is when two threads access the same memory location concurrently and at least one is a write, with no synchronization. A race condition is a semantic bug where timing affects correctness. You can have a race condition without a data race (e.g., two synchronized operations in the wrong order) and a data race without a race condition (e.g., benign racy reads where any value is acceptable).

## Deadlocks

A deadlock occurs when two or more threads are each waiting for a resource held by another, creating a circular wait. The four Coffman conditions for deadlock are:

1. **Mutual exclusion**: resources cannot be shared
2. **Hold and wait**: a thread holds one resource while waiting for another
3. **No preemption**: resources cannot be forcibly taken
4. **Circular wait**: a cycle exists in the wait-for graph

Break any one condition to prevent deadlock. The most practical strategy is **lock ordering**: always acquire locks in a consistent global order.

```ruby
# DEADLOCK: inconsistent lock ordering
mutex_a = Mutex.new
mutex_b = Mutex.new

thread1 = Thread.new do
  mutex_a.synchronize do
    sleep(0.01)
    mutex_b.synchronize do
      puts "Thread 1 got both locks"
    end
  end
end

thread2 = Thread.new do
  mutex_b.synchronize do    # reversed order!
    sleep(0.01)
    mutex_a.synchronize do
      puts "Thread 2 got both locks"
    end
  end
end

# FIX: always acquire mutex_a before mutex_b
# Both threads should do: mutex_a.synchronize { mutex_b.synchronize { ... } }
```

Other deadlock prevention strategies:
- **Try-lock with timeout**: `mutex.try_lock` returns false instead of blocking. Retry or back off.
- **Lock-free data structures**: use atomic operations (CAS) to avoid locks entirely.
- **Resource hierarchy**: assign a numeric order to all locks. Always acquire in ascending order.

## Async Patterns

Asynchronous programming avoids blocking threads on I/O. Instead of waiting, you register a callback or continuation to handle the result when it arrives.

Ruby offers several async models:

**Thread pool with Queue:**
```ruby
work_queue = Thread::Queue.new
results = Thread::Queue.new

# Worker pool
workers = 4.times.map do
  Thread.new do
    while (task = work_queue.pop)
      break if task == :shutdown
      results << task.call
    end
  end
end

# Enqueue work
10.times { |i| work_queue << -> { i * i } }
4.times { work_queue << :shutdown }

workers.each(&:join)
results.close
puts results.to_a.inspect
```

**Event-driven (Reactor pattern):** Libraries like EventMachine and Async gem use a single-threaded event loop. Non-blocking I/O operations are multiplexed over a single thread using `select`/`epoll`/`kqueue`.

## The GVL (Global VM Lock)

The GVL (Global VM Lock, often still called GIL) is MRI Ruby's mechanism to protect internal C data structures. Only one thread can execute Ruby code at a time. However, the GVL is released during blocking I/O operations (file reads, network calls, `sleep`), C extensions that explicitly release it, and certain built-in methods.

This means:
- **I/O-bound work**: threads are effective. While one thread waits on a network response, others run.
- **CPU-bound work**: threads provide zero speedup on MRI. Use processes instead (fork, or use Ractors).

```ruby
require 'benchmark'
require 'net/http'

# I/O bound: threads help despite GVL
urls = ['https://example.com'] * 10

Benchmark.bm do |x|
  x.report("sequential") do
    urls.each { |url| Net::HTTP.get(URI(url)) }
  end

  x.report("threaded") do
    urls.map { |url| Thread.new { Net::HTTP.get(URI(url)) } }.each(&:join)
  end
end
# Threaded version is ~10x faster for I/O-bound work

# CPU bound: threads do NOT help on MRI
x.report("cpu-sequential") { 2.times { (1..10_000_000).sum } }
x.report("cpu-threaded") do
  2.times.map { Thread.new { (1..10_000_000).sum } }.each(&:join)
end
# Same speed (or slightly slower due to context switching)
```

## Ractors (Ruby 3.0+)

Ractors are Ruby's answer to true parallelism. Each Ractor has its own GVL, so multiple Ractors can execute Ruby code in parallel on multiple cores. Communication is via message passing (send/receive), not shared memory.

Key constraints:
- Objects shared between Ractors must be deeply frozen (immutable) or transferred (moved, not copied).
- Most global state is not accessible from non-main Ractors.
- Not all gems are Ractor-safe (many use global mutable state).

```ruby
# CPU-bound parallelism with Ractors
ractors = 4.times.map do |i|
  Ractor.new(i) do |id|
    sum = (1..10_000_000).sum
    "Ractor #{id}: #{sum}"
  end
end

results = ractors.map(&:take)
puts results
# Actually runs in parallel on 4 cores
```

```ruby
# Producer-consumer with Ractors
pipe = Ractor.new do
  loop do
    msg = Ractor.receive
    break if msg == :done
    Ractor.yield(msg * 2)  # transform and forward
  end
end

# Send data
5.times { |i| pipe.send(i) }
5.times { puts pipe.take }
pipe.send(:done)
```

Ractors are still experimental (as of Ruby 3.3). Use them for CPU-intensive batch processing but not yet for production web serving.

## Fibers (Cooperative Concurrency)

Fibers are lightweight, cooperatively scheduled coroutines. Unlike threads, fibers never preempt -- they explicitly yield control. This makes them perfect for building generators, lazy sequences, and (with the Fiber Scheduler) async I/O.

```ruby
# Basic fiber as generator
fib = Fiber.new do
  a, b = 0, 1
  loop do
    Fiber.yield(a)
    a, b = b, a + b
  end
end

10.times { puts fib.resume }  # 0, 1, 1, 2, 3, 5, 8, 13, 21, 34
```

**Fiber Scheduler (Ruby 3.0+):** The Fiber Scheduler interface allows non-blocking I/O with fibers. The `async` gem implements a Fiber Scheduler that gives you Node.js-style async I/O with a synchronous-looking API.

```ruby
require 'async'

# Async I/O with fibers (using the async gem)
Async do
  # These run concurrently on a single thread via fibers
  5.times.map do |i|
    Async do
      # Non-blocking sleep (fiber yields, other fibers run)
      sleep(1)
      puts "Task #{i} done"
    end
  end.each(&:wait)
end
# All 5 complete in ~1 second, not 5
```

Fibers vs Threads:
- Fibers are cheaper (no OS thread overhead, ~4KB stack vs ~1MB for threads)
- Fibers have no race conditions (no preemption = no data races within a fiber scheduler)
- Fibers require explicit cooperation (blocking calls without scheduler support will block everything)
- Fibers cannot utilize multiple cores (single thread)

## Thread-Safe Data Structures

For interviews, you should be able to implement a thread-safe queue, a concurrent hash map, or a read-write lock.

```ruby
# Thread-safe bounded queue
class BoundedQueue
  def initialize(max_size)
    @queue = []
    @max_size = max_size
    @mutex = Mutex.new
    @not_empty = ConditionVariable.new
    @not_full = ConditionVariable.new
  end

  def enqueue(item)
    @mutex.synchronize do
      @not_full.wait(@mutex) while @queue.size >= @max_size
      @queue << item
      @not_empty.signal
    end
  end

  def dequeue
    @mutex.synchronize do
      @not_empty.wait(@mutex) while @queue.empty?
      item = @queue.shift
      @not_full.signal
      item
    end
  end

  def size
    @mutex.synchronize { @queue.size }
  end
end
```

```ruby
# Read-Write Lock implementation
class ReadWriteLock
  def initialize
    @mutex = Mutex.new
    @readers_cv = ConditionVariable.new
    @writers_cv = ConditionVariable.new
    @readers = 0
    @writers = 0
    @write_requests = 0
  end

  def read_lock
    @mutex.synchronize do
      @readers_cv.wait(@mutex) while @writers > 0 || @write_requests > 0
      @readers += 1
    end
  end

  def read_unlock
    @mutex.synchronize do
      @readers -= 1
      @writers_cv.signal if @readers == 0
    end
  end

  def write_lock
    @mutex.synchronize do
      @write_requests += 1
      @writers_cv.wait(@mutex) while @readers > 0 || @writers > 0
      @write_requests -= 1
      @writers += 1
    end
  end

  def write_unlock
    @mutex.synchronize do
      @writers -= 1
      @writers_cv.broadcast
      @readers_cv.broadcast
    end
  end
end
```

## Common Interview Questions

1. **Design a thread-safe LRU cache.** Combine a hash map with a doubly-linked list, protected by a read-write lock (reads are frequent, writes less so).

2. **Implement a rate limiter that works across threads.** Token bucket or sliding window with mutex. Discuss how this changes with multiple processes (need shared storage like Redis).

3. **What is a memory barrier/fence?** Ensures that memory operations before the barrier are visible to operations after it. In Ruby, mutex acquire/release acts as a memory barrier.

4. **Explain the dining philosophers problem.** Five philosophers, five forks. Demonstrate deadlock prevention via resource ordering or an arbitrator.

5. **How would you parallelize a map-reduce job in Ruby?** Fork workers for CPU-bound map phase (bypass GVL), use threads for I/O-bound reduce phase, or use Ractors for both.

---

## Exercises

- [[exercises/INSTRUCTIONS|Concurrent Job Processor]] -- Build a thread-safe job processing system with worker pool, priority queue, and graceful shutdown.

## Related Topics

- [[../01-data-structures-and-algorithms/index|Data Structures & Algorithms]] -- thread-safe data structures build on DSA fundamentals
- [[../03-api-design/index|API Design]] -- rate limiting and connection pooling require concurrency knowledge
- [[../system-design/index|System Design]] -- distributed systems extend concurrency across machines
