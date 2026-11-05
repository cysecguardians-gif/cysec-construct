# BuildSphere

BuildSphere is a reusable Windows desktop application for construction contract finance, vendor procurement, material inventory, contractor work orders, daily material issues, advances, reconciliation and contractor settlement. It is published by CySec Guardians. Each business owns and manages its own Supabase project and business data.

## Product goals

- Windows desktop application built with React and Tauri.
- Shared, cloud-hosted business data across multiple office computers.
- Customer-owned Supabase project, authentication, database, and storage.
- Tender/client company records, contracts, multiple projects per client, bills/claims, receipts, deductions and retention.
- Vendor records, purchase entries, material catalogue and auditable stock movement ledger.
- Contractor/subcontractor records and fixed or percentage-based work orders (POs).
- Daily material issues with purchase-cost and editable contractor-rate snapshots.
- Contractor advances, material returns, quantity reconciliation and final settlement.
- Employee accounts, role-based access, login/session history, and audit trails.
- Reusable multi-organization data model suitable for future deployments.

## Primary application sections

1. Tender / Contract Management
2. Material Management
3. Contractor Management
4. Contractor Closure & Settlement

See [construction workflow design](docs/construction-workflows.md) for the business rules and data model.

## Architecture

```text
GitHub repository (product source + SQL migrations + documentation)
                         |
                  Build / install
                         |
                BuildSphere desktop app
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

This repository contains the BuildSphere product foundation and construction workflow implementation. Further work should preserve customer-owned Supabase deployments, existing data, and the established database security model.

## Security baseline

- Do not commit real credentials, customer information, invoices, exports, or production backups.
- Keep only placeholder variable names in `.env.example`.
- Use Supabase Auth for user identity.
- Enforce organization data isolation using RLS.
- Keep invoice, payment, and stock history auditable; prefer cancellation/reversal workflows over destructive deletion.
- Treat client-side validation as usability support, not as a security boundary.
