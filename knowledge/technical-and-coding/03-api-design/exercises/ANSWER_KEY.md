# Answer Key -- Buggy API Code Review

---

## Security Vulnerabilities

### 1. JWT secret hardcoded in source code (Line 23)
**Severity: P0 -- full auth bypass if code leaks**

Anyone with access to the source code can forge valid JWTs for any user, including admin.

```ruby
# FIX: load from environment variable
set :jwt_secret, ENV.fetch('JWT_SECRET') { raise 'JWT_SECRET not set' }
```

### 2. SQL injection in login (Line 82)
**Severity: P0 -- full database compromise**

`username` is interpolated directly into SQL. An attacker can input `' OR 1=1 --` to bypass authentication or `'; DROP TABLE users; --` to destroy data.

```ruby
# BUG
db.execute("SELECT * FROM users WHERE username = '#{username}'")

# FIX: use parameterized query
db.execute("SELECT * FROM users WHERE username = ?", [username])
```

### 3. SQL injection in registration (Line 107)
**Severity: P0 -- full database compromise**

Same string interpolation issue.

### 4. SQL injection in search (Line 145)
**Severity: P0 -- full database compromise**

User-provided search query directly in SQL.

```ruby
# FIX
db.execute("SELECT * FROM products WHERE name LIKE ? OR description LIKE ?",
           ["%#{query}%", "%#{query}%"])
```

### 5. SQL injection in product ID lookup (Line 153)
**Severity: P0 -- SQL injection via URL parameter**

`params[:id]` interpolated without parameterization. Even though `.to_i` is not called, the value goes directly into SQL.

```ruby
# FIX
db.execute("SELECT * FROM products WHERE id = ?", [params[:id].to_i])
```

### 6. JWT token never expires (Line 95)
**Severity: P0 -- stolen tokens work forever**

No `exp` claim in the JWT payload. A compromised token is valid indefinitely.

```ruby
# FIX: add expiration
token = JWT.encode({
  sub: user[0],
  username: user[1],
  role: user[3],
  exp: Time.now.to_i + 3600  # 1 hour
}, settings.jwt_secret, 'HS256')
```

### 7. Password hash returned in login response (Line 102)
**Severity: P0 -- leaks password hashes**

The `password_hash` field is included in the response body.

```ruby
# FIX: exclude sensitive fields
{ token: token, user: { id: user[0], username: user[1], role: user[3] } }.to_json
```

### 8. Cookie set without httpOnly or secure flags (Line 100)
**Severity: P1 -- XSS can steal auth cookie**

```ruby
# FIX
response.set_cookie('auth_token', value: token, httponly: true,
                     secure: true, same_site: :strict)
```

### 9. IDOR in review creation (Line 213)
**Severity: P1 -- users can post reviews as other users**

The `user_id` comes from the request body, not from the JWT. Any authenticated user can post a review as any other user.

```ruby
# FIX: use the authenticated user's ID from the JWT
db.execute("INSERT INTO reviews ... VALUES (?, ?, ?, ?)",
           [params[:id], @current_user['sub'], data['rating'], data['comment']])
```

### 10. JWT role stored in token payload (Line 51)
**Severity: P1 -- privilege escalation risk**

If the JWT secret is compromised (it is hardcoded, see issue 1), an attacker can forge admin tokens. Even without that, roles should be checked against the database on each request, not cached in the token.

### 11. PUT allows updating any column including `id` (Line 176)
**Severity: P1 -- data corruption**

The update loop iterates over all keys in the request body. A request with `{"id": 999}` changes the product's primary key.

```ruby
# FIX: whitelist allowed fields
ALLOWED_FIELDS = %w[name description price category stock].freeze
data.each do |key, value|
  next unless ALLOWED_FIELDS.include?(key)
  fields << "#{key} = ?"
  values << value
end
```

### 12. Health endpoint leaks internal details (Lines 244-251)
**Severity: P1 -- information disclosure**

Exposes database version, Ruby version, environment, database file path, and uptime. Attackers use this for reconnaissance.

```ruby
# FIX: minimal health response
{ status: 'ok' }.to_json
```

### 13. Error handler leaks exception details (Line 264)
**Severity: P1 -- information disclosure**

Stack traces and error messages reveal internal implementation.

```ruby
# FIX: log details server-side, return generic message
error do
  logger.error(env['sinatra.error'].message)
  status 500
  { error: 'Internal server error', request_id: request.env['REQUEST_ID'] }.to_json
end
```

### 14. Bearer prefix not handled in auth (Line 44)
**Severity: P1 -- auth not standard-compliant**

The standard is `Authorization: Bearer <token>`. The code takes the entire header value as the token.

```ruby
# FIX
token = request.env['HTTP_AUTHORIZATION']&.match(/^Bearer (.+)$/)&.captures&.first
halt 401, { error: 'Unauthorized' }.to_json unless token
```

### 15. JWT decode error leaks internal details (Line 50)
**Severity: P2 -- information disclosure**

Includes `$!.message` which reveals JWT library internals.

### 16. Stock count exposed to all users (Line 258)
**Severity: P2 -- business data leak**

Competitors can query stock levels. Stock should only be visible to authenticated admins or as a boolean "in stock" / "out of stock."

---

## API Design Issues

### 17. No pagination metadata in response (Line 133)
**Severity: P1 -- clients cannot paginate**

Response is a bare array with no total count, no next/prev links, no page info.

```ruby
# FIX
total = db.execute("SELECT COUNT(*) FROM products").first[0]
{
  data: products.map { |p| product_to_hash(p) },
  pagination: {
    page: page,
    per_page: per_page,
    total: total,
    total_pages: (total.to_f / per_page).ceil
  }
}.to_json
```

