# Contractor settlement and recovery regression matrix

This is a manual acceptance matrix for the settlement/recovery SQL workflow. Run it only in a disposable development or staging Supabase project with the complete customer setup SQL applied. Do not run these scenarios against production financial records.

## Test fixture

Create one test organisation, an organisation administrator, one contractor, and four completed work orders. Prepare one draft settlement per work order with the amounts below. All amounts are paise.

| Case | Final contractor payable | Contractor recovery |
|---|---:|---:|
| A | 10,000 | 4,000 |
| B | 10,000 | 4,000 |
| C | 0 | 4,000 |
| D | 0 | 0 |

The work orders should be in `under_closure` after settlement preparation. Use unique settlement and payment references for each case.

## Scenarios and expected outcomes

### A — Outgoing payable clears first

1. Approve the draft settlement.
2. Record the full 10,000 paise contractor settlement payment.
3. Confirm settlement `status = paid`, recovery `recovery_status = outstanding`, and work order `status = under_closure`.
4. Record the full 4,000 paise recovery payment.
5. Confirm recovery `recovery_status = recovered` and work order `status = settled`.

### B — Recovery clears first

1. Approve the draft settlement.
2. Record the full 4,000 paise recovery payment.
3. Confirm recovery `recovery_status = recovered`, settlement `status = approved`, and work order `status = under_closure`.
4. Record the full 10,000 paise contractor settlement payment.
5. Confirm settlement `status = paid` and work order `status = settled`.

### C — Zero payable, recovery outstanding

1. Approve the draft settlement.
2. Confirm settlement `status = paid`, recovery `recovery_status = outstanding`, and work order `status = under_closure`.
3. Record the full 4,000 paise recovery payment.
4. Confirm recovery `recovery_status = recovered` and work order `status = settled`.

This case verifies migrations 0024 and 0025 together: recovery must remain collectable after the payable is already paid, including when the payable is zero.

### D — Both balances are zero

1. Approve the draft settlement.
2. Confirm settlement `status = paid`, recovery `recovery_status = not_due`, and work order `status = settled`.

## Negative checks

- Attempt to record more than the outstanding payable; expect `payment_exceeds_settlement_balance`.
- Attempt to recover more than the outstanding recovery; expect `recovery_payment_exceeds_outstanding_balance`.
- Attempt to record a recovery against a draft or cancelled settlement; expect rejection.
- Verify a work order does not become `settled` while either balance remains outstanding.

## Evidence to capture

For each case, record the settlement row before and after each operation, the payment ledger rows, and the work-order status. Also verify the audit log entries. The test is a pass only when every expected state above is observed.

This matrix documents the required test procedure; it is not evidence that the scenarios have already been executed.
