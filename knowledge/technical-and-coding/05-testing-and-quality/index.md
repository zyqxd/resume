# Testing & Quality

Testing is a core competency at the staff level. Interviewers do not ask "do you write tests?" -- they ask "how do you decide what to test, at what level, and how do you keep your test suite fast and reliable as the codebase grows?" Staff engineers are expected to have a testing philosophy: opinions on the test pyramid, mocking boundaries, the role of TDD, and how to handle flaky tests.

The 2025-2026 landscape has added AI-generated code testing concerns: how do you verify AI-written code? How do you test AI integrations where outputs are non-deterministic? These are increasingly common discussion topics in interviews.

---

## The Test Pyramid

The test pyramid describes the distribution of tests by scope and cost:

```
         /  E2E  \          Slow, brittle, expensive
        /----------\
       / Integration \      Medium speed, moderate maintenance
      /----------------\
     /   Unit Tests      \  Fast, cheap, reliable
    /______________________\
```

### Unit Tests

Test a single class or function in isolation. Dependencies are replaced with test doubles (mocks, stubs). Unit tests should be fast (<10ms each), deterministic, and independent of each other.

What makes a good unit test:
- Tests behavior, not implementation. Assert on outputs, not internal state.
- Tests one thing. A test that asserts on three different behaviors should be three tests.
- Is readable. A developer unfamiliar with the code should understand what the test verifies.
- Fails for the right reason. If the test fails, the failure message should point directly to the bug.

```ruby
# RSpec unit test example
RSpec.describe PricingService do
  describe '#calculate_total' do
    it 'applies percentage discount to subtotal' do
      items = [
        build(:line_item, price: 100, quantity: 2),
        build(:line_item, price: 50, quantity: 1)
      ]
      discount = build(:discount, type: :percentage, value: 10)

      result = described_class.new.calculate_total(items, discount: discount)

      expect(result.subtotal).to eq(250)
      expect(result.discount_amount).to eq(25)
      expect(result.total).to eq(225)
    end

    it 'caps flat discount at subtotal to prevent negative total' do
      items = [build(:line_item, price: 10, quantity: 1)]
      discount = build(:discount, type: :flat, value: 50)

      result = described_class.new.calculate_total(items, discount: discount)

      expect(result.total).to eq(0)
    end

    it 'returns zero total for empty items' do
      result = described_class.new.calculate_total([])

      expect(result.total).to eq(0)
    end
  end
end
```

### Integration Tests

Test the interaction between multiple components: a service that talks to a database, an API endpoint with middleware, or a module that calls an external service through an adapter.

Integration tests are slower than unit tests but catch bugs that unit tests miss: wiring errors, serialization issues, database query correctness, and middleware ordering.

```ruby
# Integration test: API endpoint with database
RSpec.describe 'POST /api/orders', type: :request do
  let(:user) { create(:user) }
  let(:product) { create(:product, stock: 10, price: 29.99) }

  it 'creates an order and decrements stock' do
    post '/api/orders',
         params: { product_id: product.id, quantity: 2 }.to_json,
         headers: auth_headers(user)

    expect(response).to have_http_status(:created)

    order = Order.last
    expect(order.user_id).to eq(user.id)
    expect(order.total).to eq(59.98)

    product.reload
    expect(product.stock).to eq(8)
  end

  it 'returns 422 when stock is insufficient' do
    post '/api/orders',
         params: { product_id: product.id, quantity: 100 }.to_json,
         headers: auth_headers(user)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(product.reload.stock).to eq(10)  # unchanged
  end
end
```

### End-to-End Tests (E2E)

Test the full system from the user's perspective. For a web app, this means browser automation (Capybara, Playwright). For an API, this means calling the deployed service with real HTTP requests.

E2E tests are expensive: slow to run, brittle (UI changes break them), and hard to debug. Use them sparingly for critical user flows (signup, checkout, payment). Prefer integration tests for most coverage.

```ruby
# Capybara E2E test
RSpec.describe 'Checkout flow', type: :system do
  it 'completes a purchase successfully' do
    product = create(:product, name: 'Ruby Book', price: 49.99)

    visit '/products'
    click_on 'Ruby Book'
    click_on 'Add to Cart'
    click_on 'Checkout'

    fill_in 'Email', with: 'buyer@example.com'
    fill_in 'Card Number', with: '4242424242424242'
    click_on 'Place Order'

    expect(page).to have_text('Order Confirmed')
    expect(page).to have_text('$49.99')
  end
end
```

---

## Test-Driven Development (TDD)

TDD is a development workflow, not a testing technique. The cycle is:

1. **Red**: Write a failing test for the next piece of behavior.
2. **Green**: Write the minimum code to make the test pass.
3. **Refactor**: Clean up the code while keeping tests green.

### When TDD Shines

- **Well-defined behavior**: you know what the function should do before writing it. TDD forces you to think about the interface first.
- **Bug fixes**: write a test that reproduces the bug, then fix it. The test prevents regression.
- **Algorithm implementation**: write tests for known inputs/outputs, then implement.

