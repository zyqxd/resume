# API Design

API design is one of the most directly practical interview topics. Nearly every backend and full-stack role includes a round where you design a REST API, review an existing one, or discuss trade-offs between REST and GraphQL. At the staff level, interviewers expect you to go beyond CRUD: they want to hear about versioning strategy, pagination trade-offs, idempotency guarantees, rate limiting algorithms, and how you handle backward compatibility.

The post-2025 landscape has added new dimensions: AI-powered APIs (streaming responses, tool-use schemas), webhook reliability, and real-time APIs (WebSockets, SSE) are now common discussion topics. Companies increasingly test API design in the context of real systems rather than abstract prompts.

---

## REST Best Practices

### Resource Naming

Resources are nouns, not verbs. Use plural nouns for collections. Nest resources to express ownership, but avoid deep nesting (max 2 levels).

```
# Good
GET    /users
GET    /users/:id
POST   /users
PATCH  /users/:id
DELETE /users/:id

GET    /users/:id/orders          # orders for a user
GET    /orders/:id                # order by ID (flat is fine)
POST   /users/:id/orders          # create order for user

# Bad
GET    /getUser/:id               # verb in URL
POST   /users/:id/create-order    # verb in URL
GET    /users/:id/orders/:oid/items/:iid/reviews  # too deep
```

### HTTP Methods & Status Codes

Use methods correctly. This matters more than most candidates realize.

| Method | Semantics | Idempotent? | Safe? |
|---|---|---|---|
| GET | Read resource | Yes | Yes |
| POST | Create resource / trigger action | No | No |
| PUT | Full replace | Yes | No |
| PATCH | Partial update | No* | No |
| DELETE | Remove resource | Yes | No |

*PATCH can be made idempotent with JSON Merge Patch or by sending the full field values.

Status codes to know:

| Code | Meaning | When to use |
|---|---|---|
| 200 | OK | Successful GET, PATCH, DELETE |
| 201 | Created | Successful POST that creates a resource |
| 204 | No Content | Successful DELETE with no body |
| 301 | Moved Permanently | Resource URL changed permanently |
| 304 | Not Modified | Conditional GET (ETag/If-None-Match) |
| 400 | Bad Request | Malformed request (invalid JSON, missing fields) |
| 401 | Unauthorized | Missing or invalid authentication |
| 403 | Forbidden | Authenticated but not authorized |
| 404 | Not Found | Resource does not exist |
| 409 | Conflict | State conflict (e.g., duplicate resource, version mismatch) |
| 422 | Unprocessable Entity | Valid syntax but semantic errors (validation failures) |
| 429 | Too Many Requests | Rate limit exceeded |
| 500 | Internal Server Error | Unhandled exception |
| 503 | Service Unavailable | Server overloaded or in maintenance |

### Request & Response Design

Design responses for the consumer, not the database schema. Include only what the client needs. Use consistent envelope structure.

```ruby
# Sinatra/Rack-style response example

# Good: consistent structure, useful metadata
{
  data: {
    id: "usr_abc123",
    type: "user",
    attributes: {
      name: "Alice",
      email: "alice@example.com",
      created_at: "2025-01-15T10:30:00Z"
    },
    relationships: {
      organization: { id: "org_xyz", type: "organization" }
    }
  },
  meta: {
    request_id: "req_def456"
  }
}

# Error response: consistent structure
{
  error: {
    code: "validation_error",
    message: "Validation failed",
    details: [
      { field: "email", message: "is not a valid email address" },
      { field: "name", message: "is required" }
    ]
  },
  meta: {
    request_id: "req_ghi789"
  }
}
```

---

## Pagination

Three main strategies, each with trade-offs:

### Offset-based (Page/Limit)

Simple and familiar. The client specifies a page number and page size.

```
GET /users?page=3&per_page=25
```

Pros: simple, supports jumping to arbitrary pages.
Cons: inconsistent results when data changes (items shift between pages), O(n) database performance for deep pages (`OFFSET 10000` still scans 10000 rows).

### Cursor-based (Keyset)

Uses an opaque cursor (typically an encoded primary key or timestamp) to mark the position. The client passes the cursor from the previous response.

```
GET /users?after=eyJpZCI6MTAwfQ&limit=25
```

Pros: consistent results regardless of insertions/deletions, O(1) database performance (uses `WHERE id > cursor`).
Cons: cannot jump to arbitrary pages, more complex to implement.

