-- Material Management System
-- Initial India / INR schema
-- Apply this migration manually in the customer's Supabase SQL Editor.
-- Never place a service-role key or database password in the desktop application.

begin;

create extension if not exists pgcrypto;

-- ============================================================
-- Enums
-- ============================================================

do $$ begin
  create type public.app_role as enum ('admin', 'staff');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.invoice_status as enum ('draft', 'issued', 'cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.payment_method as enum ('cash', 'upi', 'bank_transfer', 'cheque', 'card', 'other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.stock_movement_type as enum ('opening', 'purchase', 'sale', 'adjustment_in', 'adjustment_out', 'return_in', 'return_out');
exception when duplicate_object then null; end $$;

-- ============================================================
-- Common trigger
-- ============================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ============================================================
-- Organizations / users / access
-- ============================================================

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  legal_name text not null,
  trade_name text,
  gstin text,
  pan text,
  phone text,
  email text,
  address_line1 text,
  address_line2 text,
  city text,
  state text not null,
  state_code text not null,
  postal_code text,
  country text not null default 'India',
  currency_code text not null default 'INR' check (currency_code = 'INR'),
  currency_symbol text not null default '₹' check (currency_symbol = '₹'),
  locale text not null default 'en-IN' check (locale = 'en-IN'),
  invoice_prefix text not null default 'INV',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.app_role not null default 'staff',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, user_id)
);

create index if not exists idx_org_members_user on public.organization_members(user_id);
create index if not exists idx_org_members_org on public.organization_members(organization_id);

create or replace function public.is_org_member(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.organization_members om
    where om.organization_id = target_org
      and om.user_id = auth.uid()
      and om.is_active = true
  );
$$;

create or replace function public.is_org_admin(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.organization_members om
    where om.organization_id = target_org
      and om.user_id = auth.uid()
      and om.is_active = true
      and om.role = 'admin'
  );
$$;

-- ============================================================
-- Login/session tracking
-- ============================================================

create table if not exists public.login_sessions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  login_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  logout_at timestamptz,
  ended_reason text,
  created_at timestamptz not null default now()
);

create index if not exists idx_login_sessions_org_user on public.login_sessions(organization_id, user_id);
create index if not exists idx_login_sessions_login_at on public.login_sessions(login_at desc);

-- ============================================================
-- Materials / units / stock
-- ============================================================

create table if not exists public.material_categories (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, name)
);

create table if not exists public.units (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  short_code text not null,
  created_at timestamptz not null default now(),
  unique (organization_id, short_code)
);

create table if not exists public.materials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  category_id uuid references public.material_categories(id) on delete set null,
  unit_id uuid references public.units(id) on delete set null,
  name text not null,
  description text,
  hsn_sac_code text,
  gst_rate numeric(5,2) not null default 0 check (gst_rate >= 0 and gst_rate <= 100),
  selling_price_paise bigint not null default 0 check (selling_price_paise >= 0),
  current_quantity numeric(14,3) not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, name)
);

create index if not exists idx_materials_org on public.materials(organization_id);
create index if not exists idx_materials_category on public.materials(category_id);
create index if not exists idx_materials_active on public.materials(organization_id, is_active);

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  material_id uuid not null references public.materials(id) on delete restrict,
  movement_type public.stock_movement_type not null,
  quantity numeric(14,3) not null check (quantity > 0),
  reference_type text,
  reference_id uuid,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_stock_movements_material on public.stock_movements(material_id, created_at desc);
create index if not exists idx_stock_movements_org on public.stock_movements(organization_id, created_at desc);

-- ============================================================
-- Customers
-- ============================================================

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  gstin text,
  pan text,
  phone text,
  email text,
  billing_address_line1 text,
  billing_address_line2 text,
  billing_city text,
  billing_state text,
  billing_state_code text,
  billing_postal_code text,
  shipping_address_line1 text,
  shipping_address_line2 text,
  shipping_city text,
  shipping_state text,
  shipping_state_code text,
  shipping_postal_code text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_customers_org on public.customers(organization_id);
create index if not exists idx_customers_name on public.customers(organization_id, name);

-- ============================================================
-- Invoices
-- ============================================================

create table if not exists public.invoice_sequences (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  financial_year text not null,
  next_number bigint not null default 1 check (next_number > 0),
  primary key (organization_id, financial_year)
);

