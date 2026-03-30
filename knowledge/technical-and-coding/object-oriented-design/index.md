# Object-Oriented Design

Object-Oriented Design (OOD) interviews test your ability to model real-world systems using classes, interfaces, and relationships. At the staff level, interviewers are not looking for pattern name-dropping; they want to see you decompose a problem into cohesive abstractions, manage dependencies cleanly, and design for change. A typical OOD round is 45-60 minutes: you will be given a vague prompt ("design a parking lot system"), and you must drive the conversation by clarifying requirements, identifying entities, defining their relationships, and writing code.

Ruby is an excellent language for OOD interviews because its dynamic typing, mixins, and blocks make design patterns concise and expressive. However, the lack of static typing means you must be disciplined about interface contracts and duck typing.

---

## SOLID Principles

### Single Responsibility Principle (SRP)

A class should have one reason to change. This does not mean one method -- it means one axis of change. A `User` class that handles authentication, profile rendering, and email sending has three reasons to change and should be split.

```ruby
# VIOLATION: User does too many things
class User
  def authenticate(password); end
  def render_profile; end
  def send_welcome_email; end
end

# BETTER: separate responsibilities
class User
  attr_reader :email, :name, :password_digest
end

class Authenticator
  def authenticate(user, password); end
end

class ProfileRenderer
  def render(user); end
end

class WelcomeMailer
  def send(user); end
end
```

The test for SRP: describe what the class does in one sentence without using "and" or "or."

### Open/Closed Principle (OCP)

Software entities should be open for extension but closed for modification. You should be able to add new behavior without changing existing code. In Ruby, this is often achieved through inheritance, composition, or duck typing.

```ruby
# VIOLATION: adding a new shape requires modifying AreaCalculator
class AreaCalculator
  def calculate(shape)
    case shape.type
    when :circle then Math::PI * shape.radius ** 2
    when :rectangle then shape.width * shape.height
    # Adding :triangle requires changing this method
    end
  end
end

# BETTER: each shape knows how to calculate its own area
class Circle
  def initialize(radius)
    @radius = radius
  end

  def area
    Math::PI * @radius ** 2
  end
end

class Rectangle
  def initialize(width, height)
    @width = width
    @height = height
  end

  def area
    @width * @height
  end
end

# Adding Triangle requires no changes to existing code
class Triangle
  def initialize(base, height)
    @base = base
    @height = height
  end

  def area
    0.5 * @base * @height
  end
end
```

### Liskov Substitution Principle (LSP)

Subtypes must be substitutable for their base types without altering correctness. If `Duck` inherits from `Bird`, anywhere you use a `Bird`, a `Duck` should work.

Classic violation: `Square` inheriting from `Rectangle`. Setting width on a `Square` must also set height, which breaks the contract that width and height are independent.

```ruby
# VIOLATION
class Rectangle
  attr_accessor :width, :height

  def area
    @width * @height
  end
end

class Square < Rectangle
  def width=(val)
    @width = val
    @height = val  # violates LSP: caller expects independent dimensions
  end

  def height=(val)
    @width = val
    @height = val
  end
end

# BETTER: use composition or separate abstractions
class Shape
  def area
    raise NotImplementedError
  end
end

class Rectangle < Shape
  def initialize(width, height)
    @width = width
    @height = height
  end

  def area
    @width * @height
  end
end

class Square < Shape
  def initialize(side)
    @side = side
  end

  def area
    @side ** 2
  end
end
```

### Interface Segregation Principle (ISP)

Clients should not be forced to depend on interfaces they do not use. In Ruby (which has no formal interfaces), this means modules/mixins should be focused. Don't create a god-module that forces includers to implement 20 methods when they only need 3.

```ruby
# VIOLATION: one big module
module Printable
  def print; end
  def scan; end
  def fax; end
  def staple; end
end

# BETTER: separate concerns
module Printable
  def print; end
end

module Scannable
  def scan; end
end

module Faxable
  def fax; end
end

class BasicPrinter
  include Printable
end

class MultiFunctionPrinter
  include Printable
  include Scannable
  include Faxable
end
```

### Dependency Inversion Principle (DIP)

High-level modules should not depend on low-level modules. Both should depend on abstractions. In Ruby, this is achieved through dependency injection and duck typing.

```ruby
# VIOLATION: high-level class depends on concrete low-level class
class OrderProcessor
  def initialize
    @notifier = EmailNotifier.new  # hard dependency
  end

  def process(order)
    # ... process order ...
    @notifier.notify(order)
  end
end

# BETTER: inject the dependency
class OrderProcessor
  def initialize(notifier:)
    @notifier = notifier  # any object that responds to #notify
  end

  def process(order)
    # ... process order ...
    @notifier.notify(order)
  end
end

# Can now use any notifier: email, SMS, Slack, or a test double
processor = OrderProcessor.new(notifier: SlackNotifier.new)
```

