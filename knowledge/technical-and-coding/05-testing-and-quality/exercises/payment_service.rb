# frozen_string_literal: true

require 'securerandom'
require 'json'
require 'net/http'
require 'openssl'
require 'logger'

# Payment Service: handles charges, refunds, and webhook processing
# with retry logic, idempotency, and event tracking.
#
# Dependencies:
#   - gateway: external payment API client
#   - store: persistence layer for payments and idempotency keys
#   - logger: structured logging
#   - event_bus: publishes domain events

class PaymentService
  MAX_RETRIES = 3
  RETRY_DELAYS = [1, 5, 25].freeze  # seconds
  WEBHOOK_TOLERANCE = 300  # 5 minutes

  class PaymentError < StandardError; end
  class GatewayError < PaymentError; end
  class DuplicateChargeError < PaymentError; end
  class InvalidWebhookError < PaymentError; end
  class RefundError < PaymentError; end

  attr_reader :store

  def initialize(gateway:, store:, event_bus:, logger: Logger.new(STDOUT),
                 clock: Time)
    @gateway = gateway
    @store = store
    @event_bus = event_bus
    @logger = logger
    @clock = clock
  end

  # Create a charge with idempotency support.
  #
  # @param order_id [String] unique order identifier
  # @param amount [Integer] amount in cents (e.g., 1999 = $19.99)
  # @param currency [String] ISO currency code (default: 'usd')
  # @param idempotency_key [String] client-provided key for deduplication
  # @param metadata [Hash] arbitrary metadata to attach to the charge
  # @return [Hash] { id:, status:, amount:, currency: }
  # @raise [PaymentError] if charge fails after all retries
  # @raise [DuplicateChargeError] if idempotency key already used
  def charge(order_id:, amount:, currency: 'usd', idempotency_key: nil,
             metadata: {})
    validate_charge_params!(order_id, amount, currency)

    idem_key = idempotency_key || "charge:#{order_id}"

    # Check idempotency
    existing = @store.get_by_idempotency_key(idem_key)
    if existing
      @logger.info("Duplicate charge detected", idempotency_key: idem_key)
      raise DuplicateChargeError, "Charge already exists for key: #{idem_key}"
    end

    # Create payment record
    payment = {
      id: SecureRandom.uuid,
      order_id: order_id,
      amount: amount,
      currency: currency,
      status: 'pending',
      idempotency_key: idem_key,
      metadata: metadata,
      created_at: @clock.now,
      gateway_id: nil,
      error: nil
    }
    @store.save_payment(payment)

    # Attempt charge with retries
    result = with_retries do
      @gateway.create_charge(
        amount: amount,
        currency: currency,
        idempotency_key: idem_key,
        metadata: metadata.merge(order_id: order_id)
      )
    end

    # Update payment record
    payment[:gateway_id] = result[:id]
    payment[:status] = 'succeeded'
    @store.update_payment(payment[:id], payment)

    # Publish event
    @event_bus.publish('payment.succeeded', {
      payment_id: payment[:id],
      order_id: order_id,
      amount: amount,
      currency: currency
    })

    @logger.info("Charge succeeded",
                 payment_id: payment[:id], order_id: order_id, amount: amount)

    { id: payment[:id], status: 'succeeded', amount: amount, currency: currency }

  rescue GatewayError => e
    payment[:status] = 'failed'
    payment[:error] = e.message
    @store.update_payment(payment[:id], payment) if payment[:id]

    @event_bus.publish('payment.failed', {
      payment_id: payment[:id],
      order_id: order_id,
      error: e.message
    })

    @logger.error("Charge failed",
                  payment_id: payment[:id], order_id: order_id, error: e.message)

    raise
  end

  # Refund a previous charge.
  #
  # @param payment_id [String] ID of the payment to refund
  # @param amount [Integer, nil] partial refund amount (nil = full refund)
  # @param reason [String] reason for refund
  # @return [Hash] { id:, status:, amount:, refund_id: }
  # @raise [RefundError] if payment not found or not refundable
  def refund(payment_id:, amount: nil, reason: 'requested_by_customer')
    payment = @store.get_payment(payment_id)
    raise RefundError, "Payment not found: #{payment_id}" unless payment
    raise RefundError, "Payment not in refundable state: #{payment[:status]}" unless payment[:status] == 'succeeded'

    refund_amount = amount || payment[:amount]
    raise RefundError, "Refund amount exceeds charge" if refund_amount > payment[:amount]
    raise RefundError, "Refund amount must be positive" if refund_amount <= 0

    result = with_retries do
      @gateway.create_refund(
        charge_id: payment[:gateway_id],
        amount: refund_amount,
        reason: reason
      )
    end

    payment[:status] = refund_amount == payment[:amount] ? 'refunded' : 'partially_refunded'
    payment[:refund_id] = result[:id]
    payment[:refund_amount] = refund_amount
    @store.update_payment(payment_id, payment)

    @event_bus.publish('payment.refunded', {
      payment_id: payment_id,
      refund_amount: refund_amount,
      reason: reason
    })

    @logger.info("Refund succeeded",
                 payment_id: payment_id, amount: refund_amount)

    { id: payment_id, status: payment[:status],
      amount: refund_amount, refund_id: result[:id] }
  end

  # Process a webhook event from the payment gateway.
  #
  # @param payload [String] raw request body
  # @param signature [String] webhook signature header
  # @param webhook_secret [String] shared secret for verification
  # @return [Hash] { event_type:, processed: }
  # @raise [InvalidWebhookError] if signature is invalid or event is stale
  def process_webhook(payload:, signature:, webhook_secret:)
    verify_webhook_signature!(payload, signature, webhook_secret)

    event = JSON.parse(payload, symbolize_names: true)

    # Check for duplicate events
    if @store.webhook_processed?(event[:id])
      @logger.info("Duplicate webhook skipped", event_id: event[:id])
      return { event_type: event[:type], processed: false, reason: 'duplicate' }
    end

    case event[:type]
    when 'charge.succeeded'
      handle_charge_succeeded(event)
    when 'charge.failed'
      handle_charge_failed(event)
    when 'charge.disputed'
      handle_charge_disputed(event)
    when 'refund.succeeded'
      handle_refund_succeeded(event)
    else
      @logger.warn("Unknown webhook event type", type: event[:type])
    end

    @store.mark_webhook_processed(event[:id])
    { event_type: event[:type], processed: true }
  end

  # Get payment status and history.
  def get_payment(payment_id)
    @store.get_payment(payment_id)
  end

  # List payments for an order.
  def list_payments(order_id:, status: nil)
    payments = @store.list_payments_by_order(order_id)
    payments = payments.select { |p| p[:status] == status } if status
    payments
  end

  private

  def validate_charge_params!(order_id, amount, currency)
    raise PaymentError, "order_id is required" if order_id.nil? || order_id.empty?
    raise PaymentError, "amount must be a positive integer" unless amount.is_a?(Integer) && amount > 0
    raise PaymentError, "currency must be a 3-letter code" unless currency.match?(/\A[a-z]{3}\z/)
  end

  def with_retries(&block)
    attempts = 0
    begin
      attempts += 1
      block.call
    rescue GatewayError => e
      if attempts <= MAX_RETRIES && retryable?(e)
        delay = RETRY_DELAYS[attempts - 1] || RETRY_DELAYS.last
        @logger.warn("Retrying after gateway error",
                     attempt: attempts, delay: delay, error: e.message)
        sleep(delay)
        retry
      end
      raise
    end
  end

  def retryable?(error)
    # Retry on timeouts and 5xx errors, not on 4xx
    error.message.include?('timeout') ||
      error.message.include?('5') ||
      error.message.include?('connection')
  end

  def verify_webhook_signature!(payload, signature, secret)
    expected = OpenSSL::HMAC.hexdigest('SHA256', secret, payload)
    unless secure_compare(expected, signature)
      raise InvalidWebhookError, "Invalid webhook signature"
    end

    # Check timestamp to prevent replay attacks
    event = JSON.parse(payload, symbolize_names: true)
    event_time = event[:created_at]
    if event_time && (@clock.now.to_i - event_time) > WEBHOOK_TOLERANCE
      raise InvalidWebhookError, "Webhook event is stale (older than #{WEBHOOK_TOLERANCE}s)"
    end
  end

  def secure_compare(a, b)
    return false unless a.bytesize == b.bytesize
    l = a.unpack("C*")
    r = b.unpack("C*")
    result = 0
    l.zip(r) { |x, y| result |= x ^ y }
    result == 0
  end

  def handle_charge_succeeded(event)
    payment = @store.get_by_gateway_id(event[:data][:charge_id])
    return unless payment

    payment[:status] = 'succeeded'
    @store.update_payment(payment[:id], payment)
    @event_bus.publish('payment.confirmed', { payment_id: payment[:id] })
  end

  def handle_charge_failed(event)
    payment = @store.get_by_gateway_id(event[:data][:charge_id])
    return unless payment

    payment[:status] = 'failed'
    payment[:error] = event[:data][:failure_reason]
    @store.update_payment(payment[:id], payment)
    @event_bus.publish('payment.failed', {
      payment_id: payment[:id],
      error: event[:data][:failure_reason]
    })
  end

  def handle_charge_disputed(event)
    payment = @store.get_by_gateway_id(event[:data][:charge_id])
    return unless payment

    payment[:status] = 'disputed'
    @store.update_payment(payment[:id], payment)
    @event_bus.publish('payment.disputed', {
      payment_id: payment[:id],
      reason: event[:data][:reason]
    })
  end

  def handle_refund_succeeded(event)
    payment = @store.get_by_gateway_id(event[:data][:charge_id])
    return unless payment

    payment[:status] = 'refunded'
    @store.update_payment(payment[:id], payment)
  end
end
