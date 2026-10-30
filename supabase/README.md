# Supabase SQL

All customer database schema changes are stored as ordered SQL migrations under `migrations/`.

## Conventions

- Use sequential, descriptive filenames, for example `0001_initial_extensions.sql`.
- Prefer additive migrations; avoid editing migrations already applied to a customer environment.
- Include comments for security-sensitive functions and policies.
- Enable RLS on tenant-owned tables and add policies in the same migration that creates the table where practical.
- Revoke default/public access where appropriate; explicitly grant only required privileges.
- Never include customer data, real credentials, or production dumps.
- Keep migrations safe to review and test before production execution.

## Initial provisioning

The first release applies migrations manually through the customer's Supabase SQL Editor in filename order. The exact commands and expected verification queries will be documented as migrations are added.

No migration should require placing a service-role key in the desktop client.
