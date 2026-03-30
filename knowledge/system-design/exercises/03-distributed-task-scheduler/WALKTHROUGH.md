# Walkthrough: Design a Distributed Task Scheduler

## Step 1: Clarify Requirements and Scope

Key clarifications:
- What precision for scheduling? (Within 1 second of scheduled time -- not sub-millisecond)
- Are tasks short-lived? (Yes, < 5 minutes. Not a workflow engine.)
- Exactly-once or at-least-once execution? (At-least-once with idempotency support -- exactly-once is impractical in distributed systems)
- Do tasks have dependencies on each other? (Simple DAG dependencies -- task B waits for task A)
- Multi-tenant? (Yes -- 1000 tenants, isolation required)

---

## Step 2: High-Level Architecture

```
+-------------------+
|  Scheduler API    |  (CRUD for tasks, status queries)
+--------+----------+
         |
+--------v----------+
|   Task Store      |  (PostgreSQL -- source of truth for task definitions)
+--------+----------+
         |
+--------v----------+
|  Tick Service     |  (polls for due tasks, enqueues them)
|  (partitioned)    |
+--------+----------+
         |
+--------v----------+
|  Execution Queue  |  (Kafka / SQS -- decouples scheduling from execution)
+--------+----------+
         |
+--------v----------+
|  Worker Pool      |  (executes tasks, reports results)
+--------+----------+
         |
+--------v----------+
|  Result Store     |  (task execution history, status)
+-------------------+
```

### Core Components

1. **Scheduler API** -- REST/gRPC API for creating, updating, canceling, and querying tasks.
2. **Task Store** -- PostgreSQL database holding task definitions (schedule, payload, retry policy, status).
3. **Tick Service** -- the heart of the scheduler. Periodically scans for tasks that are due and enqueues them for execution. This is the component that must be distributed and fault-tolerant.
4. **Execution Queue** -- message queue (Kafka or SQS) that buffers tasks between scheduling and execution. Provides durability and load leveling.
5. **Worker Pool** -- processes that consume from the execution queue and execute the task logic (HTTP callback, gRPC call, or inline function).
6. **Result Store** -- records execution outcomes (success/failure, duration, error details).

---

## Step 3: Task Data Model

```sql
CREATE TABLE tasks (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id      UUID NOT NULL,
  name           TEXT NOT NULL,
  schedule_type  TEXT NOT NULL,  -- 'one_time' or 'recurring'
  cron_expr      TEXT,           -- for recurring tasks
  next_fire_at   TIMESTAMPTZ NOT NULL,
  payload        JSONB NOT NULL,
  callback_url   TEXT NOT NULL,  -- where to deliver the task
  retry_policy   JSONB NOT NULL DEFAULT '{"max_retries": 3, "backoff": "exponential"}',
  status         TEXT NOT NULL DEFAULT 'active',  -- active, paused, completed, cancelled
  partition_key  INT NOT NULL,   -- for tick service partitioning
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Critical index: the tick service queries by this
CREATE INDEX idx_tasks_due ON tasks (partition_key, next_fire_at)
  WHERE status = 'active';

CREATE TABLE task_executions (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id        UUID NOT NULL REFERENCES tasks(id),
  scheduled_at   TIMESTAMPTZ NOT NULL,
  started_at     TIMESTAMPTZ,
  completed_at   TIMESTAMPTZ,
  status         TEXT NOT NULL,  -- 'pending', 'running', 'succeeded', 'failed', 'dlq'
  attempt        INT NOT NULL DEFAULT 1,
  error_details  TEXT,
  idempotency_key UUID NOT NULL,  -- for exactly-once delivery
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_executions_task ON task_executions (task_id, created_at DESC);
```

### Partition Key

The `partition_key` is a hash of the task ID modulo the number of tick service partitions. This allows the tick service to be horizontally partitioned -- each instance only scans its own partition.

---

## Step 4: The Tick Service (Core Scheduling Engine)

The tick service is the most critical and complex component. It must:
1. Efficiently find tasks that are due
2. Enqueue them exactly once
3. Scale horizontally
4. Handle failures without missing or double-firing tasks

### Design: Partitioned Polling

Divide the task space into N partitions (e.g., 64). Each tick service instance is responsible for a subset of partitions.

```
Tick Service Instance 1: partitions [0-15]
Tick Service Instance 2: partitions [16-31]
Tick Service Instance 3: partitions [32-47]
Tick Service Instance 4: partitions [48-63]
```

**Partition assignment** is managed via a coordination service (etcd / ZooKeeper). When an instance joins or leaves, partitions are rebalanced (similar to Kafka consumer group rebalancing).

### Polling Loop

Each tick service instance runs a tight loop:

```ruby
class TickService
  POLL_INTERVAL = 1.second
  BATCH_SIZE = 1000

  def run(partitions:)
    loop do
      partitions.each do |partition|
        due_tasks = fetch_due_tasks(partition, BATCH_SIZE)
        due_tasks.each do |task|
          enqueue_for_execution(task)
          advance_next_fire_time(task)
        end
      end
      sleep(POLL_INTERVAL)
    end
  end

  private

  def fetch_due_tasks(partition, limit)
    Task.where(partition_key: partition, status: 'active')
        .where('next_fire_at <= ?', Time.now)
        .order(:next_fire_at)
        .limit(limit)
  end

  def enqueue_for_execution(task)
    execution = TaskExecution.create!(
      task_id: task.id,
      scheduled_at: task.next_fire_at,
      status: 'pending',
      idempotency_key: generate_idempotency_key(task)
    )

    queue.publish(
      topic: "task-executions",
      key: task.id,  # partition by task for ordering
      payload: { execution_id: execution.id, task: task.payload, callback_url: task.callback_url }
    )
  end

  def advance_next_fire_time(task)
    if task.schedule_type == 'recurring'
      task.update!(next_fire_at: CronParser.next(task.cron_expr, after: task.next_fire_at))
    else
      task.update!(status: 'completed')
    end
  end

  def generate_idempotency_key(task)
    # Deterministic: same task + same scheduled time = same key
    # Prevents double-enqueue if tick service crashes and retries
    Digest::UUID.uuid_v5("#{task.id}:#{task.next_fire_at.iso8601}")
  end
end
```

### Preventing Double-Firing

The critical invariant: a task must not be fired twice for the same scheduled time.

**Strategy 1: Optimistic locking on `next_fire_at`**

```sql
UPDATE tasks
SET next_fire_at = :new_next_fire_at,
    updated_at = now()
WHERE id = :task_id
  AND next_fire_at = :current_next_fire_at;
-- If 0 rows affected, another instance already processed this task
```

**Strategy 2: Idempotency key on task executions**

```sql
-- Unique constraint prevents duplicate executions
CREATE UNIQUE INDEX idx_executions_idempotency ON task_executions (idempotency_key);
```

The idempotency key is deterministically generated from (task_id, scheduled_time). If two tick service instances try to create the same execution, the second one hits a unique constraint violation and skips.

---

## Step 5: Task Execution (Workers)

### Worker Design

```ruby
class TaskWorker
  CONCURRENCY = 20

  def run
    queue.subscribe(topic: "task-executions", group: "workers") do |message|
      execution = TaskExecution.find(message.execution_id)
      next if execution.status != 'pending'

      execution.update!(status: 'running', started_at: Time.now)

      begin
        result = execute_task(message.callback_url, message.payload, execution.idempotency_key)
        execution.update!(status: 'succeeded', completed_at: Time.now)
      rescue StandardError => e
        handle_failure(execution, e)
      end
    end
  end

  private

  def execute_task(callback_url, payload, idempotency_key)
    # Deliver the task via HTTP callback with idempotency key
    HTTP.post(callback_url, json: payload, headers: {
      "Idempotency-Key" => idempotency_key,
      "X-Task-Execution-Id" => execution.id
    })
  end

  def handle_failure(execution, error)
    task = execution.task
    policy = task.retry_policy

    if execution.attempt < policy["max_retries"]
      # Re-enqueue with backoff
      delay = calculate_backoff(execution.attempt, policy)
      queue.publish(
        topic: "task-executions",
        key: task.id,
        payload: { execution_id: execution.id },
        delay: delay
      )
      execution.update!(status: 'pending', attempt: execution.attempt + 1)
    else
      execution.update!(status: 'dlq', error_details: error.message, completed_at: Time.now)
      queue.publish(topic: "task-executions-dlq", payload: { execution_id: execution.id })
      notify_tenant(task.tenant_id, execution)
    end
  end
end
```

### Execution Guarantees

- **At-least-once delivery:** If a worker crashes mid-execution, the message is redelivered (visibility timeout in SQS, or uncommitted offset in Kafka).
- **Idempotency:** The idempotency key is passed to the callback URL. The receiving service must handle duplicate deliveries.
- **Timeout:** If a task runs longer than its configured timeout, the worker kills it and treats it as a failure.

---

## Step 6: Task Dependencies (DAG)

For simple dependencies (task B runs after task A), use a parent-child model:

```sql
CREATE TABLE task_dependencies (
  task_id    UUID NOT NULL REFERENCES tasks(id),
  depends_on UUID NOT NULL REFERENCES tasks(id),
  PRIMARY KEY (task_id, depends_on)
);
```

### Execution Flow

```
Task A completes successfully
  -> Worker publishes "task_completed" event
  -> Dependency Resolver consumes event
  -> Checks: does any task depend on A?
    -> Task B depends on A
    -> Are all of B's dependencies satisfied? (check task_executions)
      -> Yes: enqueue B for execution
      -> No: wait for remaining dependencies
```

**Cycle detection:** When creating dependencies via the API, run a topological sort to detect cycles. Reject the request if a cycle is found.

**Failure propagation:** If task A fails (after exhausting retries), mark dependent tasks as "blocked" and notify the tenant.

---

## Step 7: Multi-Tenant Isolation

### Noisy Neighbor Problem

One tenant scheduling 1M tasks should not delay another tenant's critical tasks.

**Queue-level isolation:** Use per-tenant queues or priority queues. Critical tenants get dedicated queue capacity.

