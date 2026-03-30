# frozen_string_literal: true

# Test suite stubs for PaymentService.
# Implement all the test cases below.
# Use the in-memory fakes provided for the store and gateway.

require 'rspec'
require_relative 'payment_service'

# ============================================================
# In-Memory Fakes (use these, don't mock the store)
# ============================================================

class FakePaymentStore
  def initialize
    @payments = {}
    @processed_webhooks = Set.new
  end

  def save_payment(payment)
    @payments[payment[:id]] = payment.dup
  end

  def get_payment(id)
    @payments[id]&.dup
  end

  def update_payment(id, attrs)
    @payments[id]&.merge!(attrs)
  end

  def get_by_idempotency_key(key)
    @payments.values.find { |p| p[:idempotency_key] == key }
  end

  def get_by_gateway_id(gateway_id)
    @payments.values.find { |p| p[:gateway_id] == gateway_id }
  end

  def list_payments_by_order(order_id)
    @payments.values.select { |p| p[:order_id] == order_id }
  end

  def webhook_processed?(event_id)
    @processed_webhooks.include?(event_id)
  end

  def mark_webhook_processed(event_id)
    @processed_webhooks.add(event_id)
  end
end

class FakeGateway
  attr_reader :charges, :refunds

  def initialize
    @charges = []
    @refunds = []
    @should_fail = false
    @failure_message = nil
    @fail_count = 0
    @current_failures = 0
  end

  def create_charge(amount:, currency:, idempotency_key:, metadata: {})
    maybe_fail!
    charge = { id: "ch_#{SecureRandom.hex(8)}", amount: amount,
               currency: currency, status: 'succeeded' }
    @charges << charge
    charge
  end

  def create_refund(charge_id:, amount:, reason: nil)
    maybe_fail!
    refund = { id: "re_#{SecureRandom.hex(8)}", charge_id: charge_id,
               amount: amount, status: 'succeeded' }
    @refunds << refund
    refund
  end

  # Test helpers
  def fail_next!(message = 'Gateway timeout', count: 1)
    @should_fail = true
    @failure_message = message
    @fail_count = count
    @current_failures = 0
  end

  def fail_permanently!(message = 'Card declined')
    @should_fail = true
    @failure_message = message
    @fail_count = Float::INFINITY
  end

  private

  def maybe_fail!
    if @should_fail && @current_failures < @fail_count
      @current_failures += 1
      @should_fail = false if @current_failures >= @fail_count
      raise PaymentService::GatewayError, @failure_message
    end
  end
end

class FakeEventBus
  attr_reader :events

  def initialize
    @events = []
  end

  def publish(event_type, data)
    @events << { type: event_type, data: data }
  end

  def events_of_type(type)
    @events.select { |e| e[:type] == type }
  end
end

class FakeClock
  attr_accessor :current_time

  def initialize(time = Time.now)
    @current_time = time
  end

  def now
    @current_time
  end

  def advance(seconds)
    @current_time += seconds
  end
end

# ============================================================
# Test Suite -- Implement these tests
# ============================================================

RSpec.describe PaymentService do
  let(:gateway) { FakeGateway.new }
  let(:store) { FakePaymentStore.new }
  let(:event_bus) { FakeEventBus.new }
  let(:logger) { Logger.new(StringIO.new) }
  let(:clock) { FakeClock.new(Time.new(2025, 6, 15, 12, 0, 0)) }

  subject(:service) do
    described_class.new(
      gateway: gateway,
      store: store,
      event_bus: event_bus,
      logger: logger,
      clock: clock
    )
  end

  # ---- Charge: Happy Path ----

  describe '#charge' do
    context 'successful charge' do
      # TODO: implement these tests

      it 'returns a success result with payment id and amount'

      it 'persists the payment record with succeeded status'

      it 'publishes a payment.succeeded event'

      it 'calls the gateway with correct parameters'
    end

    # ---- Charge: Validation ----

    context 'input validation' do
      it 'raises PaymentError for nil order_id'

      it 'raises PaymentError for zero amount'

      it 'raises PaymentError for negative amount'

      it 'raises PaymentError for non-integer amount'

      it 'raises PaymentError for invalid currency code'
    end

    # ---- Charge: Idempotency ----

    context 'idempotency' do
      it 'raises DuplicateChargeError for same idempotency key'

      it 'uses order_id as default idempotency key'

      it 'allows same order_id with different explicit idempotency keys'
    end

    # ---- Charge: Retries ----

    context 'retry behavior' do
      it 'retries on gateway timeout and succeeds'

      it 'retries up to MAX_RETRIES times then raises'

      it 'does not retry on non-retryable errors (e.g., card declined)'

      it 'marks payment as failed after all retries exhausted'

      it 'publishes payment.failed event on failure'
    end
  end

  # ---- Refund ----

  describe '#refund' do
    # Helper: create a successful charge first
    let(:charge_result) do
      service.charge(order_id: 'order-1', amount: 5000)
    end

    context 'successful refund' do
      it 'refunds the full amount'

      it 'supports partial refund'

      it 'updates payment status to refunded'

      it 'publishes payment.refunded event'
    end

    context 'refund validation' do
      it 'raises RefundError for non-existent payment'

      it 'raises RefundError for payment not in succeeded state'

      it 'raises RefundError when refund amount exceeds charge'

      it 'raises RefundError for zero refund amount'
    end
  end

  # ---- Webhook Processing ----

  describe '#process_webhook' do
    let(:webhook_secret) { 'whsec_test123' }

    def signed_payload(event)
      payload = event.to_json
      signature = OpenSSL::HMAC.hexdigest('SHA256', webhook_secret, payload)
      [payload, signature]
    end

    context 'valid webhooks' do
      it 'processes charge.succeeded event'

      it 'processes charge.failed event'

      it 'skips duplicate events'

      it 'handles unknown event types gracefully'
    end

    context 'webhook security' do
      it 'rejects invalid signature'

      it 'rejects stale events (older than tolerance)'

      it 'accepts events within tolerance window'
    end
  end

  # ---- Query Methods ----

  describe '#list_payments' do
    it 'returns all payments for an order'

    it 'filters by status when specified'

    it 'returns empty array when no payments exist'
  end
end
