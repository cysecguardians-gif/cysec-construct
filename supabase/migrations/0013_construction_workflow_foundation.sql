-- Construction workflow foundation for Material Management System.
-- Adds client contracts, projects, vendors, contractor work orders, material issues/returns,
-- advances, client receivables, and contractor settlement snapshots.
-- Apply after 0012_import_integrity.sql. Existing customer/invoice history is preserved.

begin;

-- ============================================================
-- 1. Client companies, contracts and projects
-- ============================================================

create table if not exists public.client_companies (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  gstin text,
  pan text,
  contact_person text,
  phone text,
  email text,
  billing_address text,
  city text,
  state text,
  state_code text,
  postal_code text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);
create index if not exists idx_client_companies_org_name on public.client_companies(organization_id, name);

create table if not exists public.contracts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  client_company_id uuid not null references public.client_companies(id) on delete restrict,
  contract_number text not null,
  title text not null,
  contract_type text not null default 'tender' check (contract_type in ('tender','direct_contract','work_order','other')),
  contract_date date not null default current_date,
  start_date date,
  expected_end_date date,
  actual_end_date date,
  original_value_paise bigint not null check (original_value_paise >= 0),
  revised_value_paise bigint not null check (revised_value_paise >= 0),
  currency_code text not null default 'INR' check (currency_code = 'INR'),
  status text not null default 'active' check (status in ('draft','active','on_hold','completed','closed','cancelled')),
  scope_of_work text,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, contract_number),
  unique (organization_id, id),
  check (expected_end_date is null or start_date is null or expected_end_date >= start_date)
);
create index if not exists idx_contracts_org_date on public.contracts(organization_id, contract_date desc);
create index if not exists idx_contracts_client on public.contracts(client_company_id, contract_date desc);

create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete restrict,
  project_code text,
  name text not null,
  site_address text,
  site_contact text,
  site_phone text,
  start_date date,
  expected_end_date date,
  actual_end_date date,
  status text not null default 'active' check (status in ('planned','active','on_hold','completed','closed','cancelled')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);
create index if not exists idx_projects_contract on public.projects(contract_id);
create index if not exists idx_projects_org_status on public.projects(organization_id, status);

-- ============================================================
-- 2. Vendors and material purchases
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
  city text,
  state text,
  state_code text,
  postal_code text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);
create index if not exists idx_vendors_org_name on public.vendors(organization_id, name);

create table if not exists public.material_purchases (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  vendor_id uuid not null references public.vendors(id) on delete restrict,
  purchase_number text,
  vendor_invoice_number text,
  purchase_date date not null default current_date,
  subtotal_paise bigint not null default 0 check (subtotal_paise >= 0),
  gst_amount_paise bigint not null default 0 check (gst_amount_paise >= 0),
  other_charges_paise bigint not null default 0 check (other_charges_paise >= 0),
  total_amount_paise bigint not null default 0 check (total_amount_paise >= 0),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','partially_paid','paid')),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);
create index if not exists idx_material_purchases_org_date on public.material_purchases(organization_id, purchase_date desc);
create index if not exists idx_material_purchases_vendor on public.material_purchases(vendor_id, purchase_date desc);

create table if not exists public.material_purchase_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  purchase_id uuid not null references public.material_purchases(id) on delete restrict,
  material_id uuid not null references public.materials(id) on delete restrict,
  description_snapshot text not null,
  unit_name_snapshot text,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_cost_paise bigint not null check (unit_cost_paise >= 0),
  gst_rate numeric(5,2) not null default 0 check (gst_rate between 0 and 100),
  line_subtotal_paise bigint not null check (line_subtotal_paise >= 0),
  line_gst_paise bigint not null default 0 check (line_gst_paise >= 0),
  created_at timestamptz not null default now()
);
create index if not exists idx_material_purchase_items_purchase on public.material_purchase_items(purchase_id);
create index if not exists idx_material_purchase_items_material on public.material_purchase_items(material_id);

-- ============================================================
-- 3. Contractors, work orders, material issues and advances
-- ============================================================

create table if not exists public.contractors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  contractor_type text not null default 'subcontractor' check (contractor_type in ('contractor','subcontractor','individual','other')),
  gstin text,
  pan text,
  contact_person text,
  phone text,
  email text,
  address text,
  city text,
  state text,
  state_code text,
  postal_code text,
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, id)
);
create index if not exists idx_contractors_org_name on public.contractors(organization_id, name);

