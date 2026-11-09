-- Restrict invoice and payment mutations to validated SECURITY DEFINER RPCs.
-- Reads remain available to organization members through tenant-scoped RLS.
-- issue_invoice, cancel_invoice and record_payment remain the supported write
-- paths and execute with their owner's privileges.

begin;

drop policy if exists invoices_member_all on public.invoices;
drop policy if exists invoices_member_select on public.invoices;
create policy invoices_member_select
on public.invoices
for select to authenticated
using (public.is_org_member(organization_id));

drop policy if exists invoice_items_member_all on public.invoice_items;
drop policy if exists invoice_items_member_select on public.invoice_items;
create policy invoice_items_member_select
on public.invoice_items
for select to authenticated
using (
  exists (
    select 1
    from public.invoices i
    where i.id = invoice_items.invoice_id
      and public.is_org_member(i.organization_id)
  )
);

drop policy if exists payments_member_all on public.payments;
drop policy if exists payments_member_select on public.payments;
create policy payments_member_select
on public.payments
for select to authenticated
using (public.is_org_member(organization_id));

revoke insert, update, delete
on table public.invoices, public.invoice_items, public.payments
from authenticated, anon;

insert into public.app_schema_version(version)
values (37)
on conflict (version) do nothing;

commit;
