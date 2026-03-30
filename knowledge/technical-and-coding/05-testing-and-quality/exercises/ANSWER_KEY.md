# Answer Key -- Testing a Payment Service

---

## Reference Test Suite

Below is the complete implementation of all test cases. Key design decisions are annotated.

```ruby
RSpec.describe PaymentService do
  let(:gateway) { FakeGateway.new }
  let(:store) { FakePaymentStore.new }
  let(:event_bus) { FakeEventBus.new }
  let(:logger) { Logger.new(StringIO.new) }
  let(:clock) { FakeClock.new(Time.new(2025, 6, 15, 12, 0, 0)) }

  subject(:service) do
    described_class.new(
      gateway: gateway, store: store, event_bus: event_bus,
      logger: logger, clock: clock
    )
  end

  # ============================================================
  # Charge: Happy Path
  # ============================================================

  describe '#charge' do
    context 'successful charge' do
      it 'returns a success result with payment id and amount' do
        result = service.charge(order_id: 'order-1', amount: 2999)

        expect(result[:status]).to eq('succeeded')
        expect(result[:amount]).to eq(2999)
        expect(result[:currency]).to eq('usd')
        expect(result[:id]).to match(/\A[0-9a-f-]{36}\z/)  # UUID format
      end

      it 'persists the payment record with succeeded status' do
        result = service.charge(order_id: 'order-1', amount: 2999)
        payment = store.get_payment(result[:id])

        expect(payment[:status]).to eq('succeeded')
        expect(payment[:order_id]).to eq('order-1')
        expect(payment[:amount]).to eq(2999)
        expect(payment[:gateway_id]).to start_with('ch_')
      end

      it 'publishes a payment.succeeded event' do
        result = service.charge(order_id: 'order-1', amount: 2999)
        events = event_bus.events_of_type('payment.succeeded')

        expect(events.length).to eq(1)
        expect(events.first[:data][:order_id]).to eq('order-1')
        expect(events.first[:data][:amount]).to eq(2999)
      end

      it 'calls the gateway with correct parameters' do
        service.charge(order_id: 'order-1', amount: 2999, currency: 'cad',
                       metadata: { source: 'web' })

        expect(gateway.charges.length).to eq(1)
        charge = gateway.charges.first
        expect(charge[:amount]).to eq(2999)
        expect(charge[:currency]).to eq('cad')
      end
    end

    # ============================================================
    # Charge: Validation
    # ============================================================

    context 'input validation' do
      it 'raises PaymentError for nil order_id' do
        expect { service.charge(order_id: nil, amount: 100) }
          .to raise_error(PaymentService::PaymentError, /order_id/)
      end

      it 'raises PaymentError for empty order_id' do
        expect { service.charge(order_id: '', amount: 100) }
          .to raise_error(PaymentService::PaymentError, /order_id/)
      end

      it 'raises PaymentError for zero amount' do
        expect { service.charge(order_id: 'order-1', amount: 0) }
          .to raise_error(PaymentService::PaymentError, /amount/)
      end

      it 'raises PaymentError for negative amount' do
        expect { service.charge(order_id: 'order-1', amount: -100) }
          .to raise_error(PaymentService::PaymentError, /amount/)
      end

      it 'raises PaymentError for non-integer amount' do
        expect { service.charge(order_id: 'order-1', amount: 19.99) }
          .to raise_error(PaymentService::PaymentError, /amount/)
      end

      it 'raises PaymentError for invalid currency code' do
        expect { service.charge(order_id: 'order-1', amount: 100, currency: 'US') }
          .to raise_error(PaymentService::PaymentError, /currency/)
      end

      it 'raises PaymentError for uppercase currency' do
        expect { service.charge(order_id: 'order-1', amount: 100, currency: 'USD') }
          .to raise_error(PaymentService::PaymentError, /currency/)
      end
    end

    # ============================================================
    # Charge: Idempotency
    # ============================================================

    context 'idempotency' do
      it 'raises DuplicateChargeError for same idempotency key' do
        service.charge(order_id: 'order-1', amount: 100, idempotency_key: 'key-1')

        expect { service.charge(order_id: 'order-1', amount: 100, idempotency_key: 'key-1') }
          .to raise_error(PaymentService::DuplicateChargeError)
      end

      it 'uses order_id as default idempotency key' do
        service.charge(order_id: 'order-1', amount: 100)

        # Second charge for same order without explicit key should be duplicate
        expect { service.charge(order_id: 'order-1', amount: 200) }
          .to raise_error(PaymentService::DuplicateChargeError)
      end

      it 'allows same order_id with different explicit idempotency keys' do
        # This tests the case of retrying with a new key after failure
        result1 = service.charge(order_id: 'order-1', amount: 100, idempotency_key: 'key-1')
        result2 = service.charge(order_id: 'order-1', amount: 100, idempotency_key: 'key-2')

        expect(result1[:id]).not_to eq(result2[:id])
      end

      it 'does not charge the gateway on duplicate' do
        service.charge(order_id: 'order-1', amount: 100, idempotency_key: 'key-1')

        expect { service.charge(order_id: 'order-1', amount: 100, idempotency_key: 'key-1') }
          .to raise_error(PaymentService::DuplicateChargeError)

        expect(gateway.charges.length).to eq(1)  # only one actual charge
      end
    end

    # ============================================================
    # Charge: Retries
    # ============================================================

    context 'retry behavior' do
      before do
        # Stub sleep to avoid actual delays in tests
        allow(service).to receive(:sleep)
      end

      it 'retries on gateway timeout and succeeds' do
        gateway.fail_next!('Gateway timeout', count: 1)

        result = service.charge(order_id: 'order-1', amount: 100)

        expect(result[:status]).to eq('succeeded')
        expect(gateway.charges.length).to eq(1)
      end

      it 'retries up to MAX_RETRIES times then raises' do
        gateway.fail_permanently!('Gateway timeout')

        expect { service.charge(order_id: 'order-1', amount: 100) }
          .to raise_error(PaymentService::GatewayError, /timeout/)
      end

      it 'does not retry on non-retryable errors' do
        gateway.fail_permanently!('Card declined')

        expect { service.charge(order_id: 'order-1', amount: 100) }
          .to raise_error(PaymentService::GatewayError, /declined/)

        # Should have only tried once (no retries for card declined)
        # The fake gateway tracks total failures, but we can verify
        # by checking that sleep was not called
        expect(service).not_to have_received(:sleep)
      end

      it 'marks payment as failed after all retries exhausted' do
        gateway.fail_permanently!('Gateway timeout')

        expect { service.charge(order_id: 'order-1', amount: 100) }
          .to raise_error(PaymentService::GatewayError)

        # Find the payment in the store
        payments = store.list_payments_by_order('order-1')
        expect(payments.length).to eq(1)
        expect(payments.first[:status]).to eq('failed')
        expect(payments.first[:error]).to include('timeout')
      end

      it 'publishes payment.failed event on failure' do
        gateway.fail_permanently!('Gateway timeout')

        expect { service.charge(order_id: 'order-1', amount: 100) }
          .to raise_error(PaymentService::GatewayError)

        events = event_bus.events_of_type('payment.failed')
        expect(events.length).to eq(1)
        expect(events.first[:data][:order_id]).to eq('order-1')
      end
    end
  end

  # ============================================================
  # Refund
  # ============================================================

  describe '#refund' do
    let!(:charge_result) do
      service.charge(order_id: 'order-1', amount: 5000)
    end

    context 'successful refund' do
      it 'refunds the full amount' do
        result = service.refund(payment_id: charge_result[:id])

        expect(result[:status]).to eq('refunded')
        expect(result[:amount]).to eq(5000)
        expect(result[:refund_id]).to start_with('re_')
      end

      it 'supports partial refund' do
        result = service.refund(payment_id: charge_result[:id], amount: 2000)

        expect(result[:status]).to eq('partially_refunded')
        expect(result[:amount]).to eq(2000)
      end

      it 'updates payment status to refunded' do
        service.refund(payment_id: charge_result[:id])
        payment = store.get_payment(charge_result[:id])

        expect(payment[:status]).to eq('refunded')
        expect(payment[:refund_amount]).to eq(5000)
      end

      it 'publishes payment.refunded event' do
        service.refund(payment_id: charge_result[:id], reason: 'defective')
        events = event_bus.events_of_type('payment.refunded')

        expect(events.length).to eq(1)
        expect(events.first[:data][:refund_amount]).to eq(5000)
        expect(events.first[:data][:reason]).to eq('defective')
      end

      it 'calls gateway with correct charge_id' do
        service.refund(payment_id: charge_result[:id])

        expect(gateway.refunds.length).to eq(1)
        payment = store.get_payment(charge_result[:id])
        expect(gateway.refunds.first[:charge_id]).to eq(payment[:gateway_id])
      end
    end

    context 'refund validation' do
      it 'raises RefundError for non-existent payment' do
        expect { service.refund(payment_id: 'nonexistent') }
          .to raise_error(PaymentService::RefundError, /not found/)
      end

      it 'raises RefundError for payment not in succeeded state' do
        # Refund it first, then try again
        service.refund(payment_id: charge_result[:id])

        expect { service.refund(payment_id: charge_result[:id]) }
          .to raise_error(PaymentService::RefundError, /not in refundable state/)
      end

      it 'raises RefundError when refund amount exceeds charge' do
        expect { service.refund(payment_id: charge_result[:id], amount: 6000) }
          .to raise_error(PaymentService::RefundError, /exceeds charge/)
      end

      it 'raises RefundError for zero refund amount' do
        expect { service.refund(payment_id: charge_result[:id], amount: 0) }
          .to raise_error(PaymentService::RefundError, /must be positive/)
      end

      it 'raises RefundError for negative refund amount' do
        expect { service.refund(payment_id: charge_result[:id], amount: -100) }
          .to raise_error(PaymentService::RefundError, /must be positive/)
      end
    end
  end

  # ============================================================
  # Webhook Processing
  # ============================================================

  describe '#process_webhook' do
    let(:webhook_secret) { 'whsec_test123' }

    def signed_payload(event)
      payload = event.to_json
      signature = OpenSSL::HMAC.hexdigest('SHA256', webhook_secret, payload)
      [payload, signature]
    end

    context 'valid webhooks' do
      it 'processes charge.succeeded event and updates payment' do
        result = service.charge(order_id: 'order-1', amount: 100)
        payment = store.get_payment(result[:id])

        event = {
          id: 'evt_123', type: 'charge.succeeded',
          created_at: clock.now.to_i,
          data: { charge_id: payment[:gateway_id] }
        }
        payload, sig = signed_payload(event)

        webhook_result = service.process_webhook(
          payload: payload, signature: sig, webhook_secret: webhook_secret
        )

        expect(webhook_result[:processed]).to be true
        expect(webhook_result[:event_type]).to eq('charge.succeeded')
      end

      it 'processes charge.failed event' do
        result = service.charge(order_id: 'order-1', amount: 100)
        payment = store.get_payment(result[:id])

        event = {
          id: 'evt_456', type: 'charge.failed',
          created_at: clock.now.to_i,
          data: { charge_id: payment[:gateway_id],
                  failure_reason: 'insufficient_funds' }
        }
        payload, sig = signed_payload(event)

        service.process_webhook(
          payload: payload, signature: sig, webhook_secret: webhook_secret
        )

        updated = store.get_payment(result[:id])
        expect(updated[:status]).to eq('failed')
        expect(updated[:error]).to eq('insufficient_funds')
      end

      it 'skips duplicate events' do
        result = service.charge(order_id: 'order-1', amount: 100)
        payment = store.get_payment(result[:id])

        event = {
          id: 'evt_789', type: 'charge.succeeded',
          created_at: clock.now.to_i,
          data: { charge_id: payment[:gateway_id] }
        }
        payload, sig = signed_payload(event)

        service.process_webhook(
          payload: payload, signature: sig, webhook_secret: webhook_secret
        )
        second = service.process_webhook(
          payload: payload, signature: sig, webhook_secret: webhook_secret
        )

        expect(second[:processed]).to be false
        expect(second[:reason]).to eq('duplicate')
      end

      it 'handles unknown event types gracefully' do
        event = {
          id: 'evt_unknown', type: 'customer.created',
          created_at: clock.now.to_i, data: {}
        }
        payload, sig = signed_payload(event)

        result = service.process_webhook(
          payload: payload, signature: sig, webhook_secret: webhook_secret
        )

        expect(result[:processed]).to be true
        # Should not raise
      end
    end

    context 'webhook security' do
      it 'rejects invalid signature' do
        event = { id: 'evt_bad', type: 'charge.succeeded',
                  created_at: clock.now.to_i, data: {} }
        payload = event.to_json

        expect {
          service.process_webhook(
            payload: payload, signature: 'invalid',
            webhook_secret: webhook_secret
          )
        }.to raise_error(PaymentService::InvalidWebhookError, /signature/)
      end

      it 'rejects stale events' do
        event = {
          id: 'evt_stale', type: 'charge.succeeded',
          created_at: clock.now.to_i - 600,  # 10 minutes ago
          data: {}
        }
        payload, sig = signed_payload(event)

        expect {
          service.process_webhook(
            payload: payload, signature: sig, webhook_secret: webhook_secret
          )
        }.to raise_error(PaymentService::InvalidWebhookError, /stale/)
      end

      it 'accepts events within tolerance window' do
        event = {
          id: 'evt_ok', type: 'charge.succeeded',
          created_at: clock.now.to_i - 200,  # 3.3 minutes ago (within 5 min)
          data: {}
        }
        payload, sig = signed_payload(event)

        result = service.process_webhook(
          payload: payload, signature: sig, webhook_secret: webhook_secret
        )

        expect(result[:processed]).to be true
      end
    end
  end

  # ============================================================
  # Query Methods
  # ============================================================

  describe '#list_payments' do
    it 'returns all payments for an order' do
      service.charge(order_id: 'order-1', amount: 100, idempotency_key: 'k1')
      service.charge(order_id: 'order-1', amount: 200, idempotency_key: 'k2')
      service.charge(order_id: 'order-2', amount: 300, idempotency_key: 'k3')

      payments = service.list_payments(order_id: 'order-1')
      expect(payments.length).to eq(2)
    end

    it 'filters by status' do
      result = service.charge(order_id: 'order-1', amount: 100, idempotency_key: 'k1')
      service.charge(order_id: 'order-1', amount: 200, idempotency_key: 'k2')
      service.refund(payment_id: result[:id])

      succeeded = service.list_payments(order_id: 'order-1', status: 'succeeded')
      expect(succeeded.length).to eq(1)
    end

    it 'returns empty array when no payments exist' do
      payments = service.list_payments(order_id: 'nonexistent')
      expect(payments).to eq([])
    end
  end
end
```

