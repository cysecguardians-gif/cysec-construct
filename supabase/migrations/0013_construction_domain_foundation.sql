-- Material Management System
-- Construction workflow foundation: client contracts, projects, vendors,
-- contractor work orders, material procurement/issues/returns, advances,
-- client receivables and contractor settlements.
-- Apply after 0012_import_integrity.sql. This migration is additive.

begin;

-- Existing materials are keyed by UUID; add the composite uniqueness required
-- for tenant-consistent foreign keys in the construction tables.
create unique index if not exists uq_materials_organization_id_id
  on public.materials(organization_id, id);

-- ============================================================
-- 1. Client companies, awarded contracts and projects
-- ============================================================

create table if not exists public.client_companies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  legal_name text,
  gstin text,
  pan text,
  contact_person text,
  phone text,
  email text,
  address_line1 text,
  address_line2 text,
  city text,
  state text,
  state_code text,
  postal_code text,
  notes text,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, name)
);

create unique index if not exists uq_client_companies_organization_id_id
  on public.client_companies(organization_id, id);

create table if not exists public.contracts (

  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  client_company_id uuid not null,
  contract_number text not null,
  title text not null,
  description text,
  tender_reference text,
  contract_date date,
  start_date date,
  expected_completion_date date,
  actual_completion_date date,
  original_value_paise bigint not null check (original_value_paise >= 0),
  revised_value_paise bigint not null check (revised_value_paise >= 0),
  currency_code text not null default 'INR' check (currency_code = 'INR'),
  status text not null default 'active'
    check (status in ('draft','active','on_hold','completed','closed','cancelled')),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, contract_number),
  foreign key (organization_id, client_company_id)
    references public.client_companies(organization_id, id) on delete restrict
);

create unique index if not exists uq_contracts_organization_id_id
  on public.contracts(organization_id, id);

create index if not exists idx_contracts_client on public.contracts(organization_id, client_company_id);
create index if not exists idx_contracts_status on public.contracts(organization_id, status);

create table if not exists public.projects (

  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contract_id uuid not null,
  project_code text,
  name text not null,
  description text,
  site_address text,
  site_city text,
  site_state text,
  start_date date,
  expected_completion_date date,
  actual_completion_date date,
  status text not null default 'active'
    check (status in ('planned','active','on_hold','completed','closed','cancelled')),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, contract_id)
    references public.contracts(organization_id, id) on delete restrict
);

create index if not exists idx_projects_contract
  on public.projects(organization_id, contract_id);

create unique index if not exists uq_projects_organization_id_id
  on public.projects(organization_id, id);

-- ============================================================
-- 2. Client bills, receipts, allocations and deductions

-- ============================================================

create table if not exists public.client_bills (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contract_id uuid not null,
  project_id uuid,
  bill_number text not null,
  bill_date date not null default current_date,
  period_from date,
  period_to date,
  description text,
  amount_paise bigint not null check (amount_paise > 0),
  status text not null default 'submitted'
    check (status in ('draft','submitted','approved','partially_paid','paid','rejected','cancelled')),
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, contract_id, bill_number),
  foreign key (organization_id, contract_id)
    references public.contracts(organization_id, id) on delete restrict,
  foreign key (organization_id, project_id)
    references public.projects(organization_id, id) on delete restrict
);

-- Upgrade databases where client_bills predates this construction schema.
-- The legacy amount_claimed_paise and notes fields carry the same business
-- values as the current amount_paise and description fields; rename them
-- instead of creating empty financial columns or losing existing data.
do $migration$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_bills'
      and column_name='amount_claimed_paise'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_bills'
      and column_name='amount_paise'
  ) then
    alter table public.client_bills rename column amount_claimed_paise to amount_paise;
  elsif exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_bills'
      and column_name='amount_claimed_paise'
  ) and exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_bills'
      and column_name='amount_paise'
  ) then
    update public.client_bills
      set amount_paise = amount_claimed_paise
      where amount_paise is null;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_bills'
      and column_name='notes'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_bills'
      and column_name='description'
  ) then
    alter table public.client_bills rename column notes to description;
  end if;
end $migration$;

alter table public.client_bills
  add column if not exists project_id uuid,
  add column if not exists description text,
  add column if not exists created_by uuid references public.profiles(id) on delete set null;

