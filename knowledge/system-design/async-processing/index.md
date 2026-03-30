# Async Processing

Asynchronous processing decouples time-sensitive request handling from long-running, resource-intensive, or unreliable work. Instead of making the user wait for an email to send, a video to transcode, or a payment to process, you enqueue the work and process it in the background. The core tools are **message queues**, **worker pools**, **saga pattern**, **workflow engines**, **dead letter queues**, and **backpressure mechanisms**. This is among the most practically important system design topics -- every production system of meaningful scale uses async processing.

---

## Message Queues

A message queue is a buffer that decouples producers (who send messages) from consumers (who process them). Producers write messages to the queue; consumers read and process them at their own pace. This enables temporal decoupling (producer and consumer do not need to be available simultaneously) and load leveling (absorb traffic spikes).

### Apache Kafka

Kafka is a distributed, durable, ordered log. Messages are written to partitions within topics. Consumers read from partitions in order, tracking their position (offset).

**Architecture:**
```
Producers --> Topic (partitioned)
                |
    +-----------+-----------+
    |           |           |
 Partition 0  Partition 1  Partition 2
    |           |           |
Consumer Group (each partition assigned to one consumer)
```

**Key characteristics:**
- **Ordered within a partition** -- messages with the same key go to the same partition, preserving order
- **Durable** -- messages are persisted to disk and replicated across brokers
- **High throughput** -- designed for millions of messages per second
- **Consumer groups** -- multiple consumers share a topic's partitions for parallel processing; each message is delivered to exactly one consumer in the group
- **Replay** -- consumers can reset their offset and reprocess messages

**When to use Kafka:**
- Event streaming (user actions, system events, CDC)
- High-throughput, ordered message processing
- When consumers need to replay or reprocess events
- Event sourcing / CQRS projection feeds

### RabbitMQ

RabbitMQ is a traditional message broker implementing AMQP. It focuses on message routing, acknowledgment, and delivery guarantees.

**Key characteristics:**
- **Flexible routing** -- exchanges route messages to queues based on routing keys, headers, or patterns (direct, fanout, topic, headers)
- **Message acknowledgment** -- consumers explicitly ack messages; unacked messages are redelivered
- **Priority queues** -- messages can have priority levels
- **Lower throughput than Kafka** but richer routing semantics
- **No replay** -- once consumed and acked, messages are removed

**When to use RabbitMQ:**
- Task queues (background jobs, email sending)
- Complex routing requirements (route orders to different queues by region)
- Request-reply patterns
- When you need fine-grained delivery guarantees per message

### Amazon SQS

SQS is a fully managed queue service. It comes in two flavors:

- **Standard Queue** -- at-least-once delivery, best-effort ordering, nearly unlimited throughput
- **FIFO Queue** -- exactly-once processing, strict ordering within message groups, limited to 3,000 msg/sec with batching

**Key characteristics:**
- **Fully managed** -- no brokers to operate
- **Visibility timeout** -- when a consumer reads a message, it becomes invisible to other consumers for a configurable period. If the consumer does not delete it, it reappears.
- **Long polling** -- reduces empty responses and cost
- **Dead letter queue** -- built-in DLQ support after N failed processing attempts

**When to use SQS:**
- AWS-native architectures
- Simple queue semantics without complex routing
- When you want zero operational overhead

### Choosing a Queue

| Feature | Kafka | RabbitMQ | SQS |
|---|---|---|---|
| Ordering | Per-partition | Per-queue | Best-effort (FIFO available) |
| Throughput | Very high | Moderate | High |
| Durability | Strong (replicated log) | Good (persistent queues) | Strong (managed) |
| Replay | Yes (offset reset) | No | No |
| Routing | Partition key only | Rich (exchanges, routing keys) | Simple |
| Operational cost | High (Zookeeper/KRaft) | Moderate | None (managed) |

---

## Worker Pools

Workers are processes that consume messages from a queue and execute the associated work. A worker pool is a set of worker processes, typically sized to match available resources and desired throughput.

### Design Considerations

