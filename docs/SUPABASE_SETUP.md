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
7. Create the first administrator using the secure bootstrap process below.
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
- `0003_bootstrap_and_connection.sql` — secure first-organization bootstrap, schema/version connection check, and optional default-unit seeding.

The initial invoice model supports **optional discount and optional GST**. Both are disabled by default. When GST is enabled, the invoice stores CGST/SGST/IGST amounts; when disabled, GST amounts must remain zero. Monetary values are stored as integer paise, while the application displays Indian Rupee formatting (`₹`, `en-IN`).

### Transactional write operations

The desktop application should use the RPC functions in `0002_transactional_operations.sql` for financial and stock-changing operations rather than performing several independent writes from the frontend.

- `issue_invoice(...)` — validates the customer and materials, calculates discount/GST, creates the invoice and immutable item snapshots, deducts stock, records stock movements, generates the invoice number, and writes an audit entry in one database transaction.
- `adjust_stock(...)` — performs a controlled stock increase/decrease and creates the corresponding stock movement.
- `record_payment(...)` — records a payment while preventing payments greater than the outstanding invoice balance.
- `cancel_invoice(...)` — administrator-only cancellation that restores stock and preserves the invoice history instead of deleting it. Paid invoices cannot be cancelled until payments are reversed through a future payment-reversal workflow.

Invoice numbers use the Indian financial year format by default, such as `INV/2026-27/0001`. The organization invoice prefix is configurable.

The RPC functions use `security definer` because they perform atomic multi-table operations. Each function explicitly checks the authenticated user's organization membership, and administrator-only operations additionally check the user's organization role. The service-role key is never required by the desktop client.

## First administrator / organization bootstrap

The first administrator is created through a controlled two-step process:

1. Create the first user in Supabase Authentication using the customer's chosen login method.
2. Sign in to the desktop application with that user.
3. The application detects that the authenticated user has no organization membership and opens the organization setup screen.
4. Enter the business details: legal name, optional trade name, GSTIN/PAN, address, state, state code, contact details, and invoice prefix.
5. The application calls `bootstrap_organization(...)`.
6. The function creates the organization, profile, administrator membership, initial financial-year invoice sequence, and audit entry atomically.
7. The user is immediately treated as the organization's `admin`.
8. The application can then optionally call `seed_default_units(organization_id)` to create common units such as pcs, kg, m, litre, box, and bag.

The bootstrap function refuses to run when the authenticated user already belongs to an organization. This prevents accidental repeated provisioning.

The desktop application must never ask the customer for a service-role key to perform bootstrap. The bootstrap function validates `auth.uid()` and performs the privileged database operations itself.

## Connection test

The desktop application should provide a **Test Connection** action that verifies:

- The project URL is syntactically valid and reachable.
- Supabase client initialization succeeds.
- The current user can authenticate.
- The expected schema is installed by calling `get_app_status()`.
- The returned schema version is supported by the application.

A successful network request alone does not prove the schema is correctly installed or the user's permissions are correct.

`get_app_status()` returns only safe metadata such as authentication state, schema version, INR currency configuration, and locale. It does not expose database credentials or customer data.

## Migration order

For a new customer database, run:

```text
0001_initial_schema.sql
0002_transactional_operations.sql
0003_bootstrap_and_connection.sql
```

Do not edit an already-applied migration for a customer. Create a new numbered migration for later schema changes.

The first release uses manual migration application. Do not add an in-app button that executes arbitrary DDL with a service-role key.