create table if not exists public.contractor_work_orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete restrict,
  contractor_id uuid not null references public.contractors(id) on delete restrict,
  po_number text not null,
  po_date date not null default current_date,
  payment_basis text not null check (payment_basis in ('fixed','percentage')),
  fixed_amount_paise bigint,
  agreed_percentage numeric(7,4),
  basis_contract_value_paise bigint not null check (basis_contract_value_paise >= 0),
  agreed_work_amount_paise bigint not null check (agreed_work_amount_paise >= 0),
  materials_chargeable boolean not null default true,
  start_date date,
  expected_end_date date,
  actual_end_date date,
  status text not null default 'draft' check (status in ('draft','active','on_hold','completed','settlement_pending','settled','cancelled')),
  scope_of_work text,
  terms_and_conditions text,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, po_number),
  unique (organization_id, id),
  check (
    (payment_basis = 'fixed' and fixed_amount_paise is not null and fixed_amount_paise >= 0 and agreed_percentage is null)
    or
    (payment_basis = 'percentage' and fixed_amount_paise is null and agreed_percentage > 0 and agreed_percentage <= 100)
  )
);
create index if not exists idx_contractor_work_orders_project on public.contractor_work_orders(project_id);
create index if not exists idx_contractor_work_orders_contractor on public.contractor_work_orders(contractor_id, po_date desc);
create index if not exists idx_contractor_work_orders_org_status on public.contractor_work_orders(organization_id, status);

create table if not exists public.material_issues (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  work_order_id uuid not null references public.contractor_work_orders(id) on delete restrict,
  contractor_id uuid not null references public.contractors(id) on delete restrict,
  project_id uuid not null references public.projects(id) on delete restrict,
  issue_number text,
  issue_date date not null default current_date,
  status text not null default 'issued' check (status in ('issued','partially_returned','reconciled','cancelled')),
  notes text,
  issued_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
create index if not exists idx_material_issues_work_order on public.material_issues(work_order_id, issue_date desc);
create index if not exists idx_material_issues_contractor_date on public.material_issues(contractor_id, issue_date desc);
create index if not exists idx_material_issues_project on public.material_issues(project_id, issue_date desc);

create table if not exists public.material_issue_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  issue_id uuid not null references public.material_issues(id) on delete restrict,
  material_id uuid not null references public.materials(id) on delete restrict,
  description_snapshot text not null,
  unit_name_snapshot text,
  quantity_issued numeric(14,3) not null check (quantity_issued > 0),
  purchase_unit_cost_paise bigint not null default 0 check (purchase_unit_cost_paise >= 0),
  contractor_unit_rate_paise bigint not null check (contractor_unit_rate_paise >= 0),
  created_at timestamptz not null default now()
);
create index if not exists idx_material_issue_items_issue on public.material_issue_items(issue_id);
create index if not exists idx_material_issue_items_material on public.material_issue_items(material_id);

create table if not exists public.contractor_advances (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  work_order_id uuid not null references public.contractor_work_orders(id) on delete restrict,
  contractor_id uuid not null references public.contractors(id) on delete restrict,
  advance_date date not null default current_date,
  amount_paise bigint not null check (amount_paise > 0),
  payment_method text not null default 'cash' check (payment_method in ('cash','upi','bank_transfer','cheque','card','other')),
  reference_number text,
  notes text,
  paid_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_contractor_advances_work_order on public.contractor_advances(work_order_id, advance_date desc);
create index if not exists idx_contractor_advances_contractor on public.contractor_advances(contractor_id, advance_date desc);

-- ============================================================
-- 4. Material returns and final reconciliation
-- ============================================================

create table if not exists public.material_returns (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  issue_id uuid not null references public.material_issues(id) on delete restrict,
  work_order_id uuid not null references public.contractor_work_orders(id) on delete restrict,
  contractor_id uuid not null references public.contractors(id) on delete restrict,
  project_id uuid not null references public.projects(id) on delete restrict,
  return_number text,
  return_date date not null default current_date,
  notes text,
  received_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, id)
);
create index if not exists idx_material_returns_issue on public.material_returns(issue_id, return_date desc);
create index if not exists idx_material_returns_work_order on public.material_returns(work_order_id, return_date desc);

create table if not exists public.material_return_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  return_id uuid not null references public.material_returns(id) on delete restrict,
  issue_item_id uuid not null references public.material_issue_items(id) on delete restrict,
  material_id uuid not null references public.materials(id) on delete restrict,
  quantity_returned numeric(14,3) not null check (quantity_returned > 0),
  condition text not null default 'usable' check (condition in ('usable','damaged','scrap')),
  notes text,
  created_at timestamptz not null default now()
);
create index if not exists idx_material_return_items_issue_item on public.material_return_items(issue_item_id);

