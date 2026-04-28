# Level 1 — Basic Operations:

# CreateAccount(timestamp, accountId) → returns bool
# Deposit(timestamp, accountId, amount) → returns balance
# Transfer(timestamp, fromAccountId, toAccountId, amount) → returns balance

# Validation: account must exist, no self-transfers, sufficient balance, positive amounts.
# Level 2 — Ranking:

# TopSpenders(timestamp, n) → returns top N accounts by cumulative outgoing spend, formatted as "accountId(spendAmount)"
# Sorted by amount descending, then by account ID ascending as a tiebreaker

# Level 3 — Scheduled Payments:

# SchedulePayment(timestamp, accountId, amount, delay) → payment executes at timestamp + delay, returns a paymentId
# CancelPayment(timestamp, accountId, paymentId) → cancels if it exists
# paymentId uses a global auto-increment counter formatted as "payment1", "payment2", etc. Linkjob
# There's also a GetPaymentStatus that checks if a payment is scheduled, processed, or cancelled LeetCode

# Level 4 — Account Merging (hardest):

# Merge two accounts together, combining balances and transaction histories
# Scheduled payments from the merged account need to be handled correctly post-merge
#

class Bank
  attr_accessor :accounts, :outgoing, :payments
  def initialize
    @accounts = Hash.new(0) # all accounts start with 0 balance
    @outgoing = Hash.new(0) # all account outgoing amounts per account id
    @payments_count = 0     # global id counter
    @payments = {}
  end

  def create_account(timestamp, account_id) # -> returns bool
    process_scheduled_payments(timestamp)

    return false if @accounts.key?(account_id)

    @accounts[account_id] = 0
    @outgoing[account_id] = 0

    true
  end

  # DEBUGGING
  def get_amount(account_id)
    @accounts[account_id]
  end

  def deposit(timestamp, account_id, amount) # -> returns balance
    process_scheduled_payments(timestamp)

    return false unless @accounts.key?(account_id)
    return false unless amount >= 0

    @accounts[account_id] += amount

    @accounts[account_id]
  end

  def transfer(timestamp, from_id, to_id, amount) # -> returns balance
    process_scheduled_payments(timestamp)

    return false unless @accounts.key?(from_id)
    return false unless @accounts.key?(to_id)
    return false if from_id == to_id
    return false unless @accounts[from_id] >= amount

    @accounts[from_id] -= amount
    @accounts[to_id] += amount
    @outgoing[from_id] += amount

    @accounts[to_id]
  end

  def top_spenders(timestamp, n)
    process_scheduled_payments(timestamp)

    @outgoing.
      sort_by { |id, amount| [-amount, id] }.
      first(n)
  end

  # Status = :scheduled, :cancelled, :completed
  Payment = Struct.new(:id, :account_id, :amount, :timestamp, :status) 
  def schedule_payment(timestamp, account_id, amount, delay)
    process_scheduled_payments(timestamp)

    return false unless @accounts.key?(account_id)
    return false unless amount >= 0
    return false unless delay

    @payments_count += 1
    id = "payment#{@payments_count}"
    payment = Payment.new(id, account_id, amount, timestamp + delay, :scheduled)
    @payments[id] = payment

    id
  end

  def cancel_payment(timestamp, account_id, payment_id)
    process_scheduled_payments(timestamp)

    return false unless @accounts.key?(account_id)
    return false unless @payments.key?(payment_id)
    return false unless @payments[payment_id].account_id == account_id
    return false unless @payments[payment_id].status == :scheduled

    @payments[payment_id].status = :cancelled

    true
  end

  def get_payment_status(timestamp, payment_id)
    process_scheduled_payments(timestamp)

    @payments[payment_id].status
  end

  # Merge 2 into 1
  def merge_accounts(timestamp, account_id1, account_id2)
    process_scheduled_payments(timestamp)

    return false if account_id1 == account_id2
    return false unless @accounts.key?(account_id1) && @accounts.key?(account_id2)

    # Merge account balance
    @accounts[account_id1] += @accounts[account_id2]
    @accounts.delete(account_id2)
    
    # Merge outgoing amount
    @outgoing[account_id1] += @outgoing[account_id2]
    @outgoing.delete(account_id2)

    # Merge scheduled payments
    @payments.values.select { |p| p.account_id == account_id2 }.
      each do |payment|
        payment.account_id = account_id1
      end

    true
  end

  private

  def process_scheduled_payments(timestamp)
    due = @payments.values.
      select { |p| p.status == :scheduled && p.timestamp <= timestamp }.
      sort_by(&:timestamp)

    due.each do |payment|
      if @accounts[payment.account_id] < payment.amount
        payment.status = :cancelled
      else
        @accounts[payment.account_id] -= payment.amount
        @outgoing[payment.account_id] += payment.amount

        payment.status = :completed
      end
    end
  end