```ruby
# Ruby implementation of cursor-based pagination
def paginate_users(after_cursor: nil, limit: 25)
  query = User.order(:id).limit(limit + 1) # fetch one extra to check if more exist

  if after_cursor
    decoded_id = Base64.decode64(after_cursor).to_i
    query = query.where("id > ?", decoded_id)
  end

  users = query.to_a
  has_more = users.length > limit
  users = users.first(limit)

  next_cursor = has_more ? Base64.strict_encode64(users.last.id.to_s) : nil

  {
    data: users,
    pagination: {
      has_more: has_more,
      next_cursor: next_cursor
    }
  }
end
```

### Seek-based (Time-based)

A variant of cursor-based that uses a timestamp. Common for feeds and activity streams.

```
GET /events?since=2025-01-15T10:30:00Z&limit=50
```

Pros: natural for time-series data, clients can request "everything since my last sync."
Cons: timestamp ties can cause duplicates or missed items (mitigate with timestamp + ID compound cursor).

**Interview discussion point:** which pagination strategy would you use for a social media feed? (Cursor-based with compound cursor of created_at + id, because users scroll linearly and data changes frequently.)

---

## Versioning

### URI versioning

```
GET /v1/users
GET /v2/users
```

Pros: explicit, easy to understand, easy to route.
Cons: URL pollution, hard to version individual endpoints independently.

### Header versioning

```
GET /users
Accept: application/vnd.myapi.v2+json
```

Pros: clean URLs, can version at the resource level.
Cons: harder to test (cannot paste in browser), less discoverable.

### Query parameter versioning

```
GET /users?version=2
```

Pros: simple, backward compatible (default to latest or v1).
Cons: pollutes query parameters, caching complications.

**Staff-level opinion:** URI versioning is the most practical choice for public APIs. Header versioning is more "correct" but adds friction. The real question is: how do you evolve your API without breaking clients? The answer is additive changes (add fields, never remove), deprecation policies, and sunset headers.

---

## Rate Limiting

### Token Bucket

A bucket holds N tokens. Each request consumes one token. Tokens are added at a fixed rate. If the bucket is empty, the request is rejected.

```ruby
class TokenBucket
  def initialize(capacity:, refill_rate:)
    @capacity = capacity
    @tokens = capacity.to_f
    @refill_rate = refill_rate  # tokens per second
    @last_refill = Time.now
  end

  def allow?
    refill
    if @tokens >= 1
      @tokens -= 1
      true
    else
      false
    end
  end

  private

  def refill
    now = Time.now
    elapsed = now - @last_refill
    @tokens = [@tokens + elapsed * @refill_rate, @capacity].min
    @last_refill = now
  end
end
```

### Sliding Window Log

Track timestamps of each request. Count requests in the last N seconds. More precise but higher memory usage.

```ruby
class SlidingWindowLog
  def initialize(limit:, window_seconds:)
    @limit = limit
    @window = window_seconds
    @timestamps = []
  end

  def allow?
    now = Time.now
    @timestamps.reject! { |t| now - t > @window }
    if @timestamps.length < @limit
      @timestamps << now
      true
    else
      false
    end
  end
end
```

### Sliding Window Counter

Approximation that combines fixed window counters. Uses less memory than the log approach.

Rate limit headers to include in responses:
```
X-RateLimit-Limit: 100
X-RateLimit-Remaining: 42
X-RateLimit-Reset: 1706230800
Retry-After: 30
```

---

## Idempotency

Idempotency means that making the same request multiple times produces the same result as making it once. This is critical for payment APIs, order placement, and any operation where retries can cause duplicates.

### Idempotency Keys

The client generates a unique key (UUID) and sends it with the request. The server stores the key and the response. If the same key is seen again, the server returns the cached response without re-executing.

```ruby
class IdempotencyMiddleware
  def initialize(app, store:)
    @app = app
    @store = store
  end

  def call(env)
    key = env['HTTP_IDEMPOTENCY_KEY']
    return @app.call(env) unless key  # no key = not idempotent

    # Check if we have a cached response
    cached = @store.get("idempotency:#{key}")
    if cached
      return [cached[:status], cached[:headers], [cached[:body]]]
    end

    # Execute the request
    status, headers, body = @app.call(env)

    # Cache the response (with TTL to avoid unbounded growth)
    @store.set("idempotency:#{key}", {
      status: status,
      headers: headers.to_h,
      body: body.first
    }, ex: 86400)  # 24-hour TTL

    [status, headers, body]
  end
end
```

Key design decisions:
- **Scope**: per-user or global? Per-user prevents cross-user collisions.
- **TTL**: how long to cache? 24 hours is common.
- **Conflict handling**: what if the same key is used with different request bodies? Return 422.

---

## GraphQL Trade-offs

### When GraphQL Wins

- **Multiple client types** (web, mobile, third-party) that need different data shapes from the same API
- **Over-fetching/under-fetching** problems where REST requires many endpoints or returns too much data
- **Rapid iteration** where frontend teams need to change data requirements without backend changes
- **Deeply nested relationships** where REST would require multiple round trips

