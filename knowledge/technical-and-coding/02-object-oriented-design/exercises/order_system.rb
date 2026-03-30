# frozen_string_literal: true

# E-Commerce Order Processing System
#
# Review this code for SOLID violations, design flaws, bugs, and
# opportunities for better patterns. There are 28+ issues.

require 'securerandom'
require 'json'
require 'net/http'
require 'date'

# ============================================================
# Product & Inventory
# ============================================================

class Product
  attr_accessor :id, :name, :price, :category, :weight,
                :stock_count, :description, :tax_rate

  def initialize(id:, name:, price:, category:, weight: 0, stock_count: 0)
    @id = id
    @name = name
    @price = price
    @category = category
    @weight = weight
    @stock_count = stock_count
    @description = ""
    # B: Tax rate hardcoded per product -- should be calculated by jurisdiction
    @tax_rate = case category
                when :electronics then 0.08
                when :clothing then 0.05
                when :food then 0.0
                else 0.07
                end
  end

  # SOLID(SRP): Product should not know how to render itself for different formats
  def to_html
    "<div class='product'><h2>#{@name}</h2><p>$#{@price}</p></div>"
  end

  def to_json(*_args)
    { id: @id, name: @name, price: @price, category: @category }.to_json
  end

  def to_csv
    "#{@id},#{@name},#{@price},#{@category}"
  end

  # SOLID(SRP): Product managing its own stock
  def reserve_stock(quantity)
    # B: No check that quantity > 0
    if @stock_count >= quantity
      @stock_count -= quantity
      true
    else
      false
    end
  end

  def release_stock(quantity)
    @stock_count += quantity
  end

  # B: Price is mutable via attr_accessor -- changing it affects existing orders
  def apply_discount(percentage)
    @price = @price * (1 - percentage / 100.0)
  end
end

# ============================================================
# Shopping Cart
# ============================================================

class ShoppingCart
  attr_reader :items, :user_id

  def initialize(user_id)
    @user_id = user_id
    @items = []  # B: Should be a hash keyed by product_id for O(1) lookup
  end

  def add_item(product, quantity = 1)
    existing = @items.find { |item| item[:product].id == product.id }
    if existing
      existing[:quantity] += quantity
    else
      # B: Stores reference to Product -- if product price changes, cart changes
      @items << { product: product, quantity: quantity }
    end
  end

  def remove_item(product_id)
    @items.reject! { |item| item[:product].id == product_id }
  end

  def update_quantity(product_id, quantity)
    item = @items.find { |i| i[:product].id == product_id }
    # B: No nil check on item
    # B: No check that quantity > 0 (0 or negative quantity allowed)
    item[:quantity] = quantity
  end

  def subtotal
    @items.sum { |item| item[:product].price * item[:quantity] }
  end

  def tax
    @items.sum { |item| item[:product].price * item[:quantity] * item[:product].tax_rate }
  end

  # SOLID(SRP): Cart calculates shipping -- should be a ShippingCalculator
  def shipping_cost
    total_weight = @items.sum { |item| item[:product].weight * item[:quantity] }
    # B: Hardcoded shipping tiers -- not configurable, no international shipping
    if total_weight < 1
      5.99
    elsif total_weight < 5
      9.99
    elsif total_weight < 20
      14.99
    else
      24.99
    end
  end

  def total
    subtotal + tax + shipping_cost
  end

  # SOLID(SRP): Cart should not apply coupons -- separate concern
  def apply_coupon(code)
    # B: Hardcoded coupon logic in cart
    case code
    when "SAVE10"
      @discount = subtotal * 0.10
    when "FLAT20"
      @discount = 20.0
    when "FREESHIP"
      @free_shipping = true
    else
      raise "Invalid coupon: #{code}"
    end
  end

  def clear
    @items = []
    @discount = nil
    @free_shipping = nil
  end
end

# ============================================================
# Order
# ============================================================

