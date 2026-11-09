-- CySec Construct — schema integrity repair (v35)
-- Adds the canonical columns required by contractor issue/return/advance RPCs
-- and aligns legacy purchase-item layouts without dropping customer data.
-- Safe for databases that already contain any subset of these columns.

begin;

-- Contractor material issues.
alter table public.material_issues
  add column if not exists contractor_id uuid;

update public.material_issues mi
set contractor_id = wo.contractor_id
from public.contractor_work_orders wo
where wo.id = mi.work_order_id
  and wo.organization_id = mi.organization_id
  and mi.contractor_id is null;

-- Contractor returns: link each historical return to the latest non-cancelled
-- material issue for its PO when a direct issue link is not already present.
alter table public.material_returns
  add column if not exists issue_id uuid,
  add column if not exists contractor_id uuid,
  add column if not exists project_id uuid;

update public.material_returns mr
set contractor_id = wo.contractor_id,
    project_id = coalesce(mr.project_id, wo.project_id)
from public.contractor_work_orders wo
where wo.id = mr.work_order_id
  and wo.organization_id = mr.organization_id
  and (mr.contractor_id is null or mr.project_id is null);

update public.material_returns mr
set issue_id = (
  select mi.id
  from public.material_issues mi
  where mi.organization_id = mr.organization_id
    and mi.work_order_id = mr.work_order_id
    and mi.status <> 'cancelled'
  order by mi.created_at desc
  limit 1
)
where mr.issue_id is null;

alter table public.material_return_items
  add column if not exists condition text not null default 'usable',
  add column if not exists notes text;

-- Advances retain a direct contractor snapshot as well as the PO reference.
alter table public.contractor_advances
  add column if not exists contractor_id uuid;

update public.contractor_advances ca
set contractor_id = wo.contractor_id
from public.contractor_work_orders wo
where wo.id = ca.work_order_id
  and wo.organization_id = ca.organization_id
  and ca.contractor_id is null;

-- Canonical purchase-item columns used by the receiving RPC and stock ledger.
alter table public.material_purchase_items
  add column if not exists description_snapshot text,
  add column if not exists unit_cost_paise bigint,
  add column if not exists line_subtotal_paise bigint,
  add column if not exists line_gst_paise bigint;

do $migration$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='material_purchase_items'
      and column_name='material_name_snapshot'
  ) then
    execute 'update public.material_purchase_items
             set description_snapshot = coalesce(description_snapshot, material_name_snapshot)';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='material_purchase_items'
      and column_name='unit_purchase_price_paise'
  ) then
    execute 'update public.material_purchase_items
             set unit_cost_paise = coalesce(unit_cost_paise, unit_purchase_price_paise)';
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='material_purchase_items'
      and column_name='line_total_paise'
  ) then
    execute 'update public.material_purchase_items
             set line_subtotal_paise = coalesce(line_subtotal_paise, line_total_paise)';
  end if;
end
$migration$;

update public.material_purchase_items
set description_snapshot = coalesce(
      description_snapshot,
      (select m.name from public.materials m
       where m.id = material_purchase_items.material_id
         and m.organization_id = material_purchase_items.organization_id),
      'Material'
    ),
    unit_cost_paise = coalesce(unit_cost_paise, 0),
    line_subtotal_paise = coalesce(line_subtotal_paise, 0),
    line_gst_paise = coalesce(line_gst_paise, 0);

alter table public.material_purchase_items
  alter column description_snapshot set not null,
  alter column unit_cost_paise set default 0,
  alter column unit_cost_paise set not null,
  alter column line_subtotal_paise set default 0,
  alter column line_subtotal_paise set not null,
  alter column line_gst_paise set default 0,
  alter column line_gst_paise set not null;