create table if not exists public.invoices (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete restrict,
  invoice_number text,
  invoice_date date not null default current_date,
  place_of_supply_state text,
  place_of_supply_state_code text,
  status public.invoice_status not null default 'draft',

  -- Optional discount. All monetary amounts are stored as integer paise.
  discount_enabled boolean not null default false,
  discount_type text check (discount_type in ('percentage', 'fixed') or discount_type is null),
  discount_value numeric(12,2) check (discount_value is null or discount_value >= 0),
  discount_amount_paise bigint not null default 0 check (discount_amount_paise >= 0),

  -- Optional GST. When disabled, all GST amounts must remain zero.
  gst_enabled boolean not null default false,
  cgst_amount_paise bigint not null default 0 check (cgst_amount_paise >= 0),
  sgst_amount_paise bigint not null default 0 check (sgst_amount_paise >= 0),
  igst_amount_paise bigint not null default 0 check (igst_amount_paise >= 0),

  subtotal_paise bigint not null default 0 check (subtotal_paise >= 0),
  taxable_value_paise bigint not null default 0 check (taxable_value_paise >= 0),
  total_gst_paise bigint not null default 0 check (total_gst_paise >= 0),
  grand_total_paise bigint not null default 0 check (grand_total_paise >= 0),

  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  check (
    (gst_enabled = true)
    or (cgst_amount_paise = 0 and sgst_amount_paise = 0 and igst_amount_paise = 0 and total_gst_paise = 0)
  ),
  check (
    (discount_enabled = true)
    or (discount_amount_paise = 0 and discount_type is null and discount_value is null)
  )
);

create unique index if not exists uq_invoices_org_invoice_number
  on public.invoices(organization_id, invoice_number)
  where invoice_number is not null;

create index if not exists idx_invoices_org_date on public.invoices(organization_id, invoice_date desc);
create index if not exists idx_invoices_customer on public.invoices(customer_id, invoice_date desc);
create index if not exists idx_invoices_status on public.invoices(organization_id, status);

create table if not exists public.invoice_items (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  material_id uuid references public.materials(id) on delete set null,

  -- Immutable invoice snapshots so future material edits do not change old invoices.
  description text not null,
  hsn_sac_code text,
  unit_name text,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_price_paise bigint not null check (unit_price_paise >= 0),
  discount_amount_paise bigint not null default 0 check (discount_amount_paise >= 0),
  taxable_value_paise bigint not null check (taxable_value_paise >= 0),

  gst_rate numeric(5,2) not null default 0 check (gst_rate >= 0 and gst_rate <= 100),
  cgst_amount_paise bigint not null default 0 check (cgst_amount_paise >= 0),
  sgst_amount_paise bigint not null default 0 check (sgst_amount_paise >= 0),
  igst_amount_paise bigint not null default 0 check (igst_amount_paise >= 0),
  line_total_paise bigint not null check (line_total_paise >= 0),

  created_at timestamptz not null default now()
);

create index if not exists idx_invoice_items_invoice on public.invoice_items(invoice_id);

-- ============================================================
-- Payments
-- ============================================================

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  amount_paise bigint not null check (amount_paise > 0),
  payment_date date not null default current_date,
  payment_method public.payment_method not null,
  reference_number text,
  notes text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create index if not exists idx_payments_invoice on public.payments(invoice_id, payment_date desc);
create index if not exists idx_payments_org on public.payments(organization_id, payment_date desc);

-- ============================================================
-- Audit log
-- ============================================================

create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_audit_log_org_date on public.audit_log(organization_id, created_at desc);
create index if not exists idx_audit_log_entity on public.audit_log(entity_type, entity_id);

-- ============================================================
-- Useful views
-- ============================================================

create or replace view public.invoice_payment_summary as
select
  i.id as invoice_id,
  i.organization_id,
  i.customer_id,
  i.invoice_number,
  i.invoice_date,
  i.status as invoice_status,
  i.grand_total_paise,
  coalesce(sum(p.amount_paise), 0)::bigint as paid_amount_paise,
  greatest(i.grand_total_paise - coalesce(sum(p.amount_paise), 0), 0)::bigint as pending_amount_paise,
  case
    when i.status = 'cancelled' then 'cancelled'
    when coalesce(sum(p.amount_paise), 0) = 0 then 'pending'
    when coalesce(sum(p.amount_paise), 0) < i.grand_total_paise then 'partially_paid'
    else 'paid'
  end as payment_status
from public.invoices i
left join public.payments p on p.invoice_id = i.id
 group by i.id;

create or replace view public.customer_balance_summary as
select
  c.id as customer_id,
  c.organization_id,
  c.name,
  coalesce(sum(ips.grand_total_paise) filter (where ips.invoice_status <> 'cancelled'), 0)::bigint as total_invoiced_paise,
  coalesce(sum(ips.paid_amount_paise) filter (where ips.invoice_status <> 'cancelled'), 0)::bigint as total_paid_paise,
  coalesce(sum(ips.pending_amount_paise) filter (where ips.invoice_status <> 'cancelled'), 0)::bigint as total_pending_paise