create unique index if not exists uq_client_bills_organization_id_id
  on public.client_bills(organization_id, id);

create table if not exists public.client_receipts (

  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contract_id uuid not null,
  receipt_number text,
  receipt_date date not null default current_date,
  amount_paise bigint not null check (amount_paise > 0),
  payment_method public.payment_method not null default 'bank_transfer',
  reference_number text,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, contract_id)
    references public.contracts(organization_id, id) on delete restrict
);

-- Preserve legacy receipt metadata while aligning the columns used by the
-- current client-receivables workflow.
do $migration$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_receipts'
      and column_name='recorded_by'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_receipts'
      and column_name='created_by'
  ) then
    alter table public.client_receipts rename column recorded_by to created_by;
  end if;
end $migration$;

alter table public.client_receipts
  add column if not exists receipt_number text,
  add column if not exists created_by uuid references public.profiles(id) on delete set null;

create unique index if not exists uq_client_receipts_organization_id_id
  on public.client_receipts(organization_id, id);

create table if not exists public.client_receipt_allocations (

  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  receipt_id uuid not null,
  bill_id uuid not null,
  amount_paise bigint not null check (amount_paise > 0),
  created_at timestamptz not null default now(),
  foreign key (organization_id, receipt_id)
    references public.client_receipts(organization_id, id) on delete restrict,
  foreign key (organization_id, bill_id)
    references public.client_bills(organization_id, id) on delete restrict
);

-- Legacy receipts stored a single bill_id directly on the receipt. Convert
-- those links into allocation rows without duplicating any existing allocation.
do $migration$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_receipts'
      and column_name='bill_id'
  ) then
    insert into public.client_receipt_allocations
      (organization_id, receipt_id, bill_id, amount_paise)
    select r.organization_id, r.id, r.bill_id, r.amount_paise
    from public.client_receipts r
    where r.bill_id is not null
      and not exists (
        select 1 from public.client_receipt_allocations a
        where a.organization_id=r.organization_id
          and a.receipt_id=r.id and a.bill_id=r.bill_id
      );
  end if;
end $migration$;

create index if not exists idx_client_receipts_contract on public.client_receipts(organization_id, contract_id, receipt_date desc);
create index if not exists idx_client_allocations_bill on public.client_receipt_allocations(organization_id, bill_id);

create table if not exists public.client_deductions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contract_id uuid not null,
  bill_id uuid,
  deduction_date date not null default current_date,
  category text not null
    check (category in ('tds','retention','security_deposit','penalty','material_recovery','labour_cess','other')),
  description text,
  amount_paise bigint not null check (amount_paise > 0),
  recoverable boolean not null default false,
  reference_number text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (organization_id, contract_id)
    references public.contracts(organization_id, id) on delete restrict,
  foreign key (organization_id, bill_id)
    references public.client_bills(organization_id, id) on delete restrict
);

-- Upgrade legacy deduction columns without discarding existing records.
-- These names represent the same stored values in the earlier receivables schema.
do $migration$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_deductions'
      and column_name='deduction_type'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_deductions'
      and column_name='category'
  ) then
    alter table public.client_deductions rename column deduction_type to category;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_deductions'
      and column_name='is_recoverable'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_deductions'
      and column_name='recoverable'
  ) then
    alter table public.client_deductions rename column is_recoverable to recoverable;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_deductions'
      and column_name='notes'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_deductions'
      and column_name='description'
  ) then
    alter table public.client_deductions rename column notes to description;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_deductions'
      and column_name='recorded_by'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='client_deductions'
      and column_name='created_by'
  ) then
    alter table public.client_deductions rename column recorded_by to created_by;
  end if;
end $migration$;

alter table public.client_deductions
  add column if not exists description text,
  add column if not exists recoverable boolean not null default false,
  add column if not exists created_by uuid references public.profiles(id) on delete set null;

create index if not exists idx_client_deductions_contract on public.client_deductions(organization_id, contract_id, deduction_date desc);

-- Contract finance summary. "Pending against bills" is bill value less allocated
-- receipts; deductions and retention remain separately visible and are not
-- misrepresented as cash received.
-- The customer schema may already contain a legacy view with a different output
-- column layout. Recreate this reporting view so its named columns match the
-- current contract-finance contract; no table data is affected.
drop view if exists public.contract_finance_summary;

