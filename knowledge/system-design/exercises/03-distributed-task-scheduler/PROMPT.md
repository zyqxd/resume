# Exercise: Design a Distributed Task Scheduler

## Prompt

Design a distributed task scheduling system like a simplified version of Airflow, Temporal, or a cloud-based cron service. The system should reliably execute tasks at specified times or on recurring schedules, handle failures gracefully, and scale to millions of scheduled tasks.

## Requirements

### Functional Requirements
- Schedule one-time tasks to execute at a specific future time
- Schedule recurring tasks with cron-like expressions
- Execute tasks exactly once (or at-least-once with idempotency)
- Support task dependencies (task B runs only after task A succeeds)
- Retry failed tasks with configurable retry policies
- Provide visibility into task status (pending, running, succeeded, failed)
- Support task cancellation and rescheduling
- Dead letter handling for permanently failed tasks

### Non-Functional Requirements
- Trigger accuracy: tasks should fire within 1 second of their scheduled time
- Handle 10M scheduled tasks
- Execute up to 100K tasks per minute at peak
- 99.99% availability -- missed tasks are unacceptable for critical workflows
- Horizontal scalability -- no single point of failure
- Support multi-tenant isolation (tasks from one tenant do not affect another)

### Out of Scope (clarify with interviewer)
- Task authoring UI / DAG visualization
- Complex workflow orchestration (that is Temporal/Airflow territory)
- Long-running tasks (> 1 hour) -- focus on short tasks (< 5 minutes)
- Task-specific compute environments (assume uniform workers)

## Constraints
- 10M registered tasks (mix of one-time and recurring)
- 100K task executions per minute at peak
- Average task duration: 30 seconds
- Task payload size: < 1MB
- 1000 tenants

## Key Topics Tested
- [[../../distributed-systems-fundamentals/index|Distributed Systems]] -- consensus, leader election, distributed locks
- [[../../fault-tolerance-and-reliability/index|Fault Tolerance]] -- retries, idempotency, exactly-once semantics
- [[../../async-processing/index|Async Processing]] -- message queues, worker pools, DLQs
- [[../../databases-and-storage/index|Databases & Storage]] -- efficient querying of time-based data