### When TDD Is Less Useful

- **Exploratory work**: when you don't know what you're building yet. Spiking without tests, then writing tests after the design stabilizes, is pragmatic.
- **UI work**: the interface changes frequently. Writing E2E tests before the design is stable leads to constant test churn.
- **Integration points**: you cannot TDD your way into understanding an external API. Read the docs first, then write tests.

### Staff-Level Opinion

TDD is a tool, not a religion. Use it when it accelerates development (which is often). Skip it when it slows you down (spike, then test). The key discipline is: every piece of shipped code has tests, whether you wrote the tests first or second.

---

## Mocking Strategies

### When to Mock

Mock at the boundary between your code and external systems: HTTP clients, databases, file systems, time, randomness. Don't mock the thing you're testing.

### Test Doubles Taxonomy

```ruby
# Stub: returns canned data, no behavior verification
allow(payment_gateway).to receive(:charge).and_return(success_response)

# Mock: verifies that a method was called (behavior verification)
expect(email_service).to receive(:send).with(to: 'user@example.com', template: 'welcome')

# Spy: records calls for later assertion
email_service = spy('email_service')
# ... run code ...
expect(email_service).to have_received(:send).once

# Fake: a working implementation with shortcuts (in-memory database, fake HTTP server)
class FakePaymentGateway
  attr_reader :charges

  def initialize
    @charges = []
  end

  def charge(amount:, card_token:)
    @charges << { amount: amount, card_token: card_token }
    { id: "ch_#{SecureRandom.hex(8)}", status: 'succeeded' }
  end
end
```

### Mocking Anti-Patterns

**Over-mocking**: mocking every collaborator turns the test into a mirror of the implementation. Changing internal structure breaks all tests even if behavior is unchanged.

```ruby
# BAD: tests implementation, not behavior
it 'creates a user' do
  expect(User).to receive(:new).with(name: 'Alice').and_return(user)
  expect(user).to receive(:save!).and_return(true)
  expect(UserMailer).to receive(:welcome).with(user).and_return(mail)
  expect(mail).to receive(:deliver_later)

  service.create_user(name: 'Alice')
end

# GOOD: tests behavior through the service boundary
it 'creates a user and sends welcome email' do
  result = service.create_user(name: 'Alice')

  expect(result).to be_success
  expect(User.find_by(name: 'Alice')).to be_present
  expect(enqueued_jobs).to include(have_attributes(job_class: WelcomeEmailJob))
end
```

**Mock-driven coupling**: if you need to mock five things to test one thing, the code under test has too many dependencies. The test is telling you to refactor.

### Dependency Injection for Testability

Design classes to accept dependencies rather than creating them internally.

```ruby
# Hard to test: creates its own HTTP client
class WeatherService
  def current_temperature(city)
    response = Net::HTTP.get(URI("https://api.weather.com/v1/#{city}"))
    JSON.parse(response)['temperature']
  end
end

# Easy to test: accepts an HTTP client
class WeatherService
  def initialize(http_client: Net::HTTP)
    @http_client = http_client
  end

  def current_temperature(city)
    response = @http_client.get(URI("https://api.weather.com/v1/#{city}"))
    JSON.parse(response)['temperature']
  end
end

# In test:
fake_client = double(get: '{"temperature": 72}')
service = WeatherService.new(http_client: fake_client)
expect(service.current_temperature('toronto')).to eq(72)
```

---

## Property-Based Testing

Instead of testing specific examples, property-based testing generates random inputs and verifies that properties hold for all of them. This catches edge cases you would never think to write manually.

Ruby gem: `rantly` or `propcheck`.

```ruby
require 'rantly/rspec_extensions'

RSpec.describe 'sort' do
  it 'produces output of same length as input' do
    property_of { array(10) { integer } }.check do |arr|
      expect(arr.sort.length).to eq(arr.length)
    end
  end

  it 'produces a sorted array' do
    property_of { array(10) { integer } }.check do |arr|
      sorted = arr.sort
      sorted.each_cons(2) do |a, b|
        expect(a).to be <= b
      end
    end
  end

  it 'is idempotent' do
    property_of { array(10) { integer } }.check do |arr|
      expect(arr.sort).to eq(arr.sort.sort)
    end
  end

  it 'contains the same elements' do
    property_of { array(10) { integer } }.check do |arr|
      expect(arr.sort.tally).to eq(arr.tally)
    end
  end
end
```

Properties to look for:
- **Round-trip**: `decode(encode(x)) == x`
- **Idempotency**: `f(f(x)) == f(x)`
- **Invariants**: sorted output is always sorted, total is always non-negative
- **Commutativity**: `merge(a, b) == merge(b, a)`
- **Oracle**: compare your implementation against a known-correct but slow implementation

---

## Mutation Testing

Mutation testing measures test quality by introducing small changes (mutations) to your code and checking if your tests catch them. If a mutation survives (tests still pass), your tests have a gap.

Ruby gem: `mutant`.

