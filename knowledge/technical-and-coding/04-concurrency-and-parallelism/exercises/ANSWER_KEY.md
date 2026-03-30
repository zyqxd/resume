# Answer Key -- Concurrent Job Processor

---

## Race Conditions

### 1. `enqueue` reads `@running` and modifies `@queue` without mutex (Lines ~155-165)
**Severity: P0 -- data corruption**

Multiple threads calling `enqueue` concurrently can corrupt the priority queue heap. The `@running` check also races with `stop`.

```ruby
# BUG
def enqueue(job)
  return false unless @running
  @queue.push(job)     # unsynchronized heap modification
  @metrics[:total_enqueued] += 1  # unsynchronized counter
  @job_available.signal  # signal outside mutex
  true
end

# FIX
def enqueue(job)
  @mutex.synchronize do
    return false unless @running
    return false if @queue.size >= MAX_QUEUE_SIZE

    @queue.push(job)
    @metrics[:total_enqueued] += 1
    @job_available.signal  # signal inside mutex
  end
  true
end
```

### 2. `@metrics` counters modified without synchronization (Lines ~223, 226, 238, 243)
**Severity: P1 -- lost updates**

`total_processed += 1` is a read-modify-write: three operations that can interleave. Under load, the counts will drift from reality.

```ruby
# FIX: Either use the existing @mutex for all metric updates,
# or use Concurrent::AtomicFixnum for each counter
@mutex.synchronize { @metrics[:total_processed] += 1 }
```

### 3. `@metrics[:processing_times]` array appended without synchronization (Line ~227)
**Severity: P1 -- corrupted array**

Ruby's Array is not thread-safe. Concurrent pushes can corrupt internal state.

```ruby
# FIX: synchronize or use a thread-safe queue for times
@mutex.synchronize { @metrics[:processing_times] << duration }
```

### 4. `@processed_jobs` hash written without synchronization (Lines ~222, 244, 250)
**Severity: P1 -- corrupted hash**

Multiple workers write to the same hash concurrently. Ruby's Hash is not thread-safe for concurrent writes.

```ruby
# FIX
@mutex.synchronize { @processed_jobs[job.id] = job }
```

### 5. `@active_jobs` Set modified without synchronization (Lines ~213, 224, 236)
**Severity: P1 -- corrupted set**

`Set#add` and `Set#delete` from multiple threads without locking.

```ruby
# FIX: wrap in mutex or use Concurrent::Set from concurrent-ruby
@mutex.synchronize { @active_jobs.add(job.id) }
```

### 6. `@retry_queue` modified from multiple threads (Lines ~258, 270-277)
**Severity: P1 -- corrupted array, lost retries**

Worker threads append to `@retry_queue` (via `schedule_retry`), while the retry processor thread reads and modifies it.

```ruby
# FIX: use a separate mutex or Thread::Queue for retry_queue
```

### 7. `process_job` called with nil job after spurious wakeup (Lines ~192-198)
**Severity: P0 -- NoMethodError crash**

`worker_loop` uses `if` instead of `while` for the condition variable wait. Spurious wakeups (or `signal` without a new job) cause `pop` to return nil, then `process_job(nil)` crashes on `nil.status = :running`.

```ruby
# BUG
if @queue.empty?
  @job_available.wait(@mutex, 1)
end
job = @queue.pop

# FIX
while @queue.empty? && @running
  @job_available.wait(@mutex, 1)
end
return unless @running && !@queue.empty?
job = @queue.pop
```

### 8. `percentile` mutates the original array with `sort!` (Line ~300)
**Severity: P1 -- data corruption**

`array.sort!` sorts the `@metrics[:processing_times]` array in place. If a worker appends to it concurrently, the sort corrupts. Also, the sorted order persists, so subsequent appends are out of position.

```ruby
# BUG
sorted = array.sort!  # mutates original

# FIX
sorted = array.dup.sort  # sort a copy
```

---

## Deadlock Risks

### 9. `@job_available.signal` in `stop` only wakes ONE worker (Line ~143)
**Severity: P0 -- shutdown hangs**

`signal` wakes one thread. With N workers waiting on the condition variable, N-1 will never wake up and shutdown will block until timeout, then forcibly kill them.

```ruby
# BUG
@job_available.signal

# FIX
@job_available.broadcast  # wake ALL waiting threads
```

### 10. `ConditionVariable#signal` called outside mutex in `enqueue` (Line ~164)
**Severity: P1 -- lost signals**

The Ruby docs specify that `signal` should be called with the mutex held. Signaling outside the mutex creates a window where the signal is lost if no thread is currently in `wait`.

```ruby
# FIX: move signal inside mutex.synchronize block
```

---

## Resource Leaks & Lifecycle Issues

### 11. `Thread#kill` used as shutdown fallback (Line ~151)
**Severity: P0 -- data corruption**