create view public.contract_finance_summary
with (security_invoker = true) as
select
  c.id as contract_id,
  c.organization_id,
  c.client_company_id,
  c.contract_number,
  c.title,
  c.original_value_paise,
  c.revised_value_paise,
  coalesce(b.billed_paise, 0)::bigint as billed_paise,
  coalesce(r.received_paise, 0)::bigint as received_paise,
  greatest(coalesce(b.billed_paise, 0) - coalesce(a.allocated_paise, 0), 0)::bigint as pending_against_bills_paise,
  coalesce(d.deductions_paise, 0)::bigint as deductions_paise,
  coalesce(d.non_retention_deductions_paise, 0)::bigint as non_retention_deductions_paise,
  greatest(coalesce(b.billed_paise, 0) - coalesce(a.allocated_paise, 0) - coalesce(d.non_retention_deductions_paise, 0), 0)::bigint as pending_after_deductions_paise,
  coalesce(d.retention_paise, 0)::bigint as retention_paise,
  greatest(c.revised_value_paise - coalesce(b.billed_paise, 0), 0)::bigint as not_yet_billed_paise
from public.contracts c
left join (
  select organization_id, contract_id, sum(amount_paise) billed_paise
  from public.client_bills where status not in ('draft','rejected','cancelled')
  group by organization_id, contract_id
) b on b.organization_id=c.organization_id and b.contract_id=c.id
left join (
  select organization_id, contract_id, sum(amount_paise) received_paise
  from public.client_receipts group by organization_id, contract_id
) r on r.organization_id=c.organization_id and r.contract_id=c.id
left join (
  select cr.organization_id, cb.contract_id, sum(cr.amount_paise) allocated_paise
  from public.client_receipt_allocations cr
  join public.client_bills cb on cb.id=cr.bill_id and cb.organization_id=cr.organization_id
  group by cr.organization_id, cb.contract_id
) a on a.organization_id=c.organization_id and a.contract_id=c.id
left join (
  select organization_id, contract_id,
    sum(amount_paise) deductions_paise,
    sum(amount_paise) filter (where category not in ('retention','security_deposit') and recoverable=false) non_retention_deductions_paise,
    sum(amount_paise) filter (where category in ('retention','security_deposit')) retention_paise
  from public.client_deductions group by organization_id, contract_id
) d on d.organization_id=c.organization_id and d.contract_id=c.id;

-- ============================================================
-- 3. Vendors and material procurement
-- ============================================================

create table if not exists public.vendors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  gstin text,
  pan text,
  contact_person text,
  phone text,
  email text,
  address text,
  state text,
  state_code text,
  notes text,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, name)
);

create table if not exists public.material_purchases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  vendor_id uuid not null,
  purchase_number text,
  vendor_invoice_number text,
  purchase_date date not null default current_date,
  subtotal_paise bigint not null default 0 check (subtotal_paise >= 0),
  gst_amount_paise bigint not null default 0 check (gst_amount_paise >= 0),
  other_charges_paise bigint not null default 0 check (other_charges_paise >= 0),
  total_amount_paise bigint not null default 0 check (total_amount_paise >= 0),
  status text not null default 'draft' check (status in ('draft','received','cancelled')),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, vendor_id)
    references public.vendors(organization_id, id) on delete restrict
);

create table if not exists public.material_purchase_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  purchase_id uuid not null,
  material_id uuid not null,
  material_name_snapshot text not null,
  unit_name_snapshot text,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_purchase_price_paise bigint not null check (unit_purchase_price_paise >= 0),
  gst_rate numeric(5,2) not null default 0 check (gst_rate between 0 and 100),
  line_total_paise bigint not null check (line_total_paise >= 0),
  created_at timestamptz not null default now(),
  foreign key (organization_id, purchase_id)
    references public.material_purchases(organization_id, id) on delete restrict,
  foreign key (organization_id, material_id)
    references public.materials(organization_id, id) on delete restrict
);

create index if not exists idx_material_purchases_vendor on public.material_purchases(organization_id, vendor_id, purchase_date desc);
create index if not exists idx_purchase_items_material on public.material_purchase_items(organization_id, material_id);

-- ============================================================
-- 4. Contractors and contractor work orders (POs)
-- ============================================================