create table if not exists public.material_reconciliations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  work_order_id uuid not null references public.contractor_work_orders(id) on delete restrict,
  issue_item_id uuid not null references public.material_issue_items(id) on delete restrict,
  quantity_issued numeric(14,3) not null check (quantity_issued >= 0),
  quantity_used numeric(14,3) not null check (quantity_used >= 0),
  quantity_returned numeric(14,3) not null check (quantity_returned >= 0),
  quantity_unaccounted numeric(14,3) not null check (quantity_unaccounted >= 0),
  unaccounted_reason text,
  verified_by uuid references public.profiles(id) on delete set null,
  verified_at timestamptz not null default now(),
  unique (issue_item_id),
  check (round(quantity_issued - quantity_used - quantity_returned - quantity_unaccounted, 3) = 0)
);
create index if not exists idx_material_reconciliations_work_order on public.material_reconciliations(work_order_id);

-- ============================================================
-- 5. Client bills, receipts and deductions
-- ============================================================

create table if not exists public.client_bills (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete restrict,
  bill_number text not null,
  bill_date date not null default current_date,
  period_from date,
  period_to date,
  amount_claimed_paise bigint not null check (amount_claimed_paise > 0),
  status text not null default 'submitted' check (status in ('draft','submitted','approved','partially_paid','paid','rejected')),
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, bill_number),
  unique (organization_id, id)
);
create index if not exists idx_client_bills_contract_date on public.client_bills(contract_id, bill_date desc);

create table if not exists public.client_receipts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete restrict,
  bill_id uuid references public.client_bills(id) on delete restrict,
  receipt_date date not null default current_date,
  amount_paise bigint not null check (amount_paise > 0),
  payment_method text not null default 'other' check (payment_method in ('cash','upi','bank_transfer','cheque','card','other')),
  reference_number text,
  notes text,
  recorded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_client_receipts_contract_date on public.client_receipts(contract_id, receipt_date desc);
create index if not exists idx_client_receipts_bill on public.client_receipts(bill_id);

create table if not exists public.client_deductions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete restrict,
  bill_id uuid references public.client_bills(id) on delete restrict,
  deduction_date date not null default current_date,
  deduction_type text not null check (deduction_type in ('tds','retention','security_deposit','penalty','material_recovery','other')),
  amount_paise bigint not null check (amount_paise > 0),
  is_recoverable boolean not null default false,
  reference_number text,
  notes text,
  recorded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_client_deductions_contract_date on public.client_deductions(contract_id, deduction_date desc);
create index if not exists idx_client_deductions_bill on public.client_deductions(bill_id);

-- ============================================================
-- 6. Contractor settlements (immutable calculation snapshots)
-- ============================================================

create table if not exists public.contractor_settlements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  work_order_id uuid not null references public.contractor_work_orders(id) on delete restrict,
  settlement_number text not null,
  settlement_date date not null default current_date,
  basis_contract_value_paise bigint not null check (basis_contract_value_paise >= 0),
  payment_basis text not null check (payment_basis in ('fixed','percentage')),
  agreed_percentage numeric(7,4),
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
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, settlement_number),
  unique (work_order_id)
);
create index if not exists idx_contractor_settlements_org_date on public.contractor_settlements(organization_id, settlement_date desc);

create table if not exists public.contractor_settlement_material_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  settlement_id uuid not null references public.contractor_settlements(id) on delete restrict,
  issue_item_id uuid not null references public.material_issue_items(id) on delete restrict,
  material_name_snapshot text not null,
  unit_name_snapshot text,
  quantity_issued numeric(14,3) not null check (quantity_issued >= 0),
  quantity_returned numeric(14,3) not null check (quantity_returned >= 0),
  chargeable_quantity numeric(14,3) not null check (chargeable_quantity >= 0),
  contractor_unit_rate_paise bigint not null check (contractor_unit_rate_paise >= 0),
  line_charge_paise bigint not null check (line_charge_paise >= 0),
  created_at timestamptz not null default now(),
  unique (settlement_id, issue_item_id)
);

create table if not exists public.contractor_settlement_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  settlement_id uuid not null references public.contractor_settlements(id) on delete restrict,
  payment_date date not null default current_date,
  amount_paise bigint not null check (amount_paise > 0),
  payment_method text not null default 'other' check (payment_method in ('cash','upi','bank_transfer','cheque','card','other')),
  reference_number text,
  notes text,
  paid_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists idx_contractor_settlement_payments on public.contractor_settlement_payments(settlement_id, payment_date desc);

-- ============================================================
-- 7. Updated-at triggers
-- ============================================================

