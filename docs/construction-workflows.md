# Construction Contract and Contractor Workflows

## Product navigation

The construction edition has four primary sections:

1. **Tender / Contract Management** — client companies, contracts, projects, bills/claims, receipts, deductions and retention.
2. **Material Management** — vendors, purchases, inventory and stock ledger.
3. **Contractor Management** — contractor profiles, contractor work orders (POs), daily material issues and advances.
4. **Contractor Closure & Settlement** — material reconciliation, settlement calculation, approvals and settlement payments.

The existing dashboard, organization setup, authentication, team access, audit trail and data-import foundation remain shared application capabilities. Existing customer/invoice records are retained during transition; they are not destructively renamed or dropped.

## Relationship model

- One client company can award many contracts.
- One contract can contain multiple projects.
- One project can have multiple contractor work orders.
- A contractor can have many work orders across projects.
- A vendor can supply many material purchases.
- A purchase contains one or more material purchase lines.
- A work order has many material issues and contractor advances.
- Each material issue contains one or more material issue lines.
- Material returns refer to the exact issue line being returned.
- A work order has at most one final settlement record in the initial release.
- One contract can have many client bills, receipts and deductions.

## Contractor compensation

A work order has one of two payment bases:

### Fixed
The agreed work amount is entered in INR and stored as integer paise.

### Percentage
The agreed work amount is calculated from the **contract value snapshot captured when the PO is created**:

`agreed_work_amount = round(contract_value_snapshot × agreed_percentage / 100)`

The percentage is based on the total tender/contract value, not client receipts or certified work. The PO stores the contract-value snapshot and calculated amount so later contract amendments do not silently rewrite an existing PO.

The selected contract-value basis is the revised contract value at the time the PO is created. If a future customer process requires a different approved basis, that must be an explicit PO amendment with an audit record.

## Material purchase and issue pricing

- Vendor purchase records preserve the actual purchase unit cost.
- The material catalogue keeps a current reference purchase price for pre-filling issue forms.
- At material issue time, the purchase unit cost is snapshotted on the issue line.
- Contractor unit rate is a separate editable value, prefilled from the purchase cost.
- The issue line stores both values; changing a material or vendor price later cannot rewrite historic issues.
- Stock is reduced when materials are issued and increased only for usable returns. Damaged/scrap returns are recorded separately and must not silently become usable stock.

## Material reconciliation

For every issue line:

`issued = used + returned + unaccounted`

`chargeable_quantity = issued - returned`

Contractor material charge:

`charge = chargeable_quantity × contractor_unit_rate_snapshot`

The contractor is charged for material not returned, whether recorded as used or unaccounted. The reconciliation screen must expose those quantities separately. Unaccounted material requires a reason and explicit verification; it must never be silently treated as consumed or returned.

Only usable returns increase available stock. Damaged/scrap returns require a separate stock disposition/adjustment.

## Contractor settlement

Initial settlement calculation:

`final_payable = agreed_work_amount - chargeable_materials - advances_adjusted - other_deductions + adjustments`

The settlement must be protected against negative payable amounts. If deductions exceed the agreed work amount, payable is zero and the excess is stored separately as a contractor recovery due; it must never be silently clamped or lost. The settlement stores immutable snapshots of the PO amount, percentage basis, material issue lines, contractor rates, returned quantities, advances and deductions.

Settlement payments are recorded separately and can be partial. Historical settlement rows are not deleted; corrections use cancellation/reversal records.

## Client contract finance

For each contract, the finance view separately displays:

- Original and revised contract value.
- Bills/claims submitted.
- Receipts recorded.
- Non-retention deductions.
- Retention withheld.
- Pending receivable against submitted bills.
- Unbilled contract value.

Retention is not conflated with ordinary deductions. Client receipts may be linked to a specific bill or recorded at contract level. A later finance workflow should allocate contract-level receipts across bills when invoice-level ageing is required.

## Security and data integrity

- All construction tables are organization-scoped and protected by RLS.
- This foundation migration exposes read access to organization members but deliberately has no direct table INSERT/UPDATE/DELETE policies.
- Subsequent migrations must add narrowly scoped SECURITY DEFINER RPCs for validated transactional writes.
- Stock purchase, material issue, usable material return, advance, reconciliation, settlement approval, settlement payment, client receipt and deduction operations must be atomic.
- Financial and stock history is append-oriented. Corrections should use cancellation/reversal records, not destructive deletion.
- Monetary values are integer paise; quantities use numeric(14,3).

## Migration rollout

- `0013_construction_workflow_foundation.sql` adds the construction data model and finance summary views.
- The customer database setup generator bundles this migration for new customer installations.
- Existing customer Supabase projects must apply new numbered migrations manually, in order, using the SQL Editor.
- Do not rerun migrations 0001–0012 on an existing database.
