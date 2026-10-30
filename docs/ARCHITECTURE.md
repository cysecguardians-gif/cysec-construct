# Architecture

## High-level design

- Desktop shell: Tauri.
- UI: React + TypeScript (planned).
- Data/auth platform: customer-owned Supabase.
- Database: PostgreSQL.
- Identity: Supabase Auth.
- Authorization: PostgreSQL grants and Row Level Security.
- Critical business operations: database functions/RPC with transaction boundaries.
- Invoice document generation: desktop-side PDF generation initially, using immutable invoice snapshots from the database.

A hosted application API is not part of the initial architecture. Add a server only when a requirement cannot be safely or reliably implemented with Supabase and the desktop client.

## Customer-owned Supabase configuration

The app configuration contains:
- Supabase project URL.
- Supabase publishable key (or legacy anon key where required).

The desktop app must never contain:
- Supabase service-role key.
- PostgreSQL connection password.
- Customer's administrative Supabase credentials.

Supabase publishable keys are public identifiers, not authorization. All data protection must be enforced by authenticated user identity, database grants, and RLS.

## Database provisioning

SQL is versioned in `supabase/migrations/`. For the initial release, the vendor/operator reviews and manually applies migrations in the customer's Supabase SQL Editor. Migration order and prerequisites are documented. The app may later include a read-only schema/version check, but it must not attempt privileged schema installation using an embedded secret.

## Multi-organization model

The schema is designed to support multiple organizations in one database even though the expected first deployment uses one customer-owned Supabase project per business.

Every tenant-owned business row includes an `organization_id`. RLS must verify membership in that organization for the authenticated user. Do not rely on a client-supplied organization ID by itself.

## Transactional operations

The following operations must be database-transactional:
- Issue invoice and deduct stock.
- Record or reverse payment.
- Cancel/credit invoice and reverse stock effects where applicable.
- Record stock adjustments.

Use constraints, row locks or safe atomic update patterns to prevent concurrent transactions from overselling stock or creating inconsistent balances.

## Auditability

Financial and inventory records should be append-oriented. Corrections should use cancellation, reversal, or adjustment entries with actor, reason, timestamp, and reference. Hard deletion should be restricted to explicitly safe master-data cases.

## Realtime

Realtime subscriptions may improve visibility of changes across office PCs, but the database remains authoritative. The UI must handle reconnects and refresh authoritative state after network interruptions.

## Online availability

The first release is online-first. No local database is treated as the authoritative source. Offline transaction creation requires a separate conflict, idempotency, and reconciliation design.
