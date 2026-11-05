# Construction workflow design

The construction workflow is organized into four business sections. Existing customer/invoice data and screens remain in the database during the transition; they are not destructively renamed.

## 1. Tender / Contract Management

- A client company can award multiple contracts.
- A contract can contain multiple projects or sites.
- Contract finance is recorded independently per contract.
- Client bills/claims, receipts, allocations and deductions are separate records.
- Receipts are cash received. Deductions and retention are displayed separately.
- A receipt may be unallocated until it is matched to submitted bills.

The `contract_finance_summary` view reports original/revised contract value, submitted bill value, actual receipts, allocated pending bill value, deductions, retention and not-yet-billed value.

## 2. Material Management

- Vendors are independent records.
- Each received purchase stores vendor, vendor invoice, date, item quantity, purchase rate and GST snapshot.
- Receiving a purchase increases material stock and appends a stock movement atomically.
- Existing material catalogue and stock ledger remain in use.

## 3. Contractor Management

- Contractors are independent of client companies and vendors.
- A contractor can have multiple work orders (POs), linked to a contract and optionally a project.
- Fixed work orders snapshot a fixed amount.
- Percentage work orders snapshot the contract's revised total value and calculate the agreed work amount as total contract value multiplied by the agreed percentage.
- Material rates are maintained per contractor and material. On a new issue, the latest purchase rate is shown as the initial fallback; a previously saved contractor-specific rate is loaded when one exists. The user can change the rate, and the entered rate is saved for that contractor/material combination and snapshotted on the issue line.
- Material issue reduces stock and appends the stock movement atomically.
- Material returns reference original issue lines, restore stock and cannot exceed the unreturned/unconsumed issue quantity.
- Cash/UPI/bank/etc. advances are recorded against the PO with date and payment reference.

## 4. Contractor Closure & Settlement

- Every issued material line must be reconciled for consumption before settlement.
- Returns are recorded separately against the original issue line.
- Chargeable material quantity is issued quantity less returned quantity.
- Unaccounted quantity is issued less used less returned; it remains visible and is not silently treated as returned.
- Material charge uses chargeable quantity multiplied by the contractor rate captured at issue time.
- Settlement formula:

  `Final payable = max(agreed work amount - material charges - advances - other deductions + adjustments, 0)`

- If deductions exceed the earned amount, the excess is recorded as a contractor recovery balance instead of creating a negative payable.
- Admin approval is required before settlement payments can be recorded.
- Partial settlement payments are supported and cannot exceed the approved settlement balance.

## Database migrations

Apply migrations in numerical order. The customer setup generator bundles all migrations through the latest version. The new construction migrations are:

- `0013_construction_domain_foundation.sql`
- `0014_construction_transactional_operations.sql`
- `0015_construction_workflow_controls.sql`

The critical stock and financial mutations use SECURITY DEFINER RPCs with explicit organization membership checks. Sensitive ledger tables are read-only to direct PostgREST writes.