end

def assert(comment, result, expectation)
  output = ""
  if result == expectation
    output += "SUCCESS - " 
  else 
    output += "FAILURE: #{result} vs #{expectation} - "
  end
  output += "#{comment}"

  puts output
end

# Part 1 tests
bank = Bank.new
assert "Create account 123", bank.create_account(1, 123), true
assert "Create account 456", bank.create_account(2, 456), true
assert "Create account 789", bank.create_account(3, 789), true
assert "Fail to create account 789", bank.create_account(4, 789), false

assert "Fail to deposit account 123, -1", bank.deposit(100, 123, -1), false
assert "Fail to deposit account abc, 1000", bank.deposit(101, "abc", 1000), false
assert "Deposit account 123, 1000", bank.deposit(102, 123, 1000), 1000
assert "Deposit account 456, 500", bank.deposit(103, 456, 500), 500
assert "Deposit account 789, 2500", bank.deposit(104, 789, 2500), 2500

assert "Fail to transfer 123 -> 123, 750", bank.transfer(200, 123, 123, 750), false
assert "Fail to transfer 456 -> 123, 1250", bank.transfer(201, 456, 123, 1250), false
assert "Transfer 123 -> 456, 750", bank.transfer(202, 123, 456, 750), 1250
assert "Transfer 789 -> 456, 1250", bank.transfer(203, 789, 456, 1250), 2500
assert "Transfer 456 -> 123, 1250", bank.transfer(204, 456, 123, 1250), 1500
assert "Fail to transfer 123 -> 789, 9999", bank.transfer(205, 123, 789, 9999), false

# Part 2
assert "Top spenders 1", bank.top_spenders(300, 1), [[456, 1250]]
assert "Top spenders 3", bank.top_spenders(301, 3), [[456, 1250], [789, 1250], [123, 750]]

# Part 3
assert "123 balance = 1500", bank.get_amount(123), 1500
assert "Schedule 123, 100, 5", bank.schedule_payment(400, 123, 100, 5), "payment1"
assert "Schedule 123, 100, 4", bank.schedule_payment(401, 123, 100, 4), "payment2"
assert "Schedule 123, 100, 3", bank.schedule_payment(402, 123, 100, 3), "payment3"
assert "Schedule 123, 100, 2", bank.schedule_payment(403, 123, 100, 2), "payment4"
assert "Cancel payment2", bank.cancel_payment(404, 123, "payment2"), true
assert "Schedule 456, 100, 1", bank.schedule_payment(405, 456, 100, 1), "payment5"
assert "Cancel payment3", bank.cancel_payment(406, 123, "payment3"), false
assert "123 balance = 1200", bank.get_amount(123), 1200
assert "Payment status payment4", bank.get_payment_status(407, "payment4"), :completed
assert "Payment status payment2", bank.get_payment_status(408, "payment2"), :cancelled

# Part 4
assert "456 balance = 1200", bank.get_amount(456), 1150
assert "Merge 123, 123", bank.merge_accounts(500, 123, 123), false
assert "Merge 456, 123", bank.merge_accounts(500, 456, 123), true
assert "456 balance = 1200", bank.get_amount(456), 2350

puts bank.accounts
puts bank.payments
