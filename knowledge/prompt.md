Help me prep for tech interviews. Create an obsidian knowledge bank with 2 separate directories for:
- technical and coding
- architecture and system design

## Process
1. Research into the topic. What are the current era of popular questions (post AI/LLM world)
2. Write a primer markdown. This is the the index file. All topics have a quick 1 paragraph description and then link outs to other documents that can contain examples or further research
3. Prepare exercises similar to what we did with ebay's frontend debugging exercise (if applicable). 

## Filestructure:
```
/knowledge
|-index.md
|-/technical-and-coding
  |-index.md
  |-/topic_a
    |-index.md
    |-exercises
|-/system-design
```


Use subagents to do this work in parallel. When writing code examples, use ruby. I also prepped some starter resources for you in each of the directories index files. Start from there

## Notes
- The knowledge directory is created for you, but has not been initialized as an obsidian vault. You should do that first
- The basic filestructure is also created and is meant to be a starting point. Replace the content with your research
- There may be some overlap with the content and resources between the 2 directories. That's perfectly fine. Link them across each other when applicable. Do not denormalize the content

# Technical and coding
Starter resources to look at. Replace this file as you work

## Coding interview university
https://github.com/jwasham/coding-interview-university

## FAANG Coding problems
https://github.com/ombharatiya/FAANG-Coding-Interview-Questions

## Grind 75
https://github.com/yangshun/tech-interview-handbook

# System design primer
Starter topics to research into. Replace this file as you work

## Scaling reads
- caching 
- read replication
- indexing

## Scaling writes
- sharding
- batching
- async writes (write ahead, through, back, and around)

## Real time
- web sockets
- server side events
- web polling

## long
- message queues
- worker pools
- workflow engines (temporal)

## Failures
- retries
- idempotency
- self healing
- circuit breakers

## Databases
- sql - psql, mysql - ACID
- nosql - mongo, dynamo - scalability
- specialized - cassandra (columnar), graph dbs, redis (cache)

## Resources
https://github.com/donnemartin/system-design-primer