create table if not exists public.contractors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  contractor_type text not null default 'subcontractor'
    check (contractor_type in ('contractor','subcontractor','individual')),
  gstin text,
  pan text,
  contact_person text,
  phone text,
  email text,
  address text,
  state text,
  state_code text,
  notes text,
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, name)
);

create table if not exists public.contractor_material_rates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contractor_id uuid not null,
  material_id uuid not null,
  unit_rate_paise bigint not null check (unit_rate_paise >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, contractor_id, material_id),
  foreign key (organization_id, contractor_id)
    references public.contractors(organization_id, id) on delete cascade,
  foreign key (organization_id, material_id)
    references public.materials(organization_id, id) on delete restrict
);

create index if not exists idx_contractor_material_rates_lookup
  on public.contractor_material_rates(organization_id, contractor_id, material_id);

create table if not exists public.contractor_work_orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  po_number text not null,
  contract_id uuid not null,
  project_id uuid,
  contractor_id uuid not null,
  po_date date not null default current_date,
  work_description text,
  payment_basis text not null check (payment_basis in ('fixed','percentage')),
  fixed_amount_paise bigint,
  percentage_rate numeric(7,4),
  percentage_base_value_paise bigint,
  agreed_work_amount_paise bigint not null check (agreed_work_amount_paise >= 0),
  currency_code text not null default 'INR' check (currency_code = 'INR'),
  start_date date,
  expected_completion_date date,
  actual_completion_date date,
  status text not null default 'active'
    check (status in ('draft','active','work_completed','under_closure','settled','cancelled')),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, po_number),
  foreign key (organization_id, contract_id)
    references public.contracts(organization_id, id) on delete restrict,
  foreign key (organization_id, project_id)
    references public.projects(organization_id, id) on delete restrict,
  foreign key (organization_id, contractor_id)
    references public.contractors(organization_id, id) on delete restrict,
  check (
    (payment_basis='fixed' and fixed_amount_paise is not null and fixed_amount_paise >= 0
      and percentage_rate is null and percentage_base_value_paise is null)
    or
    (payment_basis='percentage' and fixed_amount_paise is null
      and percentage_rate is not null and percentage_rate > 0 and percentage_rate <= 100
      and percentage_base_value_paise is not null and percentage_base_value_paise >= 0)
  )
);

-- Align an existing contractor_work_orders table from the earlier project-led
-- schema with the contract-led construction workflow. The contract is derived
-- from the already-linked project, preserving the relationship and existing
-- rows. Legacy column names are renamed rather than discarded.
do $migration$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='contractor_work_orders'
      and column_name='agreed_percentage'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='contractor_work_orders'
      and column_name='percentage_rate'
  ) then
    alter table public.contractor_work_orders rename column agreed_percentage to percentage_rate;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='contractor_work_orders'
      and column_name='basis_contract_value_paise'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='contractor_work_orders'
      and column_name='percentage_base_value_paise'
  ) then
    alter table public.contractor_work_orders rename column basis_contract_value_paise to percentage_base_value_paise;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='contractor_work_orders'
      and column_name='scope_of_work'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='contractor_work_orders'
      and column_name='work_description'
  ) then
    alter table public.contractor_work_orders rename column scope_of_work to work_description;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='contractor_work_orders'
      and column_name='expected_end_date'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='contractor_work_orders'
      and column_name='expected_completion_date'
  ) then
    alter table public.contractor_work_orders rename column expected_end_date to expected_completion_date;
  end if;

  if exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='contractor_work_orders'
      and column_name='actual_end_date'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='contractor_work_orders'
      and column_name='actual_completion_date'
  ) then
    alter table public.contractor_work_orders rename column actual_end_date to actual_completion_date;
  end if;
end $migration$;

alter table public.contractor_work_orders
  add column if not exists contract_id uuid,
  add column if not exists project_id uuid,
  add column if not exists work_description text,
  add column if not exists percentage_rate numeric(7,4),
  add column if not exists percentage_base_value_paise bigint,
  add column if not exists currency_code text not null default 'INR',
  add column if not exists expected_completion_date date,
  add column if not exists actual_completion_date date;

