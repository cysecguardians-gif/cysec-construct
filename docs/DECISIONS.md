# Architecture Decision Records

## ADR-001: Customer-owned Supabase projects

**Status:** Accepted

Each customer owns a separate Supabase project. The vendor maintains one product codebase and supplies SQL migrations and setup documentation. This keeps customer data and infrastructure under customer control and avoids a shared vendor-hosted tenant database in the initial commercial model.

## ADR-002: Desktop client with Tauri and React

**Status:** Proposed

The product is planned as a Windows desktop application using Tauri with a React UI. This provides a familiar desktop installation while keeping the UI maintainable with web technologies.

## ADR-003: No application server in the initial deployment

**Status:** Accepted with constraints

The initial architecture does not require Render or a separate always-on application API. Supabase provides authentication and PostgreSQL. Sensitive workflows are enforced by database policies and transactional functions. A server may be introduced later if justified by requirements such as privileged integrations, centralized licensing, or secure background jobs.

## ADR-004: Manual Supabase SQL provisioning initially

**Status:** Accepted

Migrations are stored in GitHub and initially applied manually in the customer's Supabase SQL Editor. The desktop application will not carry a service-role key or execute privileged schema setup.