---

## Design Patterns

### Strategy Pattern

Encapsulate a family of algorithms and make them interchangeable. The client delegates behavior to a strategy object rather than implementing it directly.

Use when: you have multiple ways to do the same thing and want to switch between them at runtime.

```ruby
# Pricing strategies for an e-commerce system
class PricingStrategy
  def calculate(order)
    raise NotImplementedError
  end
end

class RegularPricing < PricingStrategy
  def calculate(order)
    order.items.sum(&:price)
  end
end

class MemberPricing < PricingStrategy
  DISCOUNT = 0.10

  def calculate(order)
    order.items.sum(&:price) * (1 - DISCOUNT)
  end
end

class BulkPricing < PricingStrategy
  def calculate(order)
    total = order.items.sum(&:price)
    total > 500 ? total * 0.85 : total
  end
end

class Order
  attr_reader :items

  def initialize(items:, pricing_strategy:)
    @items = items
    @pricing_strategy = pricing_strategy
  end

  def total
    @pricing_strategy.calculate(self)
  end
end

# Ruby-idiomatic: use blocks or lambdas instead of classes
class Order
  attr_reader :items

  def initialize(items:, &pricing)
    @items = items
    @pricing = pricing || ->(order) { order.items.sum(&:price) }
  end

  def total
    @pricing.call(self)
  end
end
```

### Observer Pattern

Define a one-to-many dependency so that when one object changes state, all dependents are notified. In Ruby, this is built into the standard library (`Observable` module), but implementing it from scratch shows understanding.

Use when: you need to decouple event producers from consumers (pub/sub, event-driven architectures).

```ruby
module Observable
  def self.included(base)
    base.instance_variable_set(:@observers, Hash.new { |h, k| h[k] = [] })
  end

  def add_observer(event, observer = nil, &block)
    callback = observer || block
    self.class.instance_variable_get(:@observers)[event] << callback
  end

  def notify(event, *args)
    self.class.instance_variable_get(:@observers)[event].each do |callback|
      if callback.respond_to?(:call)
        callback.call(*args)
      else
        callback.send("on_#{event}", *args)
      end
    end
  end
end

class Auction
  include Observable

  attr_reader :current_bid

  def place_bid(amount, bidder)
    raise "Bid too low" unless amount > (@current_bid || 0)

    @current_bid = amount
    notify(:bid_placed, amount, bidder)
  end

  def close
    notify(:auction_closed, @current_bid)
  end
end

auction = Auction.new
auction.add_observer(:bid_placed) { |amt, bidder| puts "New bid: $#{amt} by #{bidder}" }
auction.add_observer(:auction_closed) { |amt| puts "Sold for $#{amt}!" }
```

### Factory Pattern

Encapsulate object creation. Use when the creation logic is complex, when you need to return different subtypes based on input, or when you want to decouple the client from concrete classes.

```ruby
# Simple factory
class NotificationFactory
  TYPES = {
    email: EmailNotification,
    sms: SmsNotification,
    push: PushNotification
  }.freeze

  def self.create(type, **params)
    klass = TYPES.fetch(type) { raise ArgumentError, "Unknown type: #{type}" }
    klass.new(**params)
  end
end

# Abstract factory: family of related objects
class UIFactory
  def create_button; raise NotImplementedError; end
  def create_input; raise NotImplementedError; end
end

class DarkThemeFactory < UIFactory
  def create_button = DarkButton.new
  def create_input = DarkInput.new
end

class LightThemeFactory < UIFactory
  def create_button = LightButton.new
  def create_input = LightInput.new
end

# Registry pattern (Ruby-idiomatic alternative to factory)
class Serializer
  @registry = {}

  def self.register(format, klass)
    @registry[format] = klass
  end

  def self.for(format)
    @registry.fetch(format) { raise "Unknown format: #{format}" }
  end
end

class JsonSerializer
  Serializer.register(:json, self)

  def serialize(data)
    data.to_json
  end
end

class XmlSerializer
  Serializer.register(:xml, self)

  def serialize(data)
    # ... XML conversion ...
  end
end
```

### Decorator Pattern

Attach additional responsibilities to an object dynamically, without modifying its class. Decorators wrap an object and delegate calls to it, adding behavior before or after.

Use when: you need to add cross-cutting concerns (logging, caching, authorization) without modifying the core class.