-- A legacy work order was attached to a project; projects already identify
-- their awarded contract. Backfill that contract before enforcing the
-- current required relationship.
update public.contractor_work_orders wo
set contract_id = p.contract_id
from public.projects p
where p.id = wo.project_id
  and p.organization_id = wo.organization_id
  and wo.contract_id is null;

do $migration$
begin
  if exists (
    select 1 from public.contractor_work_orders
    where contract_id is null
  ) then
    raise exception 'Cannot upgrade contractor_work_orders: one or more rows have no project-to-contract mapping';
  end if;
end $migration$;

alter table public.contractor_work_orders
  alter column contract_id set not null,
  alter column project_id drop not null;

create unique index if not exists uq_contractor_work_orders_organization_id_id
  on public.contractor_work_orders(organization_id, id);

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='contractor_work_orders_organization_contract_fk'
      and conrelid='public.contractor_work_orders'::regclass
  ) then
    alter table public.contractor_work_orders
      add constraint contractor_work_orders_organization_contract_fk
      foreign key (organization_id, contract_id)
      references public.contracts(organization_id, id) on delete restrict;
  end if;
end $migration$;

create index if not exists idx_work_orders_contractor on public.contractor_work_orders(organization_id, contractor_id, po_date desc);
create index if not exists idx_work_orders_contract on public.contractor_work_orders(organization_id, contract_id);
create index if not exists idx_work_orders_project on public.contractor_work_orders(organization_id, project_id);

-- ============================================================
-- 5. Daily material issues, returns and contractor advances
-- ============================================================

create table if not exists public.material_issues (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  issue_number text not null,
  work_order_id uuid not null,
  issue_date date not null default current_date,
  notes text,
  status text not null default 'issued' check (status in ('issued','cancelled')),
  issued_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, issue_number),
  foreign key (organization_id, work_order_id)
    references public.contractor_work_orders(organization_id, id) on delete restrict
);

create table if not exists public.material_issue_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  issue_id uuid not null,
  material_id uuid not null,
  material_name_snapshot text not null,
  unit_name_snapshot text,
  quantity_issued numeric(14,3) not null check (quantity_issued > 0),
  purchase_unit_cost_paise bigint not null check (purchase_unit_cost_paise >= 0),
  contractor_unit_rate_paise bigint not null check (contractor_unit_rate_paise >= 0),
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, issue_id)
    references public.material_issues(organization_id, id) on delete restrict,
  foreign key (organization_id, material_id)
    references public.materials(organization_id, id) on delete restrict
);

create table if not exists public.material_returns (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  return_number text not null,
  work_order_id uuid not null,
  return_date date not null default current_date,
  notes text,
  received_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, return_number),
  foreign key (organization_id, work_order_id)
    references public.contractor_work_orders(organization_id, id) on delete restrict
);

create table if not exists public.material_return_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  return_id uuid not null,
  issue_item_id uuid not null,
  material_id uuid not null,
  quantity_returned numeric(14,3) not null check (quantity_returned > 0),
  created_at timestamptz not null default now(),
  foreign key (organization_id, return_id)
    references public.material_returns(organization_id, id) on delete restrict,
  foreign key (organization_id, issue_item_id)
    references public.material_issue_items(organization_id, id) on delete restrict,
  foreign key (organization_id, material_id)
    references public.materials(organization_id, id) on delete restrict
);

create index if not exists idx_material_issues_work_order on public.material_issues(organization_id, work_order_id, issue_date desc);
create index if not exists idx_material_issue_items_material on public.material_issue_items(organization_id, material_id);
create index if not exists idx_material_returns_work_order on public.material_returns(organization_id, work_order_id, return_date desc);

create table if not exists public.contractor_advances (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  work_order_id uuid not null,
  advance_date date not null default current_date,
  amount_paise bigint not null check (amount_paise > 0),
  payment_method public.payment_method not null default 'cash',
  reference_number text,
  notes text,
  paid_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, id),
  foreign key (organization_id, work_order_id)
    references public.contractor_work_orders(organization_id, id) on delete restrict
);

create index if not exists idx_contractor_advances_work_order on public.contractor_advances(organization_id, work_order_id, advance_date desc);

-- ============================================================
-- 6. Material reconciliation and contractor settlement
-- ============================================================