from public.customers c
left join public.invoice_payment_summary ips on ips.customer_id = c.id
 group by c.id;

-- ============================================================
-- Updated-at triggers
-- ============================================================

drop trigger if exists trg_organizations_updated_at on public.organizations;
create trigger trg_organizations_updated_at before update on public.organizations
for each row execute function public.set_updated_at();

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists trg_org_members_updated_at on public.organization_members;
create trigger trg_org_members_updated_at before update on public.organization_members
for each row execute function public.set_updated_at();

drop trigger if exists trg_material_categories_updated_at on public.material_categories;
create trigger trg_material_categories_updated_at before update on public.material_categories
for each row execute function public.set_updated_at();

drop trigger if exists trg_materials_updated_at on public.materials;
create trigger trg_materials_updated_at before update on public.materials
for each row execute function public.set_updated_at();

drop trigger if exists trg_customers_updated_at on public.customers;
create trigger trg_customers_updated_at before update on public.customers
for each row execute function public.set_updated_at();

drop trigger if exists trg_invoices_updated_at on public.invoices;
create trigger trg_invoices_updated_at before update on public.invoices
for each row execute function public.set_updated_at();

-- ============================================================
-- Row Level Security
-- ============================================================

alter table public.organizations enable row level security;
alter table public.profiles enable row level security;
alter table public.organization_members enable row level security;
alter table public.login_sessions enable row level security;
alter table public.material_categories enable row level security;
alter table public.units enable row level security;
alter table public.materials enable row level security;
alter table public.stock_movements enable row level security;
alter table public.customers enable row level security;
alter table public.invoice_sequences enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_items enable row level security;
alter table public.payments enable row level security;
alter table public.audit_log enable row level security;

-- Profiles: users can read/update their own profile.
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
for select to authenticated using (id = auth.uid());

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Memberships: members can see membership rows for their organizations.
drop policy if exists organization_members_select on public.organization_members;
create policy organization_members_select on public.organization_members
for select to authenticated using (public.is_org_member(organization_id));

drop policy if exists organization_members_admin_write on public.organization_members;
create policy organization_members_admin_write on public.organization_members
for all to authenticated
using (public.is_org_admin(organization_id))
with check (public.is_org_admin(organization_id));

-- Organization rows.
drop policy if exists organizations_select on public.organizations;
create policy organizations_select on public.organizations
for select to authenticated using (public.is_org_member(id));

drop policy if exists organizations_update_admin on public.organizations;
create policy organizations_update_admin on public.organizations
for update to authenticated using (public.is_org_admin(id)) with check (public.is_org_admin(id));

-- Tenant tables: members can read/write their organization's operational data.
drop policy if exists login_sessions_member_all on public.login_sessions;
create policy login_sessions_member_all on public.login_sessions
for all to authenticated using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

drop policy if exists material_categories_member_all on public.material_categories;
create policy material_categories_member_all on public.material_categories
for all to authenticated using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

drop policy if exists units_member_all on public.units;
create policy units_member_all on public.units
for all to authenticated using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

drop policy if exists materials_member_all on public.materials;
create policy materials_member_all on public.materials
for all to authenticated using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

drop policy if exists stock_movements_member_all on public.stock_movements;
create policy stock_movements_member_all on public.stock_movements
for all to authenticated using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

drop policy if exists customers_member_all on public.customers;
create policy customers_member_all on public.customers
for all to authenticated using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

drop policy if exists invoice_sequences_admin_all on public.invoice_sequences;
create policy invoice_sequences_admin_all on public.invoice_sequences
for all to authenticated using (public.is_org_admin(organization_id)) with check (public.is_org_admin(organization_id));

drop policy if exists invoices_member_all on public.invoices;
create policy invoices_member_all on public.invoices
for all to authenticated using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

drop policy if exists invoice_items_member_all on public.invoice_items;
create policy invoice_items_member_all on public.invoice_items
for all to authenticated
using (exists (select 1 from public.invoices i where i.id = invoice_items.invoice_id and public.is_org_member(i.organization_id)))
with check (exists (select 1 from public.invoices i where i.id = invoice_items.invoice_id and public.is_org_member(i.organization_id)));

drop policy if exists payments_member_all on public.payments;
create policy payments_member_all on public.payments
for all to authenticated using (public.is_org_member(organization_id)) with check (public.is_org_member(organization_id));

drop policy if exists audit_log_member_select on public.audit_log;
create policy audit_log_member_select on public.audit_log
for select to authenticated using (public.is_org_member(organization_id));

drop policy if exists audit_log_member_insert on public.audit_log;
create policy audit_log_member_insert on public.audit_log
for insert to authenticated with check (public.is_org_member(organization_id));

-- Views run with the caller's permissions and therefore respect the underlying RLS.

commit;