```ruby
class Worker
  CONCURRENCY = ENV.fetch("WORKER_CONCURRENCY", 10).to_i

  def initialize(queue:)
    @queue = queue
    @pool = Concurrent::FixedThreadPool.new(CONCURRENCY)
  end

  def start
    loop do
      message = @queue.receive  # blocking call
      @pool.post do
        process(message)
      rescue StandardError => e
        handle_failure(message, e)
      end
    end
  end

  private

  def process(message)
    # Business logic here
    perform_work(message.body)
    @queue.acknowledge(message)
  end

  def handle_failure(message, error)
    if message.attempt_count >= MAX_RETRIES
      @queue.send_to_dlq(message)
    else
      @queue.nack(message)  # requeue with backoff
    end
    log_error(error, message)
  end
end
```

### Scaling Workers

- **Horizontal scaling** -- add more worker processes/pods to increase throughput
- **Auto-scaling** -- scale based on queue depth (CloudWatch + ASG for SQS, KEDA for Kafka)
- **Concurrency tuning** -- for I/O-bound work, increase threads per worker. For CPU-bound work, increase worker count.
- **Resource isolation** -- separate worker pools for different job types to prevent one type from starving others

### Poison Messages

A poison message is one that consistently fails processing (bad data, unhandled edge case). Without protection, it can block a queue indefinitely.

**Mitigation:**
- Track retry count per message
- After N failures, move to dead letter queue
- Alert on DLQ depth
- Never block the queue on a single message

---

## Saga Pattern

The saga pattern manages distributed transactions across multiple services without a global two-phase commit. Instead of one atomic transaction, a saga is a sequence of local transactions where each step has a compensating action to undo its effects if a later step fails.

### Choreography-Based Saga

Each service listens for events and triggers the next step. No central coordinator.

```
Order Service       Payment Service      Inventory Service
     |                    |                     |
     | -- OrderCreated -> |                     |
     |                    | -- PaymentCharged -> |
     |                    |                     | -- InventoryReserved ->
     |                    |                     |
  (if Inventory fails)    |                     |
     |                    | <- CompensatePayment |
     | <- CompensateOrder |                     |
```

**Pros:** Loose coupling, no single point of failure. **Cons:** Hard to trace the overall flow, difficult to debug, implicit dependencies between services.

### Orchestration-Based Saga

A central orchestrator (saga coordinator) directs each step and handles compensation on failure.

```
Saga Orchestrator
     |
     | --> Order Service: Create Order
     | <-- Success
     | --> Payment Service: Charge Payment
     | <-- Success
     | --> Inventory Service: Reserve Stock
     | <-- FAILURE
     | --> Payment Service: Refund Payment (compensate)
     | --> Order Service: Cancel Order (compensate)
```

**Pros:** Easy to understand and debug, centralized flow control. **Cons:** The orchestrator is a single point of failure (mitigate with persistence and recovery). More coupling to the orchestrator.

**Interview tip:** Orchestration-based sagas are generally preferred for complex workflows because they are easier to reason about, test, and monitor. Choreography works well for simpler 2-3 step flows.

---

## Workflow Engines (Temporal)