create table if not exists public.material_reconciliations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  work_order_id uuid not null,
  issue_item_id uuid not null,
  quantity_used numeric(14,3) not null default 0 check (quantity_used >= 0),
  notes text,
  reconciled_by uuid references public.profiles(id) on delete set null,
  reconciled_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, work_order_id, issue_item_id),
  foreign key (organization_id, work_order_id)
    references public.contractor_work_orders(organization_id, id) on delete restrict,
  foreign key (organization_id, issue_item_id)
    references public.material_issue_items(organization_id, id) on delete restrict
);

-- Reconciliation quantity is derived from issue, usage and return ledger rows.
drop view if exists public.contractor_material_reconciliation_summary;
create view public.contractor_material_reconciliation_summary
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
join public.material_issues mi on mi.id=ii.issue_id and mi.organization_id=ii.organization_id and mi.status='issued'
join public.contractor_work_orders wo on wo.id=mi.work_order_id and wo.organization_id=ii.organization_id
left join (
  select organization_id, issue_item_id, sum(quantity_returned) returned_quantity
  from public.material_return_items group by organization_id, issue_item_id
) r on r.organization_id=ii.organization_id and r.issue_item_id=ii.id
left join public.material_reconciliations mc on mc.organization_id=ii.organization_id and mc.issue_item_id=ii.id;

create table if not exists public.contractor_settlements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  settlement_number text not null,
  work_order_id uuid not null,
  settlement_date date not null default current_date,
  agreed_work_amount_paise bigint not null check (agreed_work_amount_paise >= 0),
  material_charges_paise bigint not null default 0 check (material_charges_paise >= 0),
  advances_adjusted_paise bigint not null default 0 check (advances_adjusted_paise >= 0),
  other_deductions_paise bigint not null default 0 check (other_deductions_paise >= 0),
  adjustments_paise bigint not null default 0,
  final_payable_paise bigint not null check (final_payable_paise >= 0),
  status text not null default 'draft' check (status in ('draft','approved','partially_paid','paid','cancelled')),
  notes text,
  prepared_by uuid references public.profiles(id) on delete set null,
  approved_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id),
  unique (organization_id, settlement_number),
  foreign key (organization_id, work_order_id)
    references public.contractor_work_orders(organization_id, id) on delete restrict
);

create unique index if not exists uq_active_settlement_per_work_order
  on public.contractor_settlements(organization_id, work_order_id)
  where status <> 'cancelled';

-- Existing customer databases may have contractor_settlements keyed only by id.
-- The tenant-scoped payment foreign key below references (organization_id, id),
-- so ensure that exact column pair is unique even when the table predates this migration.
create unique index if not exists uq_contractor_settlements_organization_id_id
  on public.contractor_settlements(organization_id, id);

create table if not exists public.contractor_settlement_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  settlement_id uuid not null,
  payment_date date not null default current_date,
  amount_paise bigint not null check (amount_paise > 0),
  payment_method public.payment_method not null default 'bank_transfer',
  reference_number text,
  notes text,
  paid_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (organization_id, settlement_id)
    references public.contractor_settlements(organization_id, id) on delete restrict
);

create index if not exists idx_settlement_payments_settlement on public.contractor_settlement_payments(organization_id, settlement_id, payment_date desc);

-- ============================================================
-- 7. Access policies, triggers and audit visibility
-- ============================================================

do $$
declare t text;
begin
  foreach t in array array[
    'client_companies','contracts','projects','client_bills','client_receipts',
    'client_receipt_allocations','client_deductions','vendors','material_purchases',
    'material_purchase_items','contractors','contractor_work_orders','material_issues',
    'material_issue_items','material_returns','material_return_items','contractor_material_rates',
    'contractor_advances','material_reconciliations','contractor_settlements',
    'contractor_settlement_payments'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_member_all', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id))',
      t || '_member_all', t
    );
  end loop;
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'client_companies','contracts','projects','client_bills','vendors',
    'material_purchases','contractors','contractor_material_rates','contractor_work_orders','contractor_settlements'
  ] loop
    execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_updated_at', t);
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.set_updated_at()',
      'trg_' || t || '_updated_at', t
    );
  end loop;
end $$;

-- Append audit events for new construction-domain records. Financial mutations
-- will be performed by narrowly scoped RPCs in the next migration.
insert into public.app_schema_version(version) values (13) on conflict (version) do nothing;

commit;
