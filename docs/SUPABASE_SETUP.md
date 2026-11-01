# Customer Supabase Setup

## Ownership

The customer creates and owns the Supabase account and project. The vendor configures the project with the customer's authorization. Business records remain in the customer's project.

## Initial setup checklist

1. Customer creates a Supabase account.
2. Customer creates a new project in the appropriate region.
3. Enable and configure the required authentication method(s).
4. Configure the Windows authentication deep-link settings described below.
5. Obtain the project URL and publishable key (or legacy anon key).
6. Apply the repository SQL migrations in the documented order using the Supabase SQL Editor.
7. Create the first administrator using the secure bootstrap process below.
8. Configure the desktop application on each office PC with the same project URL and publishable key.
9. Test email confirmation, sign-in, organization isolation, stock/invoice workflows, GST/discount calculations, payments, access controls, audit logging, and login-session reporting.

## Windows authentication deep link

The desktop application uses the custom URI scheme:

```text
materialmanagement://auth/callback
```

This is required because the Windows desktop application is not served from `http://localhost:3000`. Tauri registers the custom scheme with Windows, and the desktop application consumes the Supabase session returned in the URL fragment after email confirmation.

In the customer's Supabase dashboard, open **Authentication → URL Configuration** and set:

- **Site URL:** `materialmanagement://auth/callback`
- **Redirect URLs:** add the exact value `materialmanagement://auth/callback`

Keep the redirect URL exact for production. Supabase uses the Site URL when no explicit redirect is supplied, and custom deep-link URIs are supported for authentication flows. citeturn322078search8turn322078search0

Do not use `http://localhost:3000` as the production Site URL for the desktop application. That value is a common default for web development and causes the confirmation link to open a browser page that is not running in the installed desktop application. citeturn322078search2

The desktop build uses Tauri's deep-link and single-instance plugins so Windows can open/focus the existing application and deliver the callback URL to it. Tauri documents the desktop configuration under `plugins.deep-link.desktop.schemes`, and Windows deep links are delivered through the application process. citeturn246805search4turn357267search0

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
- `0004_customer_operations.sql` — controlled customer create, update, and active/inactive operations with audit handling.
- `0005_invoice_security_and_helpers.sql` — invoice/payment grants, secure-invoker reporting views, and supporting indexes.
- `0006_material_stock_threshold.sql` — configurable minimum stock quantity for low-stock monitoring and inventory controls.
- `0007_access_control_and_audit.sql` — admin membership lookup, admin-only team management, role/access changes, and protected audit-log history.
- `0008_login_session_tracking.sql` — secure login-session start, heartbeat/touch, logout/end operations, session-history policies, and indexes for session monitoring.

The initial invoice model supports **optional discount and optional GST**. Both are disabled by default. When GST is enabled, the invoice stores CGST/SGST/IGST amounts; when disabled, GST amounts must remain zero. Monetary values are stored as integer paise, while the application displays Indian Rupee formatting (`₹`, `en-IN`).

### Transactional write operations

The desktop application should use the RPC functions in `0002_transactional_operations.sql` for financial and stock-changing operations rather than performing several independent writes from the frontend.

- `issue_invoice(...)` — validates the customer and materials, calculates discount/GST, creates the invoice and immutable item snapshots, deducts stock, records stock movements, generates the invoice number, and writes an audit entry in one database transaction.
- `adjust_stock(...)` — performs a controlled stock increase/decrease and creates the corresponding stock movement.
- `record_payment(...)` — records a payment while preventing payments greater than the outstanding invoice balance.
- `cancel_invoice(...)` — administrator-only cancellation that restores stock and preserves the invoice history instead of deleting it. Paid invoices cannot be cancelled until payments are reversed through a future payment-reversal workflow.

Invoice numbers use the Indian financial year format by default, such as `INV/2026-27/0001`. The organization invoice prefix is configurable.

The RPC functions use `security definer` because they perform atomic multi-table operations. Each function explicitly checks the authenticated user's organization membership, and administrator-only operations additionally check the user's organization role. The service-role key is never required by the desktop client.

## Admin access and audit controls

The application has two organization roles:

- `admin` — can manage organization users, change Staff/Admin roles, disable or restore user access, and review the audit log.
- `staff` — can use normal operational workflows permitted by the application but cannot manage users or access the organization audit log.

The `Access & Audit` screen uses server-side security-definer functions for administrator operations. The client does not query `auth.users` directly and never receives a service-role key.

User creation/invitation remains an authentication-provider operation. The desktop app does not create Auth users with an elevated key. An administrator can create/invite the user through the customer's approved Supabase Auth workflow, after which the user is managed in the organization's membership list.

Audit records are treated as append-only history. The migration removes direct update/delete access to audit entries. Important transactional operations and membership changes write audit entries server-side.

## Login/session monitoring

Migration `0008_login_session_tracking.sql` provides three authenticated RPC operations:

- `start_login_session(organization_id)` — closes any previous open session for the same user and starts a new session.
- `touch_login_session(session_id)` — updates `last_seen_at` for the current open session.
- `end_login_session(session_id, reason)` — records logout time and an end reason.

Session records are visible to the owning user and to organization Admins. The Access & Audit screen includes a **Login sessions** view showing login time, last seen time, logout time, duration, end reason, and user ID.

The application should call `start_login_session` immediately after a successful sign-in, periodically call `touch_login_session` while the application is active, and call `end_login_session` during explicit sign-out. This keeps session duration reporting in the database without requiring an elevated key.

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
0004_customer_operations.sql
0005_invoice_security_and_helpers.sql
0006_material_stock_threshold.sql
0007_access_control_and_audit.sql
0008_login_session_tracking.sql
```

Do not edit an already-applied migration for a customer. Create a new numbered migration for later schema changes.

The first release uses manual migration application. Do not add an in-app button that executes arbitrary DDL with a service-role key.
