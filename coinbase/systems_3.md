## Prompt 3: Design a Cash Account with Bank Deposits/Withdrawals (Closest to Retail-Cash)

Less famous but most directly aligned to your role. Tests ACH integration, balance management, the bank↔internal seam. Also add cold storage component

- *"What happens when an ACH deposit is returned 5 days later?"* 
- *"Two deposits arrive for the same `(user, transaction_id)` from a retry — what happens?"* 
- *"How do you know your ledger matches the bank?"* 

## Scale
- DAU? 