### 18. POST /products returns 200 instead of 201 (Line 171)
**Severity: P2 -- wrong semantics**

POST that creates a resource should return 201 Created with a `Location` header.

```ruby
# FIX
status 201
headers 'Location' => "/products/#{id}"
```

### 19. POST /register returns 200 instead of 201 (Line 110)
**Severity: P2 -- wrong semantics**

### 20. POST /reviews returns 200 instead of 201 (Line 219)
**Severity: P2 -- wrong semantics**

### 21. DELETE returns 200 with body instead of 204 (Line 192)
**Severity: P2 -- wrong semantics**

Successful DELETE with no meaningful response body should be 204 No Content.

### 22. Rate limit returns 420 instead of 429 (Line 68)
**Severity: P2 -- non-standard status code**

420 is not in the HTTP spec. Use 429 Too Many Requests.

### 23. PUT used with PATCH semantics (Lines 174-185)
**Severity: P2 -- semantic confusion**

PUT should replace the entire resource. The current implementation accepts partial updates, which is PATCH behavior.

### 24. No versioning strategy
**Severity: P2 -- future breaking changes will be painful**

No URL prefix (`/v1/`), no Accept header versioning.

### 25. No CORS headers
**Severity: P1 -- frontend on different domain cannot use API**

### 26. No request ID for tracing
**Severity: P2 -- debugging production issues is hard**

Generate a UUID per request and include in all responses and logs.

### 27. No consistent error response format
**Severity: P2 -- inconsistent**

Some errors return `{ error: 'message' }`, some return `{ error: 'type', details: '...' }`. Standardize to a single error envelope.

---

## Bugs

### 28. Rate limiter uses in-memory hash, not shared storage (Lines 62-72)
**Severity: P1 -- rate limiting does not work across processes/servers**

`@rate_counts` is an instance variable. With multiple Puma workers or multiple servers, each has its own counter. Also, old entries are never cleaned up (memory leak).

```ruby
# FIX: use Redis with INCR and EXPIRE
redis.multi do |tx|
  tx.incr(key)
  tx.expire(key, 60)
end
```

### 29. Rate limiter minute-boundary burst (Line 64)
**Severity: P2 -- allows 2x burst**

A user can send 100 requests at second 59 of one minute and 100 at second 0 of the next, effectively 200 requests in 2 seconds. Use sliding window instead.

### 30. `per_page` has no maximum (Line 125)
**Severity: P1 -- DoS vector**

A client can request `per_page=10000000`, causing the database to return the entire table.

```ruby
# FIX
per_page = [[per_page, 1].max, 100].min  # clamp between 1 and 100
```

### 31. Negative page number allowed (Line 124)
**Severity: P2 -- undefined behavior**

`page=-1` results in negative offset.

### 32. No ORDER BY in product listing (Line 129)
**Severity: P1 -- non-deterministic pagination**

Without ORDER BY, the database can return rows in any order. Paginating without consistent ordering means items can appear on multiple pages or be skipped.

### 33. Stock update is not atomic (Lines 200-208)
**Severity: P0 -- race condition**

Read current stock, then update. Two concurrent requests can both read stock=10, both add 5, and set stock=15 instead of 20.

```ruby
# FIX: use atomic SQL
db.execute("UPDATE products SET stock = stock + ? WHERE id = ? AND stock + ? >= 0",
           [quantity, params[:id], quantity])
```

### 34. Bulk insert has no transaction (Lines 229-243)
**Severity: P1 -- partial failure**

If the 5th of 10 products fails, the first 4 are committed. Should use a transaction for all-or-nothing semantics, or at minimum return 207 Multi-Status.

```ruby
# FIX
db.transaction do
  data['products'].each { |p| ... }
end
```

### 35. No input validation on registration (Line 105)
**Severity: P1 -- data integrity**

Username and password can be nil, empty, or any format. No length limits, no password strength requirements.

### 36. Timing attack on login (Lines 83-86)
**Severity: P2 -- username enumeration**

The early return when the user is not found is faster than the bcrypt comparison when the user exists. An attacker can measure response times to determine which usernames exist.

```ruby
# FIX: always run bcrypt comparison
fake_hash = BCrypt::Password.create('dummy')
stored_hash = user ? user[2] : fake_hash
valid = BCrypt::Password.new(stored_hash) == password
halt 401, { error: 'Invalid credentials' }.to_json unless user && valid
```

### 37. Search has no pagination (Line 148)
**Severity: P1 -- returns unbounded results**

A search matching 100,000 products returns all of them.

### 38. Hard delete does not check for order references (Line 189)
**Severity: P1 -- referential integrity violation**

Deleting a product that has orders referencing it either fails (foreign key) or orphans the order data.

---

## Summary by Category

| Category | Count | P0 | P1 | P2 |
|---|---|---|---|---|
| Security | 16 | 6 | 6 | 4 |
| API Design | 11 | 0 | 2 | 9 |
| Bugs | 11 | 2 | 6 | 3 |
| **Total** | **38** | **8** | **14** | **16** |

---

## Recommended API Redesign

1. **Add API versioning**: prefix all routes with `/v1/`
2. **Standardize response envelope**: `{ data: ..., meta: { request_id, pagination }, errors: [...] }`
3. **Use cursor-based pagination** for search results and listings
4. **Add rate limit headers** to every response: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`
5. **Use parameterized queries everywhere** -- never interpolate user input into SQL
6. **Add request ID middleware** -- generate UUID, include in response headers and all logs
7. **Implement proper CORS** with configurable allowed origins
8. **Add ETag support** for conditional requests on product details
9. **Use soft deletes** (add `deleted_at` column) instead of hard deletes
10. **Add an `/openapi.json` endpoint** for API documentation