**Rate limiting:** Limit task creation and execution rates per tenant:
```
Tenant tier: Basic   -> 1000 tasks/min execution limit
Tenant tier: Pro     -> 10000 tasks/min
Tenant tier: Enterprise -> custom
```

**Worker pool isolation:** Dedicate worker capacity per tenant tier. Or use fair scheduling (round-robin across tenants) to prevent one tenant from consuming all worker capacity.

### Partition Assignment

Assign partitions considering tenant distribution. If one tenant has 80% of tasks, their tasks should be spread across multiple partitions (the partition key is based on task ID, not tenant ID).

---

## Step 8: Failure Scenarios and Recovery

### Tick Service Instance Crashes

1. The coordination service (etcd) detects the heartbeat timeout
2. Partitions owned by the crashed instance are reassigned to surviving instances
3. Surviving instances start scanning the reassigned partitions
4. Tasks that were due during the gap are picked up on the next poll (they are past due but still have `next_fire_at <= now()`)
5. Idempotency keys prevent double-firing if the crashed instance had already enqueued some tasks

**Recovery time:** Heartbeat timeout (10-30s) + rebalance time (5-10s) = 15-40s of potential delay.

### Worker Crashes Mid-Execution

1. The message's visibility timeout expires (SQS) or consumer offset is not committed (Kafka)
2. The message is redelivered to another worker
3. The receiving service uses the idempotency key to deduplicate

### Database (Task Store) Failure

1. PostgreSQL with synchronous replication to a standby
2. Automatic failover via Patroni (< 30s)
3. Tick service retries database queries with backoff during the failover window
4. No tasks are lost (WAL ensures durability)

### Queue Failure

1. Kafka: replicated topic (replication factor 3). Can survive 2 broker failures.
2. SQS: fully managed, multi-AZ by default.
3. If the queue is unavailable, tick service backs up (tasks accumulate as "due but not enqueued"). They catch up after queue recovery.

---

## Step 9: Scale Estimates

### Tick Service Load

- 10M tasks, assume 1M are due in any given minute (mix of cron schedules)
- 64 partitions, ~15K tasks per partition per minute
- Each poll scans ~250 tasks (1 second interval, 15K tasks/60 seconds)
- PostgreSQL index scan on (partition_key, next_fire_at): < 10ms for 250 rows

### Queue Throughput

- 100K task executions per minute = ~1700 messages/second
- Well within Kafka or SQS capabilities

### Worker Pool Sizing

- 100K tasks/min, average 30 seconds each
- Concurrent tasks: 100K/60 * 30 = 50K concurrent
- At 20 threads per worker: 50K / 20 = 2500 worker instances

---

## Key Decisions and Trade-offs

| Decision | Choice | Alternative | Why |
|---|---|---|---|
| Scheduling approach | Partitioned polling | Time-wheel / delay queue | Simpler, works with standard DB, good enough precision |
| Task store | PostgreSQL | Redis sorted sets | Durability, ACID, rich query for status/history |
| Execution queue | Kafka | SQS | Ordering per task, replay capability, high throughput |
| Coordination | etcd (Raft) | ZooKeeper | Simpler API, Kubernetes-native |
| Idempotency | Deterministic key from (task_id, scheduled_time) | Distributed lock per execution | Simpler, stateless, works across retries |
| Dependencies | Event-driven resolution | Polling for dependency status | Lower latency, no wasted polls |

---

## Common Mistakes to Avoid

1. **Single scheduler instance.** A single scheduler is a single point of failure. The tick service must be distributed and partition-aware.

2. **Using wall clock time without caution.** Clock skew between tick service instances can cause tasks to fire early or late. Use database time (`now()` on the PostgreSQL server) as the authoritative clock, not the application server's clock.

3. **Scanning all tasks on every tick.** With 10M tasks, a full table scan is unacceptable. Use the partitioned index on `(partition_key, next_fire_at)` to limit each scan to a small subset.

4. **Ignoring the double-fire problem.** If two tick service instances scan overlapping partitions (during rebalancing), a task could be enqueued twice. Idempotency keys and optimistic locking are essential.

5. **No backpressure.** If the worker pool is overwhelmed, the queue grows unbounded. Implement rate limiting per tenant and auto-scaling for workers based on queue depth.

6. **Mixing scheduling and execution.** The tick service should only enqueue tasks, not execute them. Separating scheduling from execution allows independent scaling and prevents slow tasks from blocking the scheduler.

7. **Forgetting recurring task advancement.** After firing a recurring task, immediately compute and store the next fire time. If the tick service crashes before advancing, the same fire time will be picked up again -- but the idempotency key prevents double execution.

---

## Related Topics

- [[../../distributed-systems-fundamentals/index|Distributed Systems]] -- consensus, leader election, partition assignment
- [[../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- retries, idempotency, circuit breakers
- [[../../async-processing/index|Async Processing]] -- message queues, worker pools, DLQs, Temporal
- [[../../databases-and-storage/index|Databases & Storage]] -- PostgreSQL indexing, time-based queries
- [[../../scaling-writes/index|Scaling Writes]] -- partitioning the task store