`Thread#kill` (and `Thread#raise`) can interrupt a thread at any point, including while holding a mutex. This can leave the mutex locked forever, corrupting shared state.

```ruby
# FIX: Never use Thread#kill. Instead, set a flag and let threads exit naturally.
# If a thread is truly stuck, it is a bug in the thread's code.
```

### 12. Retry processor thread is never stopped (Line ~152)
**Severity: P1 -- resource leak**

`stop` sets `@running = false` but the retry processor thread loops with `loop do` and checks nothing. It runs forever after shutdown.

```ruby
# FIX: check @running in the retry loop
while @running
  sleep(1)
  # ...
end
```

### 13. Metrics reporter thread is never stopped (Line ~152)
**Severity: P1 -- resource leak**

Same issue as retry processor. The metrics thread also runs forever.

### 14. `@metrics[:processing_times]` grows unbounded (Line ~292)
**Severity: P1 -- memory leak**

Every completed job appends its processing time to this array. In a long-running system, this will consume unbounded memory.

```ruby
# FIX: keep a rolling window or use a streaming percentile algorithm
# Simple approach: keep only the last 10,000 entries
```

### 15. Scheduler threads are never joined on stop (Line ~343)
**Severity: P2 -- resource leak**

`JobScheduler#stop` sets `@running = false` but does not join the schedule threads. They run until their `sleep` completes.

```ruby
# FIX: store thread references and join them
def stop
  @running = false
  @threads.each { |t| t.join(5) }
end
```

### 16. No rescue in retry processor thread (Lines ~268-280)
**Severity: P1 -- silent thread death**

If any exception occurs in the retry processor, the thread dies silently. Retries stop working with no log message.

```ruby
# FIX: wrap in begin/rescue with logging
begin
  # ... loop body ...
rescue => e
  @logger.error("Retry processor error: #{e.message}")
  retry  # or break if unrecoverable
end
```

### 17. No rescue in metrics reporter thread
**Severity: P2 -- silent thread death**

Same issue as retry processor.

---

## Design Flaws

### 18. `to_a` returns mutable reference to internal heap (Line ~86)
**Severity: P1 -- encapsulation breach**

`cancel_job` calls `@queue.to_a.reject!` which mutates the heap array directly, bypassing the heap invariant. After cancellation, the priority queue is in an invalid state.

```ruby
# FIX: return a copy, or implement cancel properly
def to_a
  @heap.dup
end

# Better: implement cancel_job using a lazy deletion flag
```

### 19. `cancel_job` does not cancel running jobs (Line ~175)
**Severity: P2 -- incomplete feature**

Cancel only removes from the queue. If the job is already being processed, it continues.

```ruby
# FIX: add a cancellation token (AtomicBoolean) that workers check periodically
```

### 20. `status` returns mutable `@active_jobs` set (Line ~170)
**Severity: P2 -- encapsulation breach**

External code can mutate the set, corrupting internal state.

```ruby
# FIX
active_job_ids: @active_jobs.dup
```

### 21. `DeadLetterQueue` is not thread-safe (Lines ~354-385)
**Severity: P1 -- data corruption**

Called from worker threads (via callback) with no synchronization.

```ruby
# FIX: add a mutex
def add(job)
  @mutex.synchronize do
    @jobs.shift if @jobs.length >= @max_size
    @jobs << job
  end
end
```

### 22. `DeadLetterQueue#all` returns mutable reference (Line ~384)
**Severity: P2 -- encapsulation breach**

### 23. Callback execution in worker thread (Lines ~304-308)
**Severity: P1 -- worker thread poisoning**

If a callback raises an exception, it propagates up through `process_job` and is caught by the broad `rescue Exception`, but the job is then incorrectly marked as failed rather than retried.

If a callback is slow (e.g., sends an HTTP request), it blocks the worker from processing other jobs.

```ruby
# FIX: run callbacks in a separate thread, or wrap in rescue
def fire_callback(event, job, data)
  callback = @callbacks[event]
  return unless callback

  begin
    callback.call(job, data)
  rescue => e
    @logger.error("Callback error for #{event} on #{job}: #{e.message}")
  end
end
```

### 24. `rescue Exception` catches Interrupt and SystemExit (Line ~247)
**Severity: P0 -- prevents clean shutdown**

Catching `Exception` instead of `StandardError` means Ctrl+C (`Interrupt`) and `exit` (`SystemExit`) are caught and swallowed. The process becomes unkillable via normal signals.

```ruby
# FIX: only rescue StandardError (which is what bare `rescue` does)
# If you need to catch everything, re-raise Interrupt and SystemExit
rescue Exception => e
  raise if e.is_a?(Interrupt) || e.is_a?(SystemExit)
  # handle other exceptions
end
```

### 25. `object_id` used for job IDs in scheduler (Line ~333)
**Severity: P2 -- ID collision**

