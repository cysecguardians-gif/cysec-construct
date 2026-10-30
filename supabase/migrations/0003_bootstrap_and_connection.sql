-- Material Management System
-- Bootstrap, connection verification, and secure first-admin provisioning.
-- Apply after 0001_initial_schema.sql and 0002_transactional_operations.sql.
-- Run manually in the customer's Supabase SQL Editor.

begin;

create table if not exists public.app_schema_version (
  version integer primary key,
  applied_at timestamptz not null default now()
);

insert into public.app_schema_version(version)
values (3)
on conflict (version) do nothing;

create or replace function public.get_app_status()
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required';
  end if;
  return jsonb_build_object(
    'ok', true,
    'authenticated', true,
    'schema_version', (select max(version) from public.app_schema_version),
    'currency_code', 'INR',
    'locale', 'en-IN'
  );
end;
$$;

grant execute on function public.get_app_status() to authenticated;

create or replace function public.bootstrap_organization(
  p_legal_name text,
  p_trade_name text default null,
  p_gstin text default null,
  p_pan text default null,
  p_phone text default null,
  p_email text default null,
  p_address_line1 text default null,
  p_address_line2 text default null,
  p_city text default null,
  p_state text default null,
  p_state_code text default null,
  p_postal_code text default null,
  p_invoice_prefix text default 'INV'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_org_id uuid;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;
  if nullif(trim(p_legal_name), '') is null then raise exception 'legal_name_required'; end if;
  if nullif(trim(p_state), '') is null or nullif(trim(p_state_code), '') is null then raise exception 'state_and_state_code_required'; end if;
  if exists (select 1 from public.organization_members where user_id = v_user_id) then raise exception 'user_already_has_organization'; end if;

  insert into public.profiles(id) values (v_user_id) on conflict (id) do nothing;

  insert into public.organizations(
    legal_name, trade_name, gstin, pan, phone, email,
    address_line1, address_line2, city, state, state_code,
    postal_code, invoice_prefix
  ) values (
    trim(p_legal_name), nullif(trim(p_trade_name), ''), nullif(trim(p_gstin), ''), nullif(trim(p_pan), ''),
    nullif(trim(p_phone), ''), nullif(trim(p_email), ''), nullif(trim(p_address_line1), ''),
    nullif(trim(p_address_line2), ''), nullif(trim(p_city), ''), trim(p_state), trim(p_state_code),
    nullif(trim(p_postal_code), ''), coalesce(nullif(trim(p_invoice_prefix), ''), 'INV')
  ) returning id into v_org_id;

  insert into public.organization_members(organization_id, user_id, role, is_active)
  values (v_org_id, v_user_id, 'admin', true);

  insert into public.invoice_sequences(organization_id, financial_year, next_number)
  values (v_org_id, public.current_financial_year(), 1)
  on conflict do nothing;

  insert into public.audit_log(organization_id, user_id, action, entity_type, entity_id, details)
  values (v_org_id, v_user_id, 'organization_bootstrapped', 'organization', v_org_id, jsonb_build_object('legal_name', p_legal_name));

  return v_org_id;
end;
$$;

grant execute on function public.bootstrap_organization(text, text, text, text, text, text, text, text, text, text, text, text, text) to authenticated;

create or replace function public.seed_default_units(p_organization_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_count integer := 0;
  v_name text;
  v_code text;
begin
  if not public.is_org_admin(p_organization_id) then raise exception 'administrator_required'; end if;

  for v_name, v_code in
    select name, short_code from (values
      ('Piece','pcs'), ('Kilogram','kg'), ('Gram','g'), ('Tonne','ton'), ('Metre','m'),
      ('Square Metre','sqm'), ('Cubic Metre','cum'), ('Litre','L'), ('Box','box'), ('Bag','bag')
    ) as defaults(name, short_code)
  loop
    insert into public.units(organization_id, name, short_code)
    values (p_organization_id, v_name, v_code)
    on conflict (organization_id, short_code) do nothing;
    if found then v_count := v_count + 1; end if;
  end loop;

  insert into public.audit_log(organization_id, user_id, action, entity_type, details)
  values (p_organization_id, v_user_id, 'default_units_seeded', 'organization', jsonb_build_object('inserted_count', v_count));

  return v_count;
end;
$$;

grant execute on function public.seed_default_units(uuid) to authenticated;

commit;
