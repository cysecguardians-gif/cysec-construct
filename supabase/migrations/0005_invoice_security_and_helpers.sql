-- Material Management System
-- Invoice/payment security helpers.
-- Apply after 0004_customer_operations.sql.
-- Run manually in the customer's Supabase SQL Editor.

begin;

-- The payment RPC is the only write path the desktop app needs for payments.
grant execute on function public.record_payment(uuid, uuid, bigint, date, public.payment_method, text, text) to authenticated;

-- These tenant-facing views must respect the caller's table RLS policies.
alter view public.invoice_payment_summary set (security_invoker = true);
alter view public.customer_balance_summary set (security_invoker = true);

create index if not exists idx_invoices_org_date
  on public.invoices(organization_id, invoice_date desc, created_at desc);

create index if not exists idx_invoices_org_customer
  on public.invoices(organization_id, customer_id, invoice_date desc);

create index if not exists idx_payments_org_invoice_date
  on public.payments(organization_id, invoice_id, payment_date desc);

commit;
