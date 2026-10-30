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
9. Test sign-in, organization isolation, stock/invoice workflows, and session recording.

## Application configuration

- Project URL: customer Supabase project URL.
- Public key: publishable key, or legacy anon key for compatible projects.

Never request or store the customer's Supabase account password, database password, or service-role key in the desktop application.

## SQL migration policy

Migrations are committed to `supabase/migrations/` and have stable sequence numbers. Apply each migration once, in ascending order. Record the applied migration/version for each customer environment. Review the target project before applying a migration, and take a suitable backup before production schema changes.

The first release uses manual migration application. Do not add an in-app button that executes arbitrary DDL with a service-role key.

## Connection test

A connection test should verify that:
- The project URL is syntactically valid and reachable.
- Supabase client initialization succeeds.
- The expected schema/version can be read through a safe, intentionally exposed check.
- The current user can authenticate.

A successful network request alone does not prove the schema is correctly installed or the user's permissions are correct.
