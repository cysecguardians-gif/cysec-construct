-- Material Management System
-- Customer operations and customer-level balance helpers.
-- Apply after 0003_bootstrap_and_connection.sql.
-- Run manually in the customer's Supabase SQL Editor.

begin;

create index if not exists idx_customers_org_active_name
  on public.customers(organization_id, is_active, name);

create or replace function public.create_customer(
  p_organization_id uuid,
  p_name text,
  p_gstin text default null,
  p_pan text default null,
  p_phone text default null,
  p_email text default null,
  p_billing_address_line1 text default null,
  p_billing_address_line2 text default null,
  p_billing_city text default null,
  p_billing_state text default null,
  p_billing_state_code text default null,
  p_billing_postal_code text default null,
  p_shipping_address_line1 text default null,
  p_shipping_address_line2 text default null,
  p_shipping_city text default null,
  p_shipping_state text default null,
  p_shipping_state_code text default null,
  p_shipping_postal_code text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_customer_id uuid;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_access_required'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'customer_name_required'; end if;

  insert into public.customers (
    organization_id, name, gstin, pan, phone, email,
    billing_address_line1, billing_address_line2, billing_city, billing_state, billing_state_code, billing_postal_code,
    shipping_address_line1, shipping_address_line2, shipping_city, shipping_state, shipping_state_code, shipping_postal_code
  ) values (
    p_organization_id, trim(p_name), nullif(trim(p_gstin), ''), nullif(trim(p_pan), ''), nullif(trim(p_phone), ''), nullif(trim(p_email), ''),
    nullif(trim(p_billing_address_line1), ''), nullif(trim(p_billing_address_line2), ''), nullif(trim(p_billing_city), ''), nullif(trim(p_billing_state), ''), nullif(trim(p_billing_state_code), ''), nullif(trim(p_billing_postal_code), ''),
    nullif(trim(p_shipping_address_line1), ''), nullif(trim(p_shipping_address_line2), ''), nullif(trim(p_shipping_city), ''), nullif(trim(p_shipping_state), ''), nullif(trim(p_shipping_state_code), ''), nullif(trim(p_shipping_postal_code), '')
  ) returning id into v_customer_id;

  insert into public.audit_log(organization_id, user_id, action, entity_type, entity_id, details)
  values (p_organization_id, v_user_id, 'customer_created', 'customer', v_customer_id, jsonb_build_object('name', trim(p_name)));

  return v_customer_id;
end;
$$;

grant execute on function public.create_customer(uuid, text, text, text, text, text, text, text, text, text, text, text, text, text, text, text, text, text) to authenticated;

create or replace function public.update_customer(
  p_customer_id uuid,
  p_organization_id uuid,
  p_name text,
  p_gstin text default null,
  p_pan text default null,
  p_phone text default null,
  p_email text default null,
  p_billing_address_line1 text default null,
  p_billing_address_line2 text default null,
  p_billing_city text default null,
  p_billing_state text default null,
  p_billing_state_code text default null,
  p_billing_postal_code text default null,
  p_shipping_address_line1 text default null,
  p_shipping_address_line2 text default null,
  p_shipping_city text default null,
  p_shipping_state text default null,
  p_shipping_state_code text default null,
  p_shipping_postal_code text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_access_required'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'customer_name_required'; end if;

  update public.customers
  set name = trim(p_name),
      gstin = nullif(trim(p_gstin), ''), pan = nullif(trim(p_pan), ''), phone = nullif(trim(p_phone), ''), email = nullif(trim(p_email), ''),
      billing_address_line1 = nullif(trim(p_billing_address_line1), ''), billing_address_line2 = nullif(trim(p_billing_address_line2), ''), billing_city = nullif(trim(p_billing_city), ''), billing_state = nullif(trim(p_billing_state), ''), billing_state_code = nullif(trim(p_billing_state_code), ''), billing_postal_code = nullif(trim(p_billing_postal_code), ''),
      shipping_address_line1 = nullif(trim(p_shipping_address_line1), ''), shipping_address_line2 = nullif(trim(p_shipping_address_line2), ''), shipping_city = nullif(trim(p_shipping_city), ''), shipping_state = nullif(trim(p_shipping_state), ''), shipping_state_code = nullif(trim(p_shipping_state_code), ''), shipping_postal_code = nullif(trim(p_shipping_postal_code), '')
  where id = p_customer_id and organization_id = p_organization_id;

  if not found then raise exception 'customer_not_found'; end if;

  insert into public.audit_log(organization_id, user_id, action, entity_type, entity_id, details)
  values (p_organization_id, v_user_id, 'customer_updated', 'customer', p_customer_id, jsonb_build_object('name', trim(p_name)));
  return true;
end;
$$;

grant execute on function public.update_customer(uuid, uuid, text, text, text, text, text, text, text, text, text, text, text, text, text, text, text, text, text) to authenticated;

create or replace function public.set_customer_active(
  p_customer_id uuid,
  p_organization_id uuid,
  p_is_active boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_access_required'; end if;
  update public.customers set is_active = p_is_active where id = p_customer_id and organization_id = p_organization_id;
  if not found then raise exception 'customer_not_found'; end if;
  insert into public.audit_log(organization_id, user_id, action, entity_type, entity_id, details)
  values (p_organization_id, v_user_id, case when p_is_active then 'customer_activated' else 'customer_deactivated' end, 'customer', p_customer_id, jsonb_build_object('is_active', p_is_active));
  return true;
end;
$$;

grant execute on function public.set_customer_active(uuid, uuid, boolean) to authenticated;

commit;
