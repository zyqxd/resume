
```ruby
# Coinbase CodeSignal - Banking System (All 4 Levels)
#
# Level 1: CreateAccount, Deposit, Transfer
# Level 2: TopSpenders
# Level 3: SchedulePayment, CancelPayment, GetPaymentStatus
# Level 4: MergeAccounts

class BankingSystem
  def initialize
    @accounts = {}          # account_id => balance (Integer)
    @outgoing = Hash.new(0) # account_id => total outgoing spend
    @payments = {}          # payment_id => Payment
    @payment_counter = 0
  end

  # ─── LEVEL 1 ────────────────────────────────────────────────

  def create_account(timestamp, account_id)
    process_scheduled_payments(timestamp)
    return false if @accounts.key?(account_id)
    @accounts[account_id] = 0
    true
  end

  def deposit(timestamp, account_id, amount)
    process_scheduled_payments(timestamp)
    return nil unless @accounts.key?(account_id)
    return nil if amount <= 0
    @accounts[account_id] += amount
    @accounts[account_id]
  end

  def transfer(timestamp, from_id, to_id, amount)
    process_scheduled_payments(timestamp)
    return nil if from_id == to_id
    return nil unless @accounts.key?(from_id) && @accounts.key?(to_id)
    return nil if amount <= 0
    return nil if @accounts[from_id] < amount

    @accounts[from_id] -= amount
    @accounts[to_id] += amount
    @outgoing[from_id] += amount
    @accounts[from_id]
  end

  # ─── LEVEL 2 ────────────────────────────────────────────────

  def top_spenders(timestamp, n)
    process_scheduled_payments(timestamp)
    @accounts.keys
      .sort_by { |id| [-@outgoing[id], id] }
      .first(n)
      .map { |id| "#{id}(#{@outgoing[id]})" }
  end

  # ─── LEVEL 3 ────────────────────────────────────────────────

  Payment = Struct.new(:id, :account_id, :amount, :trigger_time, :status)
  # status: :scheduled, :processed, :cancelled

  def schedule_payment(timestamp, account_id, amount, delay)
    process_scheduled_payments(timestamp)
    return nil unless @accounts.key?(account_id)
    return nil if amount <= 0

    @payment_counter += 1
    pid = "payment#{@payment_counter}"
    @payments[pid] = Payment.new(pid, account_id, amount, timestamp + delay, :scheduled)
    pid
  end

  def cancel_payment(timestamp, _account_id, payment_id)
    process_scheduled_payments(timestamp)
    pmt = @payments[payment_id]
    return false if pmt.nil? || pmt.status != :scheduled
    pmt.status = :cancelled
    true
  end

  def get_payment_status(timestamp, _account_id, payment_id)
    process_scheduled_payments(timestamp)
    pmt = @payments[payment_id]
    return nil if pmt.nil?
    pmt.status.to_s
  end

  # ─── LEVEL 4 ────────────────────────────────────────────────

  def merge_accounts(timestamp, account_id_1, account_id_2)
    process_scheduled_payments(timestamp)
    return false if account_id_1 == account_id_2
    return false unless @accounts.key?(account_id_1) && @accounts.key?(account_id_2)

    # Merge into account_id_1, remove account_id_2
    @accounts[account_id_1] += @accounts[account_id_2]
    @outgoing[account_id_1] += @outgoing[account_id_2]

    # Reassign pending scheduled payments from account_id_2 -> account_id_1
    @payments.each_value do |pmt|
      if pmt.account_id == account_id_2 && pmt.status == :scheduled
        pmt.account_id = account_id_1
      end
    end

    @accounts.delete(account_id_2)
    @outgoing.delete(account_id_2)
    true
  end

  private

  # ─── CORE: Process all scheduled payments due at or before `timestamp` ──

  def process_scheduled_payments(timestamp)
    due = @payments.values
      .select { |p| p.status == :scheduled && p.trigger_time <= timestamp }
      .sort_by(&:trigger_time)

    due.each do |pmt|
      if @accounts.key?(pmt.account_id) && @accounts[pmt.account_id] >= pmt.amount
        @accounts[pmt.account_id] -= pmt.amount
        @outgoing[pmt.account_id] += pmt.amount
        pmt.status = :processed
      else
        pmt.status = :cancelled  # insufficient funds or account gone
      end
    end
  end
end

# ─── QUICK SMOKE TEST ─────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  bank = BankingSystem.new

  # Level 1
  puts bank.create_account(1, "alice")    # true
  puts bank.create_account(2, "bob")      # true
  puts bank.deposit(3, "alice", 1000)     # 1000
  puts bank.transfer(4, "alice", "bob", 300) # 700

  # Level 2
  p bank.top_spenders(5, 2)              # ["alice(300)", "bob(0)"]

  # Level 3
  pid = bank.schedule_payment(6, "alice", 200, 5)  # triggers at t=11
  puts pid                                          # payment1
  puts bank.get_payment_status(7, "alice", pid)     # scheduled
  puts bank.deposit(12, "bob", 50)                  # triggers payment at t=11 first, then deposits
  puts bank.get_payment_status(13, "alice", pid)    # processed

  # Level 4
  puts bank.create_account(14, "carol")    # true
  puts bank.deposit(15, "carol", 500)      # 500
  puts bank.merge_accounts(16, "alice", "carol") # true
  puts bank.deposit(17, "alice", 0).inspect       # nil (amount <= 0)
  puts bank.deposit(17, "alice", 1)               # alice now has 500 + remaining + 1
end
```