### When REST Wins

- **Simple CRUD** operations with well-defined resources
- **Caching** (HTTP caching with ETags, CDN caching is trivial with REST, complex with GraphQL)
- **File upload/download** (GraphQL is awkward for binary data)
- **Internal microservices** where the client and server are tightly coupled
- **Rate limiting** (hard to define "one request" in GraphQL where a single query can be arbitrarily expensive)

### Common GraphQL Pitfalls

- **N+1 queries**: a query for users with their orders triggers one query per user. Solution: DataLoader (batching).
- **Query complexity**: a malicious query can request deeply nested relationships. Solution: query depth limiting, cost analysis.
- **Caching**: no HTTP-level caching. Must implement application-level caching with persistent queries or `@cacheControl` directives.

---

## Authentication & Authorization

### Token-based Auth (JWT)

```ruby
# Sinatra middleware for JWT auth
class JwtAuth
  def initialize(app, secret:)
    @app = app
    @secret = secret
  end

  def call(env)
    token = extract_token(env)
    return unauthorized unless token

    begin
      payload = JWT.decode(token, @secret, true, algorithm: 'HS256').first
      env['current_user_id'] = payload['sub']
      env['token_scopes'] = payload['scopes'] || []
    rescue JWT::DecodeError
      return unauthorized
    rescue JWT::ExpiredSignature
      return [401, {}, [{ error: 'Token expired' }.to_json]]
    end

    @app.call(env)
  end

  private

  def extract_token(env)
    auth = env['HTTP_AUTHORIZATION']
    auth&.match(/^Bearer (.+)$/)&.captures&.first
  end

  def unauthorized
    [401, { 'Content-Type' => 'application/json' },
     [{ error: 'Unauthorized' }.to_json]]
  end
end
```

### API Keys

Simpler than JWT. Good for server-to-server communication. Send in header (`X-API-Key`) not in query params (logged in server access logs).

### OAuth 2.0 Scopes

For third-party access, use OAuth 2.0 with scopes. The token includes a list of permissions, and the API checks them on each request.

```ruby
def require_scope(scope)
  scopes = request.env['token_scopes']
  halt 403, { error: "Missing scope: #{scope}" }.to_json unless scopes.include?(scope)
end

# Usage
get '/users/:id/billing' do
  require_scope('billing:read')
  # ...
end
```

---

## Real-Time APIs

### WebSockets

Full-duplex, persistent connection. Good for chat, live updates, collaborative editing.

Considerations: load balancer support (sticky sessions or layer 4), connection management, heartbeats, reconnection logic.

### Server-Sent Events (SSE)

Server-to-client only. Uses standard HTTP. Simpler than WebSockets when you only need server push.

```ruby
# Sinatra SSE endpoint
get '/events', provides: 'text/event-stream' do
  stream(:keep_open) do |out|
    EventBus.subscribe do |event|
      out << "event: #{event.type}\ndata: #{event.data.to_json}\n\n"
    end
  end
end
```

SSE advantages over WebSockets: automatic reconnection, works with HTTP/2 multiplexing, simpler server implementation, works through most proxies without configuration.

### Webhooks

Server calls a client-provided URL when events occur. The client registers a URL and event types.

Key design considerations:
- **Retry logic**: exponential backoff on failure (e.g., 1s, 5s, 30s, 5m, 1h)
- **Verification**: HMAC signature in headers so the client can verify the webhook is genuine
- **Idempotency**: include an event ID so the client can deduplicate
- **Ordering**: webhooks may arrive out of order; include timestamps or sequence numbers

```ruby
# Webhook delivery with HMAC signing
class WebhookDelivery
  def deliver(url:, payload:, secret:)
    body = payload.to_json
    signature = OpenSSL::HMAC.hexdigest('SHA256', secret, body)

    response = Net::HTTP.post(
      URI(url),
      body,
      'Content-Type' => 'application/json',
      'X-Webhook-Signature' => "sha256=#{signature}",
      'X-Webhook-ID' => SecureRandom.uuid,
      'X-Webhook-Timestamp' => Time.now.to_i.to_s
    )

    response.code.start_with?('2')
  end
end
```

---

## Exercises

- [[exercises/INSTRUCTIONS|Buggy API Code Review]] -- Review a Ruby API (Sinatra) for an e-commerce product catalog with authentication, pagination, rate limiting, and error handling issues.

## Related Topics

- [[../02-object-oriented-design/index|Object-Oriented Design]] -- API design is the external interface of your OOD
- [[../05-testing-and-quality/index|Testing & Quality]] -- API testing strategies (contract testing, integration testing)
- [[../system-design/index|System Design]] -- APIs connect the components of your system design