do $$
declare t text;
begin
  foreach t in array array[
    'client_companies','contracts','projects','vendors','material_purchases',
    'contractors','contractor_work_orders','client_bills','contractor_settlements'
  ] loop
    execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_updated_at', t);
    execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()', 'trg_' || t || '_updated_at', t);
  end loop;
end $$;

-- ============================================================
-- 8. Tenant RLS. Members may operate; financial history has no DELETE policy.
-- ============================================================

do $$
declare t text;
begin
  foreach t in array array[
    'client_companies','contracts','projects','vendors','material_purchases',
    'material_purchase_items','contractors','contractor_work_orders',
    'material_issues','material_issue_items','contractor_advances',
    'material_returns','material_return_items','material_reconciliations',
    'client_bills','client_receipts','client_deductions',
    'contractor_settlements','contractor_settlement_material_lines',
    'contractor_settlement_payments'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_member_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_org_member(organization_id))', t || '_member_select', t);
    -- Writes are intentionally blocked at the table layer in this foundation migration.
    -- Subsequent migrations expose narrowly scoped SECURITY DEFINER transaction RPCs.
    execute format('drop policy if exists %I on public.%I', t || '_member_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_member_update', t);
  end loop;
end $$;

-- ============================================================
-- 9. Finance summaries. Retention is shown separately from deductions.
-- ============================================================

create or replace view public.contract_finance_summary
with (security_invoker = true) as
select
  c.id as contract_id,
  c.organization_id,
  c.client_company_id,
  cc.name as client_company_name,
  c.contract_number,
  c.title,
  c.original_value_paise,
  c.revised_value_paise,
  coalesce(b.total_billed_paise, 0)::bigint as total_billed_paise,
  coalesce(r.total_received_paise, 0)::bigint as total_received_paise,
  coalesce(d.total_deductions_paise, 0)::bigint as total_deductions_paise,
  coalesce(d.retention_paise, 0)::bigint as retention_paise,
  greatest(coalesce(b.total_billed_paise, 0) - coalesce(r.total_received_paise, 0) - coalesce(d.non_retention_deductions_paise, 0), 0)::bigint as pending_receivable_paise,
  greatest(c.revised_value_paise - coalesce(b.total_billed_paise, 0), 0)::bigint as unbilled_contract_value_paise
from public.contracts c
join public.client_companies cc on cc.id = c.client_company_id
left join (
  select contract_id, sum(amount_claimed_paise)::bigint as total_billed_paise
  from public.client_bills where status <> 'rejected' and status <> 'draft'
  group by contract_id
) b on b.contract_id = c.id
left join (
  select contract_id, sum(amount_paise)::bigint as total_received_paise
  from public.client_receipts group by contract_id
) r on r.contract_id = c.id
left join (
  select contract_id,
    sum(amount_paise)::bigint as total_deductions_paise,
    (sum(amount_paise) filter (where deduction_type = 'retention'))::bigint as retention_paise,
    (sum(amount_paise) filter (where deduction_type <> 'retention'))::bigint as non_retention_deductions_paise
  from public.client_deductions group by contract_id
) d on d.contract_id = c.id;

create or replace view public.contractor_work_order_summary
with (security_invoker = true) as
select
  wo.id as work_order_id,
  wo.organization_id,
  wo.project_id,
  p.contract_id,
  wo.contractor_id,
  ct.name as contractor_name,
  wo.po_number,
  wo.payment_basis,
  wo.agreed_percentage,
  wo.basis_contract_value_paise,
  wo.agreed_work_amount_paise,
  coalesce(a.total_advances_paise, 0)::bigint as total_advances_paise,
  coalesce(s.final_payable_paise, 0)::bigint as settlement_final_payable_paise,
  coalesce(sp.total_paid_paise, 0)::bigint as settlement_paid_paise,
  case when s.id is null then null else greatest(s.final_payable_paise - coalesce(sp.total_paid_paise, 0), 0)::bigint end as settlement_pending_paise,
  wo.status
from public.contractor_work_orders wo
join public.projects p on p.id = wo.project_id
join public.contractors ct on ct.id = wo.contractor_id
left join (
  select work_order_id, sum(amount_paise)::bigint as total_advances_paise
  from public.contractor_advances group by work_order_id
) a on a.work_order_id = wo.id
left join public.contractor_settlements s on s.work_order_id = wo.id and s.status <> 'cancelled'
left join (
  select settlement_id, sum(amount_paise)::bigint as total_paid_paise
  from public.contractor_settlement_payments group by settlement_id
) sp on sp.settlement_id = s.id;

-- ============================================================
-- 10. Schema version
-- ============================================================

insert into public.app_schema_version(version) values (13)
on conflict (version) do nothing;

commit;
