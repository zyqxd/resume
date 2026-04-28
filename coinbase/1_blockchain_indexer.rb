# Blockchain Indexer
# Your goal is to create a simple indexer that allows for fast queries based on transaction IDs.

# The indexer should implement two methods: add_block and get_account_balance.

# add_block takes in an array of transactions. Transactions include "from" address, "to" address and a "value" amount of cryptocurrency. These transactions should be stored in a data structure that allows efficiently retrieval.

# get_account_balance takes in an account address and a block number. It returns the balance for the address at that block number. If no block number is provided then return latest balance.

# When an invalid block is added, such as insufficient funds to perform a transaction, it should return an error. Any transaction from 'init' to any other account is valid.

# Follow-up: Given an account address and a blockNum, return the account’s most recent stored balance at the largest block number strictly less than blockNum.

class BlockchainIndexer
  attr_accessor :blocks, :accounts_history

  def initialize
    @blocks = []
    @accounts = Hash.new(0)
    @accounts_history = Hash.new { |h,k| h[k] = [] }
  end

  # Initial thoughts on add_block
  # We can naively push block into blocks
  # Additionally we can store hash of account by value
  # This gives us retrival per transaction to validate if the account has the sufficient funds
  # Assume transaction input is correct format
  # For quick per block retrival, let's format each block as a hash
  Block = Struct.new(:transactions_raw, :account_balances)
  def add_block(transactions)
    valid = transactions.all? { |transaction| validate_transaction(transaction) }
    return :error unless valid

    # Follow-up - reduce storage to only use accounts that had a transaction
    account_balances = Hash.new(0)
    transactions.each do |transaction|
      from, to, value = transaction.values_at(:from, :to, :value)
      account_balances[from] = @accounts[from] unless account_balances.key?(from)
      account_balances[to] = @accounts[to] unless account_balances.key?(to)

      account_balances[from] -= value
      account_balances[to] += value
      @accounts[from] -= value
      @accounts[to] += value
    end

    account_balances.keys.each do |account|

      @accounts_history[account].push(@blocks.length) # index of current block, before push
    end

    @blocks << Block.new(transactions_raw: transactions, account_balances: account_balances)

    true
  end

  def get_account_balance(account_id, block_index = nil)
    return @accounts[account_id] if block_index == nil

    # Binary search for account history
    history = @accounts_history[account_id]
    lo, hi = 0, history.length - 1
    result = -1
    while lo <= hi
      mid = (lo + hi) / 2

      if history[mid] <= block_index
        result = mid
        lo = mid + 1
      else 
        hi = mid - 1
      end
    end

    return 0 if result == -1
    block_num = history[result]
    @blocks[block_num].account_balances[account_id]
  end

  private

  def validate_transaction(transaction)
    return true if transaction[:from] == 'init' 

    @accounts[transaction[:from]] >= transaction[:value] # false if account doesn't exist
  end
end

indexer = BlockchainIndexer.new

# Adding blocks with transactions
puts indexer.add_block([
    {from: 'init', to: 'acc1', value: 15},
    {from: 'init', to: 'acc3', value: 20},
    {from: 'init', to: 'acc4', value: 35},
])
puts indexer.get_account_balance('acc1', 0) == 15 
puts indexer.get_account_balance('acc2', 0) == 0
puts indexer.get_account_balance('acc3', 0) == 20


puts indexer.add_block([
    {from: 'acc1', to: 'acc2', value: 10},
    {from: 'acc3', to: 'acc1', value: 5},
])

puts indexer.get_account_balance('acc1', 1) == 10
puts indexer.get_account_balance('acc2', 1) == 10
puts indexer.get_account_balance('acc3', 1) == 15

puts indexer.add_block([
    {from: 'acc2', to: 'acc1', value: 8},
    {from: 'acc3', to: 'acc2', value: 3},
])

puts indexer.get_account_balance('acc1', 2) == 18
puts indexer.get_account_balance('acc2', 2) == 5
puts indexer.get_account_balance('acc3', 2) == 12

puts indexer.add_block([
    {from: 'acc1', to: 'acc3', value: 12},
])

# # Querying account balances
puts indexer.get_account_balance('acc1') == 6
puts indexer.get_account_balance('acc2') == 5
puts indexer.get_account_balance('acc3') == 24
puts indexer.get_account_balance('acc4', 2) == 35