class Order
  attr_accessor :id, :user_id, :items, :status, :shipping_address,
                :billing_address, :payment_method, :total, :created_at,
                :updated_at, :tracking_number, :notes

  # B: Too many constructor params -- should use builder or keyword args
  def initialize(user_id, items, shipping_address, billing_address, payment_method)
    @id = SecureRandom.uuid
    @user_id = user_id
    @items = items  # B: stores mutable reference to cart items
    @status = :pending
    @shipping_address = shipping_address
    @billing_address = billing_address
    @payment_method = payment_method
    @total = 0
    @created_at = Time.now
    @updated_at = Time.now
    @tracking_number = nil
    @notes = []
  end

  # SOLID(OCP/SRP): Order should not contain all processing logic
  def process
    validate!
    calculate_total
    reserve_inventory
    charge_payment
    send_confirmation
    @status = :confirmed
    @updated_at = Time.now
  rescue => e
    @status = :failed
    @notes << "Processing failed: #{e.message}"
    release_inventory
    raise
  end

  def cancel
    # B: Can cancel in any state -- should only cancel pending/confirmed orders
    @status = :cancelled
    release_inventory
    refund_payment
    send_cancellation_email
    @updated_at = Time.now
  end

  def ship(tracking_number)
    @tracking_number = tracking_number
    @status = :shipped
    send_shipping_notification
    @updated_at = Time.now
  end

  def deliver
    @status = :delivered
    @updated_at = Time.now
  end

  private

  def validate!
    raise "No items in order" if @items.empty?
    raise "No shipping address" unless @shipping_address
    raise "No payment method" unless @payment_method
    # B: No validation of item availability at order time
    # B: No validation of addresses (format, deliverability)
  end

  def calculate_total
    subtotal = @items.sum { |item| item[:product].price * item[:quantity] }
    tax = @items.sum do |item|
      item[:product].price * item[:quantity] * item[:product].tax_rate
    end
    # B: Floating point arithmetic for money -- use BigDecimal or integer cents
    @total = subtotal + tax
  end

  def reserve_inventory
    @items.each do |item|
      unless item[:product].reserve_stock(item[:quantity])
        # B: Partial reservation -- some items reserved before failure,
        # but only releases from this point forward, not already-reserved items
        raise "Insufficient stock for #{item[:product].name}"
      end
    end
  end

  def release_inventory
    @items.each do |item|
      item[:product].release_stock(item[:quantity])
    end
  end

  # SOLID(DIP): Hard dependency on specific payment processor
  def charge_payment
    case @payment_method[:type]
    when :credit_card
      # B: Sensitive card data stored in order object in plain text
      response = Net::HTTP.post(
        URI("https://payments.example.com/charge"),
        {
          card_number: @payment_method[:card_number],
          expiry: @payment_method[:expiry],
          cvv: @payment_method[:cvv],
          amount: @total
        }.to_json,
        "Content-Type" => "application/json"
      )
      raise "Payment failed" unless response.code == "200"
    when :paypal
      # B: Different payment code path with different error handling
      response = Net::HTTP.post(
        URI("https://paypal.example.com/pay"),
        { email: @payment_method[:email], amount: @total }.to_json,
        "Content-Type" => "application/json"
      )
      raise "PayPal payment failed" unless response.code == "200"
    else
      raise "Unsupported payment method: #{@payment_method[:type]}"
    end
  end

  def refund_payment
    # B: No idempotency -- calling cancel twice refunds twice
    # B: Assumes payment was actually charged (what if it failed mid-process?)
    Net::HTTP.post(
      URI("https://payments.example.com/refund"),
      { order_id: @id, amount: @total }.to_json,
      "Content-Type" => "application/json"
    )
  end

  # SOLID(SRP): Order should not send emails
  def send_confirmation
    Net::HTTP.post(
      URI("https://email.example.com/send"),
      {
        to: @user_id,  # B: user_id is not an email address
        template: "order_confirmation",
        data: { order_id: @id, total: @total }
      }.to_json,
      "Content-Type" => "application/json"
    )
  end

  def send_cancellation_email
    Net::HTTP.post(
      URI("https://email.example.com/send"),
      { to: @user_id, template: "order_cancelled", data: { order_id: @id } }.to_json,
      "Content-Type" => "application/json"
    )
  end

  def send_shipping_notification
    Net::HTTP.post(
      URI("https://email.example.com/send"),
      {
        to: @user_id,
        template: "shipping_notification",
        data: { order_id: @id, tracking: @tracking_number }
      }.to_json,
      "Content-Type" => "application/json"
    )
  end
end

# ============================================================
# Order Repository (persistence)
# ============================================================

