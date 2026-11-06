# CySec Construct

CySec Construct is a Windows desktop application for construction businesses, covering tender and contract finance, material procurement and inventory, contractor work orders, and contractor settlements. The product is designed to support multiple independent businesses while allowing each customer to own and manage their own Supabase project and business data.

## Product goals

- Windows desktop application built with React and Tauri.
- Shared, cloud-hosted business data across multiple office computers.
- Customer-owned Supabase project, authentication, database, and storage.
- Inventory management with an auditable stock movement ledger.
- Client companies, awarded contracts, projects, client bills, receipts, and deductions.
- Vendor procurement, material inventory, contractor-specific issue rates, and stock reconciliation.
- Contractor/subcontractor work orders (fixed or percentage of total contract value), advances, returns, and final settlement.
- Employee accounts, role-based access, login/session history, and audit trails.
- Reusable multi-organization data model suitable for future deployments.

## Architecture

```text
GitHub repository (product source + SQL migrations + documentation)
                         |
                  Build / install
                         |
                Windows desktop app
                 (React + Tauri)
                         |
             HTTPS / Supabase client
                         |
              Customer-owned Supabase
          Auth | PostgreSQL | Storage | RLS
                         |
               Customer's office PCs
```

There is no requirement for a separate always-on application server for the initial product architecture. Sensitive operations must be enforced by PostgreSQL permissions, Row Level Security (RLS), and narrowly scoped database functions.

## Customer deployment model

Each customer deployment uses the same application codebase and a separate Supabase project/database. Customer data is not shared between deployments.

The desktop app may be configured with a Supabase project URL and a publishable (or legacy anon) key. Never embed a Supabase service-role key or database password in the desktop application.

## Repository layout

- `app/` — React application source.
- `src-tauri/` — Tauri desktop shell and native configuration.
- `supabase/migrations/` — ordered SQL migrations, maintained in Git.
- `supabase/seed/` — optional non-production reference/test data.
- `docs/` — architecture, setup, security, and operating decisions.
- `scripts/` — development and release helper scripts.

## Current status

The construction workflow is organized into four sections: (1) Tender / Contract Management and client finance, (2) Material Management and vendor procurement, (3) Contractor Management with work orders, daily material issues and advances, and (4) Contractor Closure with material reconciliation and settlement. Existing customer/invoice records remain available during the transition; the construction schema is additive.

## Security baseline

- Do not commit real credentials, customer information, invoices, exports, or production backups.
- Keep only placeholder variable names in `.env.example`.
- Use Supabase Auth for user identity.
- Enforce organization data isolation using RLS.
- Keep contract, receipt, deduction, purchase, material issue/return, advance, settlement, and stock history auditable; prefer cancellation/reversal workflows over destructive deletion.
- Perform stock and financial mutations through validated transactional PostgreSQL functions; do not write directly to sensitive ledger tables.
- Treat client-side validation as usability support, not as a security boundary.