-- The old purchase RPC has already been superseded by migration 0028. Keep
-- legacy columns nullable so the canonical RPC does not have to populate them.
do $migration$
begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='material_purchase_items' and column_name='material_name_snapshot') then
    alter table public.material_purchase_items alter column material_name_snapshot drop not null;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='material_purchase_items' and column_name='unit_purchase_price_paise') then
    alter table public.material_purchase_items alter column unit_purchase_price_paise drop not null;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='material_purchase_items' and column_name='line_total_paise') then
    alter table public.material_purchase_items alter column line_total_paise drop not null;
  end if;
end
$migration$;

-- Normalize material issue statuses and keep returned issues visible to
-- reconciliation. Remove the original generated check before adding the
-- expanded constraint.
do $migration$
declare
  c record;
begin
  for c in
    select conname
    from pg_constraint
    where conrelid = 'public.material_issues'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format('alter table public.material_issues drop constraint %I', c.conname);
  end loop;
end
$migration$;

alter table public.material_issues
  add constraint material_issues_status_check
  check (status in ('issued','partially_returned','cancelled'));

-- Add tenant-scoped foreign keys only when absent.
do $migration$
begin
  if not exists (select 1 from pg_constraint where conrelid='public.material_issues'::regclass and conname='material_issues_org_contractor_fk') then
    alter table public.material_issues
      add constraint material_issues_org_contractor_fk
      foreign key (organization_id, contractor_id)
      references public.contractors(organization_id, id) on delete restrict;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.material_returns'::regclass and conname='material_returns_org_issue_fk') then
    alter table public.material_returns
      add constraint material_returns_org_issue_fk
      foreign key (organization_id, issue_id)
      references public.material_issues(organization_id, id) on delete restrict;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.material_returns'::regclass and conname='material_returns_org_contractor_fk') then
    alter table public.material_returns
      add constraint material_returns_org_contractor_fk
      foreign key (organization_id, contractor_id)
      references public.contractors(organization_id, id) on delete restrict;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.material_returns'::regclass and conname='material_returns_org_project_fk') then
    alter table public.material_returns
      add constraint material_returns_org_project_fk
      foreign key (organization_id, project_id)
      references public.projects(organization_id, id) on delete restrict;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.contractor_advances'::regclass and conname='contractor_advances_org_contractor_fk') then
    alter table public.contractor_advances
      add constraint contractor_advances_org_contractor_fk
      foreign key (organization_id, contractor_id)
      references public.contractors(organization_id, id) on delete restrict;
  end if;
end
$migration$;

create or replace view public.contractor_material_reconciliation_summary
with (security_invoker = true) as
select
  ii.organization_id,
  wo.id as work_order_id,
  ii.id as issue_item_id,
  ii.material_id,
  ii.description_snapshot as material_name_snapshot,
  ii.unit_name_snapshot,
  ii.quantity_issued,
  coalesce(r.returned_quantity, 0)::numeric(14,3) as quantity_returned,
  coalesce(mc.quantity_used, 0)::numeric(14,3) as quantity_used,
  greatest(ii.quantity_issued - coalesce(r.returned_quantity, 0) - coalesce(mc.quantity_used, 0), 0)::numeric(14,3) as quantity_unaccounted,
  ii.contractor_unit_rate_paise,
  greatest(ii.quantity_issued - coalesce(r.returned_quantity, 0), 0)::numeric(14,3) * ii.contractor_unit_rate_paise as material_charge_paise
from public.material_issue_items ii
join public.material_issues mi
  on mi.id=ii.issue_id
 and mi.organization_id=ii.organization_id
 and mi.status in ('issued','partially_returned')
join public.contractor_work_orders wo
  on wo.id=mi.work_order_id
 and wo.organization_id=ii.organization_id
left join (
  select organization_id, issue_item_id, sum(quantity_returned) returned_quantity
  from public.material_return_items
  group by organization_id, issue_item_id
) r on r.organization_id=ii.organization_id and r.issue_item_id=ii.id
left join public.material_reconciliations mc
  on mc.organization_id=ii.organization_id
 and mc.issue_item_id=ii.id;

insert into public.app_schema_version(version)
values (35)
on conflict (version) do nothing;

commit;