class OrderRepository
  def initialize
    @orders = {}
    @file_path = "orders.json"
  end

  def save(order)
    @orders[order.id] = order
    persist_to_file
  end

  def find(id)
    @orders[id]
  end

  def find_by_user(user_id)
    @orders.values.select { |o| o.user_id == user_id }
  end

  # SOLID(SRP): Repository also handles reporting
  def revenue_report(start_date, end_date)
    orders = @orders.values.select do |o|
      o.status == :confirmed && o.created_at.between?(start_date, end_date)
    end

    {
      total_revenue: orders.sum(&:total),
      order_count: orders.count,
      average_order_value: orders.empty? ? 0 : orders.sum(&:total) / orders.count,
      # B: Floating point division for money
      top_products: calculate_top_products(orders)
    }
  end

  # SOLID(SRP): Repository should not generate CSV exports
  def export_to_csv
    csv = "id,user_id,status,total,created_at\n"
    @orders.values.each do |order|
      csv += "#{order.id},#{order.user_id},#{order.status},#{order.total},#{order.created_at}\n"
    end
    File.write("orders_export.csv", csv)
  end

  private

  def persist_to_file
    # B: Serializes entire order graph including product references
    # B: Not atomic -- partial write on crash corrupts the file
    File.write(@file_path, @orders.to_json)
  end

  def calculate_top_products(orders)
    product_sales = Hash.new(0)
    orders.each do |order|
      order.items.each do |item|
        product_sales[item[:product].name] += item[:quantity]
      end
    end
    product_sales.sort_by { |_, v| -v }.first(10)
  end
end

# ============================================================
# Notification Service
# ============================================================

# SOLID(ISP): This class has methods for every channel -- should be separate
class NotificationService
  def send_email(to, subject, body)
    Net::HTTP.post(
      URI("https://email.example.com/send"),
      { to: to, subject: subject, body: body }.to_json,
      "Content-Type" => "application/json"
    )
  end

  def send_sms(phone, message)
    Net::HTTP.post(
      URI("https://sms.example.com/send"),
      { phone: phone, message: message }.to_json,
      "Content-Type" => "application/json"
    )
  end

  def send_push(device_token, title, body)
    Net::HTTP.post(
      URI("https://push.example.com/send"),
      { token: device_token, title: title, body: body }.to_json,
      "Content-Type" => "application/json"
    )
  end

  # B: No error handling on any HTTP calls
  # B: No retry logic for transient failures
  # B: Synchronous -- blocks the caller while sending
end

# ============================================================
# Discount Engine
# ============================================================

class DiscountEngine
  # SOLID(OCP): Adding a new discount type requires modifying this method
  def calculate_discount(order, coupon_code)
    case coupon_code
    when /^PERCENT(\d+)$/
      percentage = $1.to_i
      # B: No cap -- PERCENT100 gives everything free
      order.total * (percentage / 100.0)
    when /^FLAT(\d+)$/
      amount = $1.to_i
      # B: Discount can exceed order total (negative total)
      amount
    when "BOGO"
      cheapest = order.items.min_by { |i| i[:product].price }
      cheapest ? cheapest[:product].price : 0
    when "LOYALTY"
      # B: Hardcoded loyalty check -- should query user service
      order.total * 0.15
    else
      0
    end
  end

  # B: No validation that coupon hasn't expired
  # B: No validation that coupon hasn't been used already
  # B: No validation of minimum order amount
end

# ============================================================
# Usage Example
# ============================================================

def main
  # Create products
  laptop = Product.new(id: 1, name: "Laptop", price: 999.99,
                       category: :electronics, weight: 3.5, stock_count: 50)
  shirt = Product.new(id: 2, name: "T-Shirt", price: 29.99,
                      category: :clothing, weight: 0.2, stock_count: 200)

  # Create cart
  cart = ShoppingCart.new("user-123")
  cart.add_item(laptop, 1)
  cart.add_item(shirt, 3)

  puts "Cart total: $#{format('%.2f', cart.total)}"

  # Create order
  order = Order.new(
    "user-123",
    cart.items,
    { street: "123 Main St", city: "Toronto", postal: "M5V 1A1" },
    { street: "123 Main St", city: "Toronto", postal: "M5V 1A1" },
    { type: :credit_card, card_number: "4111111111111111",
      expiry: "12/25", cvv: "123" }
  )

  repo = OrderRepository.new

  begin
    order.process
    repo.save(order)
    puts "Order #{order.id} confirmed!"
  rescue => e
    puts "Order failed: #{e.message}"
  end
end

main if __FILE__ == $PROGRAM_NAME