Common mutations:
- Replace `>` with `>=`, `<`, `==`
- Replace `true` with `false`
- Remove method calls
- Replace `+` with `-`
- Change boundary values

```ruby
# Original code
def eligible?(age)
  age >= 18
end

# Mutant changes >= to >
def eligible?(age)
  age > 18  # mutation: changes boundary
end

# If your tests only check age=20 and age=10, this mutation SURVIVES
# You need a test for age=18 (the boundary) to kill it
```

Mutation testing is expensive to run (generates hundreds of mutations) but reveals the exact tests you are missing. Run it periodically, not on every commit.

---

## Testing Non-Deterministic Systems

### Time-Dependent Code

Never use `Time.now` directly. Inject a clock or use a test helper to freeze time.

```ruby
# Using Timecop gem
it 'expires tokens after 1 hour' do
  Timecop.freeze(Time.new(2025, 1, 15, 10, 0, 0)) do
    token = TokenService.generate(user)

    Timecop.travel(59.minutes.from_now)
    expect(TokenService.valid?(token)).to be true

    Timecop.travel(2.minutes.from_now)
    expect(TokenService.valid?(token)).to be false
  end
end
```

### Randomness

Seed the random number generator for reproducible tests.

```ruby
it 'shuffles deck consistently with same seed' do
  deck1 = Deck.new(seed: 42).shuffle
  deck2 = Deck.new(seed: 42).shuffle
  expect(deck1.cards).to eq(deck2.cards)
end
```

### AI/LLM Output Testing

For AI integrations, test the structure and constraints, not the exact content. See [[../06-ai-llm-integration/index|AI & LLM Integration]] for detailed patterns.

```ruby
it 'returns a summary within length constraints' do
  result = summarizer.summarize(long_document)

  expect(result).to be_a(String)
  expect(result.length).to be_between(50, 500)
  expect(result).not_to include(long_document[0..100])  # not just a prefix
end
```

---

## Test Organization & Maintainability

### Test Structure: Arrange-Act-Assert

Every test has three phases. Keep them visually distinct.

```ruby
it 'applies bulk discount for orders over $100' do
  # Arrange
  items = [build(:line_item, price: 60, quantity: 2)]
  pricing = PricingService.new(bulk_threshold: 100, bulk_discount: 0.10)

  # Act
  result = pricing.calculate(items)

  # Assert
  expect(result.total).to eq(108.0)  # 120 - 10% = 108
end
```

### Shared Examples and Contexts

Use shared examples to test common behavior across classes that share an interface.

```ruby
RSpec.shared_examples 'a payment gateway' do
  it 'charges the given amount' do
    result = subject.charge(amount: 1000, token: 'tok_test')
    expect(result.success?).to be true
    expect(result.amount).to eq(1000)
  end

  it 'returns failure for declined cards' do
    result = subject.charge(amount: 1000, token: 'tok_declined')
    expect(result.success?).to be false
    expect(result.error).to be_present
  end
end

RSpec.describe StripeGateway do
  subject { described_class.new(api_key: 'sk_test') }
  it_behaves_like 'a payment gateway'
end

RSpec.describe PayPalGateway do
  subject { described_class.new(client_id: 'test') }
  it_behaves_like 'a payment gateway'
end
```

### Avoiding Flaky Tests

Flaky tests are tests that sometimes pass and sometimes fail without code changes. Common causes:

1. **Time dependence**: test assumes current time. Fix: freeze time.
2. **Order dependence**: test depends on state left by a previous test. Fix: reset state in `before(:each)`.
3. **External services**: test calls a real API that is occasionally slow or down. Fix: mock/stub external calls.
4. **Concurrency**: test has a race condition. Fix: use synchronization or deterministic sequencing.
5. **Non-deterministic data**: test uses `rand` or `Time.now` in factories. Fix: use deterministic seeds.

---

## Test Coverage Philosophy

100% line coverage is not the goal. You can have 100% coverage and still miss critical bugs (e.g., integer overflow, race conditions, boundary values). Conversely, 80% coverage with well-chosen tests can be more effective than 100% with trivial assertions.

What to cover:
- All public API methods
- All error paths and edge cases
- All business rules
- Boundary values (0, 1, max, empty, nil)
- State transitions (especially invalid transitions)

What not to obsess over:
- Private methods (tested through public interface)
- Simple getters/setters
- Framework-generated code
- Boilerplate configuration

---

## Exercises

- [[exercises/INSTRUCTIONS|Testing a Payment Service]] -- Write a comprehensive test suite for a Ruby payment processing service with external dependencies, retries, and state management.

## Related Topics

- [[../02-object-oriented-design/index|Object-Oriented Design]] -- good design makes testing easy
- [[../03-api-design/index|API Design]] -- contract testing for APIs
- [[../06-ai-llm-integration/index|AI & LLM Integration]] -- testing non-deterministic AI outputs
- [[../04-concurrency-and-parallelism/index|Concurrency & Parallelism]] -- testing concurrent code