```ruby
# Base service
class UserRepository
  def find(id)
    # database lookup
    { id: id, name: "Alice" }
  end
end

# Decorator: adds caching
class CachingUserRepository
  def initialize(repository, cache:)
    @repository = repository
    @cache = cache
  end

  def find(id)
    @cache.fetch("user:#{id}") { @repository.find(id) }
  end
end

# Decorator: adds logging
class LoggingUserRepository
  def initialize(repository, logger:)
    @repository = repository
    @logger = logger
  end

  def find(id)
    @logger.info("Looking up user #{id}")
    result = @repository.find(id)
    @logger.info("Found user: #{result[:name]}")
    result
  end
end

# Compose decorators
repo = LoggingUserRepository.new(
  CachingUserRepository.new(
    UserRepository.new,
    cache: Redis.new
  ),
  logger: Logger.new(STDOUT)
)
repo.find(42)  # logs, then checks cache, then hits DB if needed
```

Ruby-idiomatic alternative: use `Module#prepend` or `SimpleDelegator`.

```ruby
# Using SimpleDelegator
class CachingUserRepository < SimpleDelegator
  def initialize(repository, cache:)
    super(repository)
    @cache = cache
  end

  def find(id)
    @cache.fetch("user:#{id}") { super }
  end
end
```

---

## Modeling Real-World Systems

### Interview Approach

1. **Clarify requirements** (3-5 min): ask about scope, scale, and use cases. "Should the parking lot support multiple floors? What types of vehicles? Do we need payment processing?"
2. **Identify core entities** (5 min): nouns in the problem become classes. Verbs become methods.
3. **Define relationships** (5 min): has-a vs is-a. Prefer composition over inheritance.
4. **Write the interfaces first** (10 min): define the public API of each class before implementation.
5. **Implement key methods** (15-20 min): focus on the most interesting logic. Skip boilerplate.
6. **Discuss extensions** (5 min): how would you add feature X? Where are the extension points?

### Key Modeling Heuristics

- **Prefer composition over inheritance.** Inheritance creates tight coupling. Composition via delegation is more flexible. Use inheritance only for genuine "is-a" relationships.
- **Keep classes small.** If a class has more than 5-7 public methods, it is probably doing too much.
- **Use value objects for things without identity.** A `Money` amount, a `DateRange`, or a `Coordinate` should be immutable value objects, not entities.
- **Separate command and query.** Methods that change state should not return data, and vice versa (with pragmatic exceptions).
- **Model state machines explicitly.** If an object has states (order: pending -> paid -> shipped -> delivered), use an explicit state machine rather than boolean flags.

```ruby
# Value object example
class Money
  include Comparable

  attr_reader :amount, :currency

  def initialize(amount, currency = :usd)
    @amount = amount.round(2)
    @currency = currency
    freeze  # immutable
  end

  def +(other)
    raise "Currency mismatch" unless @currency == other.currency
    Money.new(@amount + other.amount, @currency)
  end

  def *(multiplier)
    Money.new(@amount * multiplier, @currency)
  end

  def <=>(other)
    raise "Currency mismatch" unless @currency == other.currency
    @amount <=> other.amount
  end

  def to_s
    "$#{format('%.2f', @amount)}"
  end
end
```

---

## Common OOD Interview Problems

### Parking Lot

Key entities: `ParkingLot`, `Level`, `Spot`, `Vehicle` (with subtypes: `Car`, `Truck`, `Motorcycle`), `Ticket`.

Key decisions: spot assignment strategy (first available? closest to entrance?), how to handle different vehicle sizes, payment integration.

### Elevator System

Key entities: `Elevator`, `ElevatorController`, `Floor`, `Request`.

Key decisions: scheduling algorithm (SCAN, LOOK, SSTF), handling multiple elevators, peak vs off-peak strategies.

### Card Game (e.g., Blackjack)

Key entities: `Deck`, `Card`, `Hand`, `Player`, `Dealer`, `Game`.

Key decisions: strategy pattern for player decisions, observer for game events, state machine for game flow.

### Library Management

Key entities: `Book`, `Member`, `Loan`, `Catalog`, `SearchService`.

Key decisions: search strategy (by title, author, ISBN), reservation system, late fee calculation.

---

## Exercises

- [[exercises/INSTRUCTIONS|E-Commerce Order System Design]] -- Design and implement an order processing system with products, carts, orders, payments, and fulfillment. Includes a buggy starter implementation for code review.

## Related Topics

- [[../api-design/index|API Design]] -- API design is the external expression of your OOD
- [[../testing-and-quality/index|Testing & Quality]] -- good OOD makes testing easy; hard-to-test code is often poorly designed
- [[../system-design/index|System Design]] -- OOD at the class level scales to service-level design