Temporal (and its predecessor, Uber's Cadence) is a durable execution engine for long-running workflows. It provides automatic retry, state persistence, and crash recovery for complex multi-step processes.

### Core Concepts

- **Workflow** -- a deterministic function that orchestrates activities. Its state is persisted automatically. If the worker crashes, the workflow resumes from where it left off.
- **Activity** -- a single unit of work (call an API, send an email, query a database). Activities can be retried independently.
- **Task Queue** -- workflows and activities are dispatched via task queues to workers.

### Why Temporal Over Raw Queues

| Aspect | Raw Queues + Workers | Temporal |
|---|---|---|
| State management | You build it (DB, Redis) | Automatic (event-sourced) |
| Retry logic | You build it | Declarative retry policies |
| Timeouts | You build them | Built-in activity timeouts |
| Visibility | You build dashboards | Built-in UI for workflow state |
| Complex flows | Hard (chained queues) | Natural (code as workflow) |
| Versioning | Painful | Built-in workflow versioning |

### When to Use Temporal

- Multi-step processes spanning minutes to months (order fulfillment, onboarding flows)
- Processes that need durable timers (send reminder in 3 days)
- Complex compensation/rollback logic
- When you need visibility into long-running process state

**Trade-offs:** Temporal adds infrastructure complexity (Temporal server, persistence store). For simple queue-and-process workloads, it is overkill.

---

## Dead Letter Queues (DLQ)

A DLQ is a secondary queue where messages that cannot be processed after exhausting retries are sent. It prevents poison messages from blocking the main queue and provides a mechanism for investigation and reprocessing.

### DLQ Workflow

```
Main Queue -> Consumer -> Process
                |
                | (failure, retry N times)
                |
                v
        Dead Letter Queue -> Alert -> Investigate -> Fix -> Replay
```

### Best Practices

- **Set a retry limit** -- typically 3-5 retries with exponential backoff before DLQ
- **Preserve context** -- include the original message, error details, retry count, and timestamps in DLQ entries
- **Monitor DLQ depth** -- alert when messages accumulate (indicates a systemic issue)
- **Replay mechanism** -- build tooling to move DLQ messages back to the main queue after fixing the issue
- **Separate DLQs per topic/queue** -- makes investigation easier

---

## Backpressure

Backpressure is a mechanism to handle situations where producers generate work faster than consumers can process it. Without backpressure, queues grow unbounded, memory is exhausted, and the system crashes.

### Strategies

**1. Bounded Queues**
Set a maximum queue size. When full, producers are blocked or messages are rejected. This pushes backpressure upstream to the producer.

**2. Rate Limiting Producers**
Limit the rate at which producers can enqueue messages. See [[../api-gateway-and-service-mesh/index|API Gateway & Service Mesh]] for rate limiting algorithms.

**3. Load Shedding**
When overloaded, intentionally drop lower-priority work to protect the system's ability to handle critical work.

```ruby
class BackpressureQueue
  MAX_DEPTH = 10_000

  def enqueue(message)
    if @queue.size >= MAX_DEPTH
      if message.priority == :low
        # Shed low-priority work
        metrics.increment("queue.shed")
        return :shed
      else
        # Block high-priority producers until space available
        sleep(0.1) until @queue.size < MAX_DEPTH
      end
    end
    @queue.push(message)
  end
end
```

**4. Consumer Scaling**
Auto-scale consumers based on queue depth. This is reactive backpressure -- the system adapts to demand.

**5. Credit-Based Flow Control**
Consumers tell producers how many messages they can accept (credits). Producers stop sending when credits are exhausted. Used by RabbitMQ's QoS prefetch and reactive streams.

**Interview tip:** Backpressure is a system-wide concern. Discuss it at every layer: API gateway (rate limiting), queue (bounded depth), consumers (concurrency limits), and downstream services (circuit breakers). A system without backpressure at any layer will eventually cascade fail under load.

---

## Delivery Guarantees

Understanding message delivery semantics is critical for designing correct async systems.

| Guarantee | Description | Use Case |
|---|---|---|
| **At-most-once** | Message delivered 0 or 1 times. Fire and forget. | Logging, metrics (some loss OK) |
| **At-least-once** | Message delivered 1+ times. May duplicate. | Most background jobs (with idempotency) |
| **Exactly-once** | Message delivered exactly 1 time. | Financial transactions (hardest to achieve) |

**Exactly-once is extremely hard** in distributed systems. Most systems achieve it through at-least-once delivery combined with [[../fault-tolerance-and-reliability/index|idempotency]] on the consumer side.

---

## Putting It Together: Async Processing Decision Framework

```
Is the work time-sensitive (must complete within the request)?
  YES -> Do it synchronously (or with a very fast cache-aside pattern)
  NO  -> Async processing

Is the work a simple task (send email, resize image)?
  YES -> Message queue + worker pool
    Need complex routing? -> RabbitMQ
    Need high throughput + replay? -> Kafka
    Want zero ops? -> SQS

Is the work a multi-step process spanning services?
  YES -> How complex?
    2-3 steps, loosely coupled -> Choreography saga
    Complex, many steps, needs visibility -> Orchestration saga or Temporal

Is ordering critical?
  YES -> Kafka (partition key ordering) or FIFO SQS
  NO  -> Standard SQS or RabbitMQ

Does the work span days/weeks?
  YES -> Workflow engine (Temporal)
  NO  -> Simple queue + workers
```

---

## Related Topics

- [[../scaling-writes/index|Scaling Writes]] -- CQRS and event sourcing use async projections
- [[../fault-tolerance-and-reliability/index|Fault Tolerance]] -- retries, idempotency, circuit breakers for async consumers
- [[../real-time-systems/index|Real-Time Systems]] -- pub/sub for real-time event delivery
- [[../distributed-systems-fundamentals/index|Distributed Systems]] -- consensus and ordering in distributed queues
- [[../api-gateway-and-service-mesh/index|API Gateway]] -- rate limiting as a form of backpressure
