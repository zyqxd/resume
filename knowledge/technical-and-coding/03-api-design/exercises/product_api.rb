# frozen_string_literal: true

# E-Commerce Product Catalog API
#
# A Sinatra REST API with authentication, pagination, rate limiting,
# search, and CRUD operations. Review for bugs, security issues,
# API design mistakes, and performance problems.
#
# There are 35+ intentional issues. Some are subtle.

require 'sinatra/base'
require 'json'
require 'jwt'
require 'bcrypt'
require 'sqlite3'
require 'securerandom'

class ProductAPI < Sinatra::Base
  configure do
    set :database, SQLite3::Database.new('products.db')
    # S: Secret key hardcoded in source code
    set :jwt_secret, 'super-secret-key-do-not-share'
    set :rate_limit, 100  # requests per minute
  end

  before do
    content_type :json

    # Rate limiting
    check_rate_limit unless request.path == '/health'
  end

  # ============================================================
  # Authentication
  # ============================================================

  helpers do
    def authenticate!
      token = request.env['HTTP_AUTHORIZATION']
      # S: No 'Bearer ' prefix handling -- accepts raw token
      halt 401, { error: 'Unauthorized' }.to_json unless token

      begin
        payload = JWT.decode(token, settings.jwt_secret, true, algorithm: 'HS256').first
        @current_user = payload
      rescue JWT::DecodeError
        # S: Leaks internal error details to client
        halt 401, { error: 'Invalid token', details: $!.message }.to_json
      end
    end

    def admin_only!
      authenticate!
      # S: Checks role from JWT payload -- user controls this if secret is weak
      halt 403, { error: 'Forbidden' }.to_json unless @current_user['role'] == 'admin'
    end

    def db
      settings.database
    end

    def check_rate_limit
      ip = request.ip
      key = "rate:#{ip}:#{Time.now.min}"
      # B: Using minute boundary -- resets allow burst of 200 requests
      # at minute boundary (100 at :59, 100 at :00)
      @rate_counts ||= {}
      @rate_counts[key] ||= 0
      @rate_counts[key] += 1

      if @rate_counts[key] > settings.rate_limit
        # B: Wrong HTTP status -- 420 is not standard
        halt 420, {
          error: 'Rate limit exceeded',
          # S: Leaks rate limit implementation details
          retry_after: 60 - Time.now.sec
        }.to_json
      end
    end
  end

  # ============================================================
  # Auth Endpoints
  # ============================================================

  post '/login' do
    data = JSON.parse(request.body.read)
    username = data['username']
    password = data['password']

    # S: SQL injection vulnerability
    user = db.execute("SELECT * FROM users WHERE username = '#{username}'").first
    halt 401, { error: 'Invalid credentials' }.to_json unless user

    # B: Timing attack -- BCrypt.== is constant time but the early
    # return on missing user leaks whether the username exists
    unless BCrypt::Password.new(user[2]) == password
      halt 401, { error: 'Invalid credentials' }.to_json
    end

    token = JWT.encode(
      {
        sub: user[0],
        username: user[1],
        role: user[3],
        # S: Token never expires -- no 'exp' claim
      },
      settings.jwt_secret,
      'HS256'
    )

    # S: Returns token in response body AND sets it as a cookie
    # Cookie is not httpOnly or secure
    response.set_cookie('auth_token', token)

    # B: Returns password hash in response
    { token: token, user: { id: user[0], username: user[1],
                            password_hash: user[2], role: user[3] } }.to_json
  end

  post '/register' do
    data = JSON.parse(request.body.read)

    # B: No input validation -- username/password can be nil or empty
    password_hash = BCrypt::Password.create(data['password'])

    # S: SQL injection
    db.execute("INSERT INTO users (username, password_hash, role) VALUES ('#{data['username']}', '#{password_hash}', 'user')")

    # B: Returns 200 instead of 201 for resource creation
    { message: 'User created' }.to_json
  end

  # ============================================================
  # Product CRUD
  # ============================================================

  get '/products' do
    page = (params[:page] || 1).to_i
    per_page = (params[:per_page] || 20).to_i

    # B: No validation on per_page -- client can request per_page=1000000
    # B: No validation on page -- negative page is allowed
    offset = (page - 1) * per_page

    # B: No consistent ordering -- results are non-deterministic without ORDER BY
    products = db.execute("SELECT * FROM products LIMIT #{per_page} OFFSET #{offset}")

    # S: SQL injection via per_page and offset (integer injection)
    # Even though to_i is called, the values are interpolated into SQL

    # API: No total count or pagination metadata in response
    # API: No links to next/prev pages (HATEOAS)
    products.map { |p| product_to_hash(p) }.to_json
  end

  get '/products/search' do
    query = params[:q]
    halt 400, { error: 'Query required' }.to_json unless query

    # S: SQL injection -- user input directly in SQL
    results = db.execute(
      "SELECT * FROM products WHERE name LIKE '%#{query}%' OR description LIKE '%#{query}%'"
    )

    # B: No pagination on search results
    # P: No full-text search index -- LIKE '%query%' cannot use indexes
    results.map { |p| product_to_hash(p) }.to_json
  end

  get '/products/:id' do
    # S: No type validation on :id -- could be SQL injection vector
    product = db.execute("SELECT * FROM products WHERE id = #{params[:id]}").first

    # API: Returns 200 with nil body instead of 404 when not found
    halt 404, { error: 'Not found' }.to_json unless product

    product_to_hash(product).to_json
  end

  post '/products' do
    admin_only!
    data = JSON.parse(request.body.read)

    # B: No validation of required fields (name, price)
    # B: No validation of data types (price should be numeric)
    # B: No check for duplicate products

    db.execute(
      "INSERT INTO products (name, description, price, category, stock) " \
      "VALUES ('#{data['name']}', '#{data['description']}', #{data['price']}, " \
      "'#{data['category']}', #{data['stock'] || 0})"
    )

    id = db.last_insert_row_id

    # API: Returns 200 instead of 201
    # API: No Location header pointing to the new resource
    { id: id, message: 'Product created' }.to_json
  end

  put '/products/:id' do
    admin_only!
    data = JSON.parse(request.body.read)

    # B: PUT should replace the entire resource, but this allows partial updates
    # This should be PATCH semantics
    fields = []
    values = []

    data.each do |key, value|
      # S: Allows updating ANY column including id
      fields << "#{key} = ?"
      values << value
    end

    values << params[:id]
    db.execute(
      "UPDATE products SET #{fields.join(', ')} WHERE id = ?",
      values
    )

    # API: No check if product exists -- returns success even for non-existent ID
    # API: Should return the updated resource
    { message: 'Product updated' }.to_json
  end

  delete '/products/:id' do
    admin_only!

    # B: Hard deletes the product -- should soft delete
    # B: Does not check if product exists before deleting
    # B: Does not handle products that are referenced by orders
    db.execute("DELETE FROM products WHERE id = ?", params[:id])

    # API: Returns 200 with body instead of 204 No Content
    { message: 'Product deleted' }.to_json
  end

  # ============================================================
  # Inventory Management
  # ============================================================

  patch '/products/:id/stock' do
    authenticate!
    data = JSON.parse(request.body.read)

    quantity = data['quantity']
    # B: No validation that quantity is an integer
    # B: No check for negative resulting stock

    # B: Race condition -- read then update is not atomic
    current = db.execute("SELECT stock FROM products WHERE id = ?", params[:id]).first
    halt 404, { error: 'Product not found' }.to_json unless current

    new_stock = current[0] + quantity

    # B: new_stock can be negative
    db.execute("UPDATE products SET stock = ? WHERE id = ?", new_stock, params[:id])

    { stock: new_stock }.to_json
  end

  # ============================================================
  # Reviews
  # ============================================================

  post '/products/:id/reviews' do
    authenticate!
    data = JSON.parse(request.body.read)

    # B: No validation that rating is 1-5
    # S: IDOR -- any authenticated user can post as any user_id
    db.execute(
      "INSERT INTO reviews (product_id, user_id, rating, comment) VALUES (?, ?, ?, ?)",
      [params[:id], data['user_id'], data['rating'], data['comment']]
    )

    # API: Returns 200 instead of 201
    { message: 'Review added' }.to_json
  end

  get '/products/:id/reviews' do
    # B: No pagination
    reviews = db.execute(
      "SELECT * FROM reviews WHERE product_id = ?", params[:id]
    )

    # P: N+1 potential -- if reviews include user details, need to join
    reviews.map { |r| { id: r[0], product_id: r[1], user_id: r[2],
                        rating: r[3], comment: r[4] } }.to_json
  end

  # ============================================================
  # Bulk Operations
  # ============================================================

  post '/products/bulk' do
    admin_only!
    data = JSON.parse(request.body.read)

    # B: No transaction -- partial failure leaves inconsistent state
    # P: No batch insert -- inserts one at a time
    results = data['products'].map do |product|
      begin
        db.execute(
          "INSERT INTO products (name, description, price, category, stock) " \
          "VALUES (?, ?, ?, ?, ?)",
          [product['name'], product['description'], product['price'],
           product['category'], product['stock']]
        )
        { name: product['name'], status: 'created' }
      rescue => e
        { name: product['name'], status: 'failed', error: e.message }
      end
    end

    # API: Returns 200 even when some items failed
    # Should return 207 Multi-Status or 422 if any failed
    { results: results }.to_json
  end

  # ============================================================
  # Health Check
  # ============================================================

  get '/health' do
    # S: Exposes database info and internal details
    {
      status: 'ok',
      database: db.execute("SELECT sqlite_version()").first[0],
      uptime: (Time.now - $start_time).to_i,
      ruby_version: RUBY_VERSION,
      env: ENV['RACK_ENV'],
      # S: Leaks environment variables
      database_path: db.filename
    }.to_json
  end

  # ============================================================
  # Helpers
  # ============================================================

  def product_to_hash(row)
    {
      id: row[0],
      name: row[1],
      description: row[2],
      price: row[3],
      category: row[4],
      stock: row[5],
      # S: Exposing internal stock count to all users (should be admin only)
      # API: No created_at/updated_at timestamps
      # API: No self-link (HATEOAS)
    }
  end

  # B: Global exception handler catches everything silently
  error do
    status 500
    # S: Leaks exception details in production
    { error: 'Internal server error', details: env['sinatra.error'].message }.to_json
  end

  # API: No CORS headers -- frontend on different domain cannot call this
  # API: No request ID for tracing
  # API: No versioning strategy
  # API: No API documentation endpoint
  # API: No ETag/conditional request support
end

$start_time = Time.now
