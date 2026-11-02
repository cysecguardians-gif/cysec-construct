-- Material Management System
-- First-admin lock and controlled historical data import helpers.
-- Apply after 0010_staff_membership_management.sql.

begin;

create or replace function public.get_setup_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_admin_exists boolean;
  v_schema_version integer;
begin
  select exists (
    select 1
    from public.organization_members
    where role = 'admin'
      and is_active = true
  ) into v_admin_exists;

  select coalesce(max(version), 0)
    into v_schema_version
    from public.app_schema_version;

  return jsonb_build_object(
    'initialized', v_admin_exists,
    'admin_exists', v_admin_exists,
    'schema_version', v_schema_version
  );
end;
$$;

grant execute on function public.get_setup_status() to anon, authenticated;

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
  v_admin_exists boolean;
begin
  if v_user_id is null then raise exception 'authentication_required'; end if;

  -- Serialize first-admin creation so two first-run clients cannot both win a race.
  perform pg_advisory_xact_lock(hashtextextended('material_management:first_admin', 0));

  select exists (
    select 1 from public.organization_members
    where role = 'admin' and is_active = true
  ) into v_admin_exists;

  if v_admin_exists then
    raise exception 'administrator_already_exists';
  end if;

  if nullif(trim(p_legal_name), '') is null then raise exception 'legal_name_required'; end if;
  if nullif(trim(p_state), '') is null or nullif(trim(p_state_code), '') is null then raise exception 'state_and_state_code_required'; end if;
  if exists (select 1 from public.organization_members where user_id = v_user_id) then raise exception 'user_already_has_organization'; end if;

  insert into public.profiles(id) values (v_user_id) on conflict (id) do nothing;

  insert into public.organizations(legal_name, trade_name, gstin, pan, phone, email, address_line1, address_line2, city, state, state_code, postal_code, invoice_prefix)
  values (
    trim(p_legal_name), nullif(trim(p_trade_name), ''), nullif(trim(p_gstin), ''), nullif(trim(p_pan), ''),
    nullif(trim(p_phone), ''), nullif(trim(p_email), ''), nullif(trim(p_address_line1), ''), nullif(trim(p_address_line2), ''),
    nullif(trim(p_city), ''), trim(p_state), trim(p_state_code), nullif(trim(p_postal_code), ''),
    coalesce(nullif(trim(p_invoice_prefix), ''), 'INV')
  ) returning id into v_org_id;

  insert into public.organization_members(organization_id, user_id, role, is_active)
  values (v_org_id, v_user_id, 'admin', true);

  insert into public.invoice_sequences(organization_id, financial_year, next_number)
  values (v_org_id, public.current_financial_year(), 1)
  on conflict do nothing;

  insert into public.audit_log(organization_id, user_id, action, entity_type, entity_id, details)
  values (v_org_id, v_user_id, 'organization_bootstrapped', 'organization', v_org_id,
          jsonb_build_object('legal_name', p_legal_name));

  return v_org_id;
end;
$$;

grant execute on function public.bootstrap_organization(text, text, text, text, text, text, text, text, text, text, text, text, text) to authenticated;
revoke execute on function public.bootstrap_organization(text, text, text, text, text, text, text, text, text, text, text, text, text) from anon;

-- ------------------------------------------------------------
-- Import helpers. These are intentionally admin-only and atomic.
-- The desktop application sends validated JSON rows after preview.
-- ------------------------------------------------------------

