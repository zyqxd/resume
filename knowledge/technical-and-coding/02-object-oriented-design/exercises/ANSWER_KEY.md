# Answer Key -- E-Commerce Order System

---

## SOLID Violations

### 1. Product has rendering responsibilities (SRP) -- Lines 38-48
**Severity: P2 -- maintainability**

`Product` has `to_html`, `to_json`, and `to_csv` methods. Adding a new output format requires modifying `Product`. Rendering should be in dedicated serializer/presenter classes.

```ruby
# FIX: Extract to presenters
class ProductHtmlPresenter
  def initialize(product)
    @product = product
  end

  def render
    "<div class='product'><h2>#{@product.name}</h2><p>$#{@product.price}</p></div>"
  end
end
```

### 2. Product manages its own stock (SRP) -- Lines 52-59
**Severity: P1 -- design flaw**

Stock management involves concurrency concerns, warehouse tracking, and reservation logic. It should not live on the Product model, which is a value/entity class.

```ruby
# FIX: Extract InventoryService
class InventoryService
  def reserve(product_id, quantity)
    # atomic operation with locking
  end

  def release(product_id, quantity); end
end
```

### 3. ShoppingCart calculates shipping (SRP) -- Lines 99-111
**Severity: P2 -- maintainability**

Shipping calculation is a complex domain with carriers, zones, weights, and dimensions. It should be a separate `ShippingCalculator` with a strategy pattern for different carriers.

### 4. ShoppingCart handles coupons (SRP) -- Lines 118-131
**Severity: P2 -- maintainability**

Coupon logic (validation, application, stacking rules) is its own domain. Extract to `CouponService`.

### 5. Order contains all processing logic (SRP/OCP) -- Lines 146-162
**Severity: P1 -- design flaw**

`Order#process` orchestrates validation, inventory, payments, and emails. This should be an `OrderProcessor` service. The Order should be a data object with state.

### 6. Order has hard dependency on payment processor (DIP) -- Lines 187-213
**Severity: P1 -- design flaw**

`charge_payment` contains concrete HTTP calls to specific payment providers. Adding a new payment method requires modifying `Order`. Should inject a `PaymentGateway` via DIP.

```ruby
# FIX: Strategy pattern for payment
class PaymentGateway
  def charge(amount, payment_method); raise NotImplementedError; end
  def refund(order_id, amount); raise NotImplementedError; end
end

class StripeGateway < PaymentGateway
  def charge(amount, payment_method)
    # Stripe-specific API call
  end
end
```

### 7. Order sends emails directly (SRP) -- Lines 225-255
**Severity: P2 -- coupling**

Order should emit events (`:confirmed`, `:cancelled`, `:shipped`). A separate listener/observer sends emails. This decouples order processing from notification logic.

### 8. NotificationService violates ISP -- Lines 260-284
**Severity: P2 -- maintainability**

Consumers that only need email must depend on an object that also knows about SMS and push. Each channel should be a separate class behind a common interface.

### 9. DiscountEngine violates OCP -- Lines 293-316
**Severity: P1 -- design flaw**

Adding a new discount type requires modifying the `case` statement. Should use a registry of discount strategies.

```ruby
# FIX: Registry + strategy
class DiscountEngine
  @strategies = {}

  def self.register(pattern, strategy)
    @strategies[pattern] = strategy
  end

  def calculate(order, code)
    @strategies.each do |pattern, strategy|
      return strategy.apply(order, code) if code.match?(pattern)
    end
    0
  end
end
```

### 10. OrderRepository handles reporting and CSV export (SRP) -- Lines 243-259
**Severity: P2 -- maintainability**

`revenue_report` and `export_to_csv` are reporting concerns, not persistence concerns. Extract to `ReportService` or `OrderExporter`.

---

## Bugs

### 11. Floating point arithmetic for money -- Lines 166-170
**Severity: P0 -- financial data corruption**

`0.1 + 0.2 != 0.3` in floating point. All money calculations should use integer cents or `BigDecimal`.

```ruby
# FIX
require 'bigdecimal'
@total = BigDecimal(subtotal.to_s) + BigDecimal(tax.to_s)

# Better: store prices in cents (integer)
```

### 12. Product price is mutable via `attr_accessor` -- Line 8
**Severity: P1 -- data corruption**

Changing a product's price affects all existing carts and orders that hold a reference to the product. Price at time of cart/order creation should be captured as a snapshot.

```ruby
# FIX: capture price at time of addition
cart.add_item(product, quantity)
# internally stores: { product_id: product.id, price: product.price, quantity: quantity }
```

### 13. Cart stores reference to Product (not a snapshot) -- Line 79
**Severity: P1 -- data corruption**

Related to above. Cart items should store the product ID and a copy of the price, not a reference to the mutable Product object.

### 14. Order stores mutable reference to cart items -- Line 140
**Severity: P1 -- data corruption**

If the cart is modified after order creation, the order's items change too. Should deep-copy items.

```ruby
# FIX
@items = items.map { |i| i.dup }
```