After GC reclaims a schedule hash, its `object_id` can be reused. Combined with timestamp collision (same second), IDs can collide.

```ruby
# FIX: use SecureRandom.uuid or an atomic counter
```

### 26. CPU-bound `:compute` jobs block all workers due to GVL (Line ~263)
**Severity: P1 -- queue starvation**

The `execute_job` method includes CPU-bound work (`(1..1_000_000).sum`). Under MRI's GVL, this blocks all other Ruby threads. If multiple compute jobs are queued, I/O-bound jobs starve.

```ruby
# FIX: either forbid CPU-bound jobs in the thread pool,
# offload them to Ractors or child processes,
# or add periodic GVL-release points (Thread.pass is insufficient)
```

### 27. Retry processor modifies array during conceptual iteration (Lines ~273-276)
**Severity: P1 -- skipped retries**

`@retry_queue.select` then `@retry_queue.delete` in a loop. Deleting elements shifts indices, potentially skipping entries.

```ruby
# FIX: partition instead
ready, @retry_queue = @retry_queue.partition { |e| e[:retry_at] <= now }
ready.each { |entry| enqueue(entry[:job]) }
```

### 28. `sleep` in scheduler is not interruptible (Line ~338)
**Severity: P2 -- slow shutdown**

`sleep(interval)` blocks for the full interval before checking `@running`. If interval is 60 seconds, shutdown takes up to 60 seconds.

```ruby
# FIX: use a shorter sleep in a loop, or use ConditionVariable#wait with timeout
remaining = schedule[:interval]
while remaining > 0 && @running
  sleep([remaining, 1].min)
  remaining -= 1
end
```

### 29. Queue size check in `enqueue` is racy (Line ~159)
**Severity: P2 -- queue overflow**

`@queue.size >= MAX_QUEUE_SIZE` is checked without holding the mutex. Multiple threads can pass the check simultaneously and all push, exceeding the limit.

### 30. `worker_loop` does not check `@running` after waking (Line ~196)
**Severity: P1 -- processes job during shutdown**

After `@job_available.wait` returns (from broadcast during shutdown), the worker does not re-check `@running` and proceeds to pop and process a job.

```ruby
# FIX: check @running before popping
while @queue.empty? && @running
  @job_available.wait(@mutex, 1)
end
break unless @running
```

### 31. `DeadLetterQueue#retry_all` is not atomic (Lines ~371-379)
**Severity: P2 -- lost jobs**

Between `dup` and `clear`, new jobs can be added. Those new jobs are lost (cleared but not in the dup).

```ruby
# FIX: synchronize
@mutex.synchronize do
  jobs_to_retry = @jobs.dup
  @jobs.clear
end
```

### 32. No backpressure from workers to enqueue (Design)
**Severity: P2 -- design flaw**

When all workers are busy and the queue is at capacity, `enqueue` silently rejects jobs. There is no mechanism to apply backpressure to the caller (block, return a future, or retry later).

---

## Summary by Category

| Category | Count | P0 | P1 | P2 |
|---|---|---|---|---|
| Race Conditions | 8 | 1 | 6 | 1 |
| Deadlock / Liveness | 2 | 1 | 1 | 0 |
| Resource Leaks | 6 | 1 | 3 | 2 |
| Design Flaws | 11 | 1 | 4 | 6 |
| Error Handling | 3 | 1 | 1 | 1 |
| GVL / Performance | 2 | 0 | 1 | 1 |
| **Total** | **32** | **5** | **16** | **11** |

---

## Architectural Suggestions

1. **Use `Thread::Queue` or `Thread::SizedQueue` instead of custom PriorityQueue.** These are thread-safe by design. For priority support, wrap them or use `concurrent-ruby`'s priority queue.

2. **Separate the mutex for metrics from the mutex for the queue.** One global mutex creates contention. Use fine-grained locking: one for the queue, one for metrics, one for the retry queue.

3. **Use `concurrent-ruby` gem.** It provides `Concurrent::AtomicFixnum`, `Concurrent::Map`, `Concurrent::Array`, thread pools (`Concurrent::ThreadPoolExecutor`), and futures. There is no reason to build this from scratch.

4. **Implement a CancellationToken pattern.** Each job gets a token. Workers check it periodically. Cancel sets the flag. This allows cancellation of running jobs.

5. **Use a proper shutdown protocol.** Instead of `@running = false` + broadcast, use a poison pill: push N `:shutdown` sentinels to the queue (one per worker). Each worker exits when it pops a sentinel. This guarantees all workers wake up and exit.

6. **Add structured logging and error reporting.** Log job ID, worker ID, duration, and error details in a parseable format (JSON). This makes debugging production issues feasible.

7. **Offload CPU-bound work to processes or Ractors.** The thread pool should only handle I/O-bound work under MRI. CPU-bound work should go to a separate process pool.