create or replace function public.import_customers(p_organization_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_count integer := 0;
  v_user uuid := auth.uid();
  v_id uuid;
  v_name text;
begin
  if not public.is_org_admin(p_organization_id) then raise exception 'administrator_required'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'rows_must_be_array'; end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_name := nullif(trim(v_row->>'name'), '');
    if v_name is null then raise exception 'customer_name_required'; end if;

    insert into public.customers(
      organization_id, name, gstin, pan, phone, email,
      billing_address_line1, billing_address_line2, billing_city, billing_state, billing_state_code, billing_postal_code,
      shipping_address_line1, shipping_address_line2, shipping_city, shipping_state, shipping_state_code, shipping_postal_code
    ) values (
      p_organization_id, v_name, nullif(trim(v_row->>'gstin'), ''), nullif(trim(v_row->>'pan'), ''),
      nullif(trim(v_row->>'phone'), ''), nullif(trim(v_row->>'email'), ''),
      nullif(trim(v_row->>'billing_address_line1'), ''), nullif(trim(v_row->>'billing_address_line2'), ''),
      nullif(trim(v_row->>'billing_city'), ''), nullif(trim(v_row->>'billing_state'), ''), nullif(trim(v_row->>'billing_state_code'), ''), nullif(trim(v_row->>'billing_postal_code'), ''),
      nullif(trim(v_row->>'shipping_address_line1'), ''), nullif(trim(v_row->>'shipping_address_line2'), ''),
      nullif(trim(v_row->>'shipping_city'), ''), nullif(trim(v_row->>'shipping_state'), ''), nullif(trim(v_row->>'shipping_state_code'), ''), nullif(trim(v_row->>'shipping_postal_code'), '')
    ) returning id into v_id;
    v_count := v_count + 1;
  end loop;

  insert into public.audit_log(organization_id, user_id, action, entity_type, details)
  values (p_organization_id, v_user, 'historical_import', 'customers', jsonb_build_object('count', v_count));
  return jsonb_build_object('imported', v_count);
end;
$$;

create or replace function public.import_materials(p_organization_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_count integer := 0;
  v_user uuid := auth.uid();
  v_unit_id uuid;
  v_category_id uuid;
  v_name text;
  v_unit text;
  v_category text;
  v_qty numeric;
  v_price numeric;
  v_gst numeric;
begin
  if not public.is_org_admin(p_organization_id) then raise exception 'administrator_required'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'rows_must_be_array'; end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_name := nullif(trim(v_row->>'name'), '');
    if v_name is null then raise exception 'material_name_required'; end if;
    v_unit := nullif(trim(v_row->>'unit'), '');
    v_category := nullif(trim(v_row->>'category'), '');
    v_qty := coalesce(nullif(v_row->>'quantity', '')::numeric, 0);
    v_price := coalesce(nullif(v_row->>'selling_price', '')::numeric, 0);
    v_gst := coalesce(nullif(v_row->>'gst_rate', '')::numeric, 0);
    if v_qty < 0 or v_price < 0 or v_gst < 0 or v_gst > 100 then raise exception 'invalid_material_numeric_value'; end if;

    if v_unit is not null then
      select id into v_unit_id from public.units where organization_id = p_organization_id and (lower(name)=lower(v_unit) or lower(short_code)=lower(v_unit)) limit 1;
      if v_unit_id is null then
        insert into public.units(organization_id, name, short_code) values (p_organization_id, v_unit, lower(regexp_replace(v_unit, '[^a-zA-Z0-9]+', '', 'g')))
        returning id into v_unit_id;
      end if;
    end if;

    if v_category is not null then
      insert into public.material_categories(organization_id, name) values (p_organization_id, v_category)
      on conflict (organization_id, name) do update set name = excluded.name
      returning id into v_category_id;
    end if;

    insert into public.materials(organization_id, unit_id, category_id, name, hsn_sac_code, gst_rate, selling_price_paise, current_quantity)
    values (p_organization_id, v_unit_id, v_category_id, v_name, nullif(trim(v_row->>'hsn_sac_code'), ''), v_gst, round(v_price * 100), v_qty);
    v_count := v_count + 1;
  end loop;

  insert into public.audit_log(organization_id, user_id, action, entity_type, details)
  values (p_organization_id, v_user, 'historical_import', 'materials', jsonb_build_object('count', v_count));
  return jsonb_build_object('imported', v_count);
end;
$$;

create or replace function public.import_stock_movements(p_organization_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_count integer := 0;
  v_user uuid := auth.uid();
  v_material uuid;
  v_name text;
  v_type text;
  v_qty numeric;
  v_created timestamptz;
  v_enum public.stock_movement_type;
begin
  if not public.is_org_admin(p_organization_id) then raise exception 'administrator_required'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'rows_must_be_array'; end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_name := nullif(trim(v_row->>'material'), '');
    v_type := lower(trim(v_row->>'movement_type'));
    v_qty := nullif(v_row->>'quantity', '')::numeric;
    if v_name is null or v_qty is null or v_qty <= 0 then raise exception 'invalid_stock_row'; end if;
    select id into v_material from public.materials where organization_id = p_organization_id and lower(name)=lower(v_name) limit 1;
    if v_material is null then raise exception 'material_not_found_for_stock_import: %', v_name; end if;

    v_enum := case v_type
      when 'opening' then 'opening'::public.stock_movement_type
      when 'purchase' then 'purchase'::public.stock_movement_type
      when 'sale' then 'sale'::public.stock_movement_type
      when 'adjustment_in' then 'adjustment_in'::public.stock_movement_type
      when 'adjustment_out' then 'adjustment_out'::public.stock_movement_type
      when 'return_in' then 'return_in'::public.stock_movement_type
      when 'return_out' then 'return_out'::public.stock_movement_type
      else null end;
    if v_enum is null then raise exception 'invalid_stock_movement_type: %', v_type; end if;

    v_created := coalesce(nullif(v_row->>'movement_date','')::timestamptz, now());
    insert into public.stock_movements(organization_id, material_id, movement_type, quantity, notes, created_by, created_at)
    values (p_organization_id, v_material, v_enum, v_qty, nullif(trim(v_row->>'notes'), ''), v_user, v_created);
    update public.materials
      set current_quantity = current_quantity + case when v_enum in ('opening','purchase','adjustment_in','return_in') then v_qty else -v_qty end
      where id = v_material;
    v_count := v_count + 1;
  end loop;

  if exists (select 1 from public.materials where organization_id=p_organization_id and current_quantity < 0) then
    raise exception 'stock_import_would_create_negative_stock';
  end if;

  insert into public.audit_log(organization_id, user_id, action, entity_type, details)
  values (p_organization_id, v_user, 'historical_import', 'stock_movements', jsonb_build_object('count', v_count));
  return jsonb_build_object('imported', v_count);
end;
$$;

create or replace function public.import_historical_invoices(p_organization_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_invoice_id uuid;
  v_customer_id uuid;
  v_material_id uuid;
  v_invoice_number text;
  v_customer_name text;
  v_material_name text;
  v_qty numeric;
  v_unit_price numeric;
  v_taxable bigint;
  v_gst numeric;
  v_total bigint;
  v_count integer := 0;
  v_user uuid := auth.uid();
begin
  if not public.is_org_admin(p_organization_id) then raise exception 'administrator_required'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'rows_must_be_array'; end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_invoice_number := nullif(trim(v_row->>'invoice_number'), '');
    v_customer_name := nullif(trim(v_row->>'customer'), '');
    v_material_name := nullif(trim(v_row->>'material'), '');
    v_qty := nullif(v_row->>'quantity', '')::numeric;
    v_unit_price := coalesce(nullif(v_row->>'unit_price', '')::numeric, 0);
    v_gst := coalesce(nullif(v_row->>'gst_rate', '')::numeric, 0);
    if v_invoice_number is null or v_customer_name is null or v_material_name is null or v_qty is null or v_qty <= 0 then raise exception 'invalid_invoice_import_row'; end if;

    select id into v_customer_id from public.customers where organization_id=p_organization_id and lower(name)=lower(v_customer_name) limit 1;
    if v_customer_id is null then raise exception 'customer_not_found_for_invoice_import: %', v_customer_name; end if;
    select id into v_material_id from public.materials where organization_id=p_organization_id and lower(name)=lower(v_material_name) limit 1;
    if v_material_id is null then raise exception 'material_not_found_for_invoice_import: %', v_material_name; end if;

    v_taxable := round(v_qty * v_unit_price * 100);
    v_total := round(v_taxable * (1 + v_gst / 100));

    select id into v_invoice_id from public.invoices where organization_id=p_organization_id and invoice_number=v_invoice_number limit 1;
    if v_invoice_id is null then
      insert into public.invoices(organization_id, customer_id, invoice_number, invoice_date, status, gst_enabled, subtotal_paise, taxable_value_paise, total_gst_paise, grand_total_paise, created_by)
      values (p_organization_id, v_customer_id, v_invoice_number, coalesce(nullif(v_row->>'invoice_date','')::date,current_date), 'issued', v_gst > 0, v_taxable, v_taxable, v_total-v_taxable, v_total, v_user)
      returning id into v_invoice_id;
      v_count := v_count + 1;
    end if;

    insert into public.invoice_items(invoice_id, material_id, description, hsn_sac_code, unit_name, quantity, unit_price_paise, taxable_value_paise, gst_rate, igst_amount_paise, line_total_paise)
    select v_invoice_id, m.id, m.name, m.hsn_sac_code, u.name, v_qty, round(v_unit_price*100), v_taxable, v_gst, v_total-v_taxable, v_total
    from public.materials m left join public.units u on u.id=m.unit_id where m.id=v_material_id;
  end loop;

  insert into public.audit_log(organization_id, user_id, action, entity_type, details)
  values (p_organization_id, v_user, 'historical_import', 'invoices', jsonb_build_object('count', v_count));
  return jsonb_build_object('imported_invoices', v_count);
end;
$$;

create or replace function public.import_historical_payments(p_organization_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_invoice uuid;
  v_number text;
  v_amount numeric;
  v_count integer := 0;
  v_user uuid := auth.uid();
  v_method public.payment_method;
begin
  if not public.is_org_admin(p_organization_id) then raise exception 'administrator_required'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'rows_must_be_array'; end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_number := nullif(trim(v_row->>'invoice_number'), '');
    v_amount := nullif(v_row->>'amount', '')::numeric;
    if v_number is null or v_amount is null or v_amount <= 0 then raise exception 'invalid_payment_import_row'; end if;
    select id into v_invoice from public.invoices where organization_id=p_organization_id and invoice_number=v_number limit 1;
    if v_invoice is null then raise exception 'invoice_not_found_for_payment_import: %', v_number; end if;
    v_method := case lower(coalesce(trim(v_row->>'payment_method'),'other'))
      when 'cash' then 'cash'::public.payment_method
      when 'upi' then 'upi'::public.payment_method
      when 'bank_transfer' then 'bank_transfer'::public.payment_method
      when 'bank transfer' then 'bank_transfer'::public.payment_method
      when 'cheque' then 'cheque'::public.payment_method
      when 'card' then 'card'::public.payment_method
      else 'other'::public.payment_method end;
    insert into public.payments(organization_id, invoice_id, amount_paise, payment_date, payment_method, reference_number, notes, created_by)
    values (p_organization_id, v_invoice, round(v_amount*100), coalesce(nullif(v_row->>'payment_date','')::date,current_date), v_method, nullif(trim(v_row->>'reference_number'),''), nullif(trim(v_row->>'notes'),''), v_user);
    v_count := v_count + 1;
  end loop;

  insert into public.audit_log(organization_id, user_id, action, entity_type, details)
  values (p_organization_id, v_user, 'historical_import', 'payments', jsonb_build_object('count', v_count));
  return jsonb_build_object('imported', v_count);
end;
$$;

grant execute on function public.import_customers(uuid, jsonb) to authenticated;
grant execute on function public.import_materials(uuid, jsonb) to authenticated;
grant execute on function public.import_stock_movements(uuid, jsonb) to authenticated;
grant execute on function public.import_historical_invoices(uuid, jsonb) to authenticated;
grant execute on function public.import_historical_payments(uuid, jsonb) to authenticated;
revoke execute on function public.import_customers(uuid, jsonb) from anon;
revoke execute on function public.import_materials(uuid, jsonb) from anon;
revoke execute on function public.import_stock_movements(uuid, jsonb) from anon;
revoke execute on function public.import_historical_invoices(uuid, jsonb) from anon;
revoke execute on function public.import_historical_payments(uuid, jsonb) from anon;

insert into public.app_schema_version(version) values (11) on conflict (version) do nothing;

commit;