---

## Key Testing Decisions Explained

### Why use fakes instead of mocks for the store?

Fakes (in-memory implementations of the store interface) give us real behavior without the fragility of mocks. If we mocked every store method, our tests would break whenever we changed the internal call patterns. With a fake, we test the actual state transitions.

### Why stub `sleep` in retry tests?

Without stubbing sleep, each retry test would take 1 + 5 + 25 = 31 seconds. We verify the retry behavior through outcomes (number of gateway calls, final payment status) rather than timing.

### Why test the gateway interaction through the fake?

We inspect `gateway.charges` and `gateway.refunds` to verify the service called the gateway correctly. This is a form of spy verification that is appropriate here because the gateway is a boundary (external system).

### What is missing from this test suite?

1. **Concurrent charge tests**: two threads charging the same order simultaneously. The current implementation has a TOCTOU race on the idempotency check (get + save is not atomic). This would require either a real database with locking or a thread-safe fake.

2. **Partial refund followed by full refund**: the service does not track cumulative refunds, so you could refund more than the original charge via multiple partial refunds.

3. **Gateway returning unexpected responses**: what if the gateway returns a 200 but with an unexpected schema? The service assumes specific fields exist.

4. **Network errors vs gateway errors**: `Net::HTTP` raises different exceptions (Timeout::Error, SocketError) than our GatewayError. The real gateway adapter needs to catch these and wrap them.

5. **Log verification**: we could verify that the logger receives the correct structured log messages for observability.

---

## Design Issues in PaymentService

1. **Idempotency check is not atomic**: `get_by_idempotency_key` + `save_payment` is a TOCTOU race. In production, use a database unique constraint on `idempotency_key` and catch the constraint violation.

2. **Retries use `sleep`**: blocks the thread. In production, use a background job queue (Sidekiq) with scheduled retries.

3. **No cumulative refund tracking**: multiple partial refunds can exceed the original charge amount. Need to track `total_refunded` and check `existing_refunds + new_refund <= charge_amount`.

4. **`retryable?` uses string matching**: fragile. Better to use structured error types or HTTP status codes from the gateway.

5. **Webhook handler silently ignores unknown charges**: if `get_by_gateway_id` returns nil, the handler returns without logging or raising. This could mask configuration errors.