### 15. No check for quantity > 0 in `reserve_stock` -- Line 53
**Severity: P2 -- allows negative stock reservation**

### 16. `update_quantity` has no nil check -- Line 90
**Severity: P1 -- NoMethodError crash**

```ruby
# BUG
item[:quantity] = quantity  # item could be nil

# FIX
raise ArgumentError, "Item not found: #{product_id}" unless item
raise ArgumentError, "Quantity must be positive" unless quantity > 0
```

### 17. Zero or negative quantity allowed in `update_quantity` -- Line 91
**Severity: P2 -- allows zero-quantity items in cart**

### 18. Cancel has no state guard -- Line 153
**Severity: P0 -- can cancel shipped/delivered orders**

```ruby
# FIX
def cancel
  raise "Cannot cancel #{@status} order" unless %i[pending confirmed].include?(@status)
  # ...
end
```

### 19. Partial inventory reservation on failure -- Lines 172-178
**Severity: P0 -- inventory leak**

If the third product fails to reserve, the first two are already reserved but only the third is released. The rescue block releases ALL items including those that were never reserved.

```ruby
# FIX: track which items were reserved
reserved = []
@items.each do |item|
  if item[:product].reserve_stock(item[:quantity])
    reserved << item
  else
    reserved.each { |r| r[:product].release_stock(r[:quantity]) }
    raise "Insufficient stock for #{item[:product].name}"
  end
end
```

### 20. Credit card data stored in plain text -- Line 195
**Severity: P0 -- security**

The order object stores full card number, expiry, and CVV. This violates PCI-DSS. Should use a payment token from the gateway.

### 21. Refund is not idempotent -- Lines 218-224
**Severity: P1 -- double refund**

Calling `cancel` twice issues two refund API calls. Should track whether a refund has been issued.

### 22. `user_id` used as email recipient -- Line 230
**Severity: P1 -- emails never arrive**

`user_id` is "user-123", not an email address.

### 23. No error handling on HTTP calls in NotificationService -- Lines 260-284
**Severity: P1 -- silent failures**

### 24. Discount can exceed order total -- Line 303
**Severity: P1 -- negative total**

`FLAT9999` on a $50 order gives a -$9949 total.

```ruby
# FIX
[amount, order.total].min
```

### 25. PERCENT discount has no cap -- Line 299
**Severity: P1 -- order is free**

`PERCENT100` gives 100% off. Should cap at a maximum percentage or dollar amount.

### 26. Coupon validation missing -- Lines 318-320
**Severity: P1 -- unlimited coupon reuse**

No expiry check, no single-use enforcement, no minimum order validation.

### 27. File persistence is not atomic -- Line 271
**Severity: P1 -- data loss**

If the process crashes during `File.write`, the file is corrupted. Should write to a temp file and then atomic rename.

### 28. Tax rate hardcoded per category, not jurisdiction -- Lines 22-28
**Severity: P2 -- incorrect tax**

Tax depends on shipping destination, not product category. Electronics sold to Oregon (no sales tax) should be tax-free.

---

## Summary by Category

| Category | Count | P0 | P1 | P2 |
|---|---|---|---|---|
| SOLID Violations | 10 | 0 | 4 | 6 |
| Bugs | 12 | 4 | 6 | 2 |
| Design Flaws | 6 | 0 | 2 | 4 |
| **Total** | **28** | **4** | **12** | **12** |

---

## Part 2: Extension Design

### Subscription Orders

Add a `SubscriptionOrder` that holds a `billing_cycle` (monthly, yearly), `next_charge_date`, and references a base order template. Use the Strategy pattern for billing: `MonthlyBilling`, `YearlyBilling`. A `SubscriptionProcessor` cron job queries for subscriptions where `next_charge_date <= now`, creates a new Order from the template, processes it, and advances `next_charge_date`.

Key classes:
- `Subscription` (entity: user, product, billing strategy, status)
- `BillingStrategy` (interface: `next_date(current_date)`)
- `SubscriptionProcessor` (service: runs periodically)

The Order class does not change. Subscription creates Orders.

### Gift Cards

Add a `GiftCard` class (code, balance, expiry). Implement a `GiftCardPaymentGateway` that implements the same `PaymentGateway` interface. The gateway deducts from the gift card balance.

Key decision: gift card charges are internal (no external API call). The gateway checks balance, deducts, and records the transaction.

### Split Payments

Change `PaymentGateway#charge` to accept an array of `PaymentAllocation` objects, each specifying a gateway and an amount. The `OrderProcessor` iterates allocations and charges each. If one fails, it refunds all previously charged allocations (saga pattern).

```ruby
class PaymentAllocation
  attr_reader :gateway, :amount

  def initialize(gateway:, amount:)
    @gateway = gateway
    @amount = amount
  end
end

class SplitPaymentProcessor
  def charge(allocations)
    charged = []
    allocations.each do |alloc|
      alloc.gateway.charge(alloc.amount)
      charged << alloc
    rescue => e
      # Compensate: refund everything already charged
      charged.each { |c| c.gateway.refund(c.amount) }
      raise
    end
  end
end
```
