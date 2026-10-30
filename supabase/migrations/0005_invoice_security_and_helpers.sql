-- Material Management System
-- Invoice reporting helpers and view hardening.
-- Apply after 0004_customer_operations.sql.
-- Run manually in the customer's Supabase SQL Editor.

begin;

-- These views are tenant-facing. Run them with the caller's permissions so the
-- underlying organization RLS policies remain effective.
alter view public.invoice_payment_summary set (security_invoker = true);
alter view public.customer_balance_summary set (security_invoker = true);

create index if not exists idx_invoices_org_date
  on public.invoices(organization_id, invoice_date desc, created_at desc);

create index if not exists idx_invoices_org_customer
  on public.invoices(organization_id, customer_id, invoice_date desc);

commit;
