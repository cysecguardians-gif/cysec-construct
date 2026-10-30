# Security Requirements

## Secrets

- Never commit real customer credentials or secrets.
- Never bundle service-role keys or database passwords in the desktop app.
- The Supabase publishable/anon key may be distributed with the client, but it must be treated as an identifier rather than a security boundary.
- Store local configuration using an OS-appropriate secure storage mechanism where practical. Do not claim that a public key is secret.

## Authentication and authorization

- Require authenticated users for business operations.
- Use least-privilege database grants.
- Enable and test RLS on every tenant-owned table.
- Enforce organization membership in database policies and security-definer functions.
- Define safe ownership and execution privileges for every RPC.
- Prevent staff from granting themselves admin roles or changing organization membership.

## Financial and stock integrity

- Issue invoice and deduct stock in one transaction.
- Prevent overselling through atomic database logic.
- Validate positive quantities, valid prices, and discount bounds in the database.
- Record immutable invoice line snapshots.
- Derive invoice payment status from valid payments and reversals.
- Keep an audit trail for price changes, stock adjustments, invoice cancellation, and payment reversal.
- Use idempotency protection for retryable financial operations.

## Sessions

- Record authentication/session events without assuming a desktop app can guarantee a clean logout.
- Close or mark stale sessions according to a documented policy.
- Do not use client-provided duration as an authoritative value; derive duration from server-recorded timestamps.

## Privacy

Collect only employee and customer information required for business operations. Define retention and backup practices with each customer.
