# Customer Supabase Setup

## Ownership

The customer creates and owns the Supabase account and project. The vendor configures the project with the customer's authorization. Business records remain in the customer's project.

## Initial setup checklist

1. Customer creates a Supabase account.
2. Customer creates a new project in the appropriate region.
3. Enable and configure the required authentication method(s).
4. Obtain the project URL and publishable key (or legacy anon key).
5. Apply the repository SQL migrations in the documented order using the Supabase SQL Editor.
6. Configure Auth URL settings only if required by the selected login flow.
7. Create the first administrator using the documented secure bootstrap process.
8. Configure the desktop application on each office PC with the same project URL and publishable key.
9. Test sign-in, organization isolation, stock/invoice workflows, GST/discount calculations, payments, and session recording.

## Application configuration

- Project URL: customer Supabase project URL.
- Public key: publishable key, or legacy anon key for compatible projects.

Never request or store the customer's Supabase account password, database password, or service-role key in the desktop application.

## SQL migration policy

Migrations are committed to `supabase/migrations/` and have stable sequence numbers. Apply each migration once, in ascending order. Record the applied migration/version for each customer environment. Review the target project before applying a migration, and take a suitable backup before production schema changes.

The migrations currently are:

- `0001_initial_schema.sql` — India-first INR schema covering organizations, users/memberships, login sessions, materials, stock movements, customers, invoices, invoice items, payments, audit logging, and customer balance/payment summary views.
- `0002_transactional_operations.sql` — transactional invoice issuance, Indian financial-year invoice numbering, stock deduction/adjustment, payment recording, and invoice cancellation/stock restoration.

The initial invoice model supports **optional discount and optional GST**. Both are disabled by default. When GST is enabled, the invoice stores CGST/SGST/IGST amounts; when disabled, GST amounts must remain zero. Monetary values are stored as integer paise, while the application displays Indian Rupee formatting (`₹`, `en-IN`).

### Transactional write operations

The desktop application should use the RPC functions in `0002_transactional_operations.sql` for financial and stock-changing operations rather than performing several independent writes from the frontend.

- `issue_invoice(...)` — validates the customer and materials, calculates discount/GST, creates the invoice and immutable item snapshots, deducts stock, records stock movements, generates the invoice number, and writes an audit entry in one database transaction.
- `adjust_stock(...)` — performs a controlled stock increase/decrease and creates the corresponding stock movement.
- `record_payment(...)` — records a payment while preventing payments greater than the outstanding invoice balance.
- `cancel_invoice(...)` — administrator-only cancellation that restores stock and preserves the invoice history instead of deleting it. Paid invoices cannot be cancelled until payments are reversed through a future payment-reversal workflow.

Invoice numbers use the Indian financial year format by default, such as `INV/2026-27/0001`. The organization invoice prefix is configurable.

The RPC functions use `security definer` because they perform atomic multi-table operations. Each function explicitly checks the authenticated user's organization membership, and administrator-only operations additionally check the user's organization role. The service-role key is never required by the desktop client.

Apply each migration once, in ascending order. Do not edit an already-applied migration for a customer; create a new migration for later schema changes.

The first release uses manual migration application. Do not add an in-app button that executes arbitrary DDL with a service-role key.

## Connection test

A connection test should verify that:
- The project URL is syntactically valid and reachable.
- Supabase client initialization succeeds.
- The expected schema/version can be read through a safe, intentionally exposed check.
- The current user can authenticate.

A successful network request alone does not prove the schema is correctly installed or the user's permissions are correct.
