-- Material Management System
-- Correct historical invoice aggregation and payment safety.
-- Apply after 0011_first_admin_lock_and_imports.sql.

begin;

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

  create temp table if not exists mms_import_invoice_ids(invoice_id uuid primary key) on commit drop;
  truncate mms_import_invoice_ids;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_invoice_number := nullif(trim(v_row->>'invoice_number'), '');
    v_customer_name := nullif(trim(v_row->>'customer'), '');
    v_material_name := nullif(trim(v_row->>'material'), '');
    v_qty := nullif(v_row->>'quantity', '')::numeric;
    v_unit_price := coalesce(nullif(v_row->>'unit_price', '')::numeric, 0);
    v_gst := coalesce(nullif(v_row->>'gst_rate', '')::numeric, 0);
    if v_invoice_number is null or v_customer_name is null or v_material_name is null or v_qty is null or v_qty <= 0 then raise exception 'invalid_invoice_import_row'; end if;
    if v_unit_price < 0 or v_gst < 0 or v_gst > 100 then raise exception 'invalid_invoice_numeric_value'; end if;

    select id into v_customer_id from public.customers where organization_id=p_organization_id and lower(name)=lower(v_customer_name) limit 1;
    if v_customer_id is null then raise exception 'customer_not_found_for_invoice_import: %', v_customer_name; end if;
    select id into v_material_id from public.materials where organization_id=p_organization_id and lower(name)=lower(v_material_name) limit 1;
    if v_material_id is null then raise exception 'material_not_found_for_invoice_import: %', v_material_name; end if;

    select id into v_invoice_id from public.invoices where organization_id=p_organization_id and invoice_number=v_invoice_number limit 1;
    if v_invoice_id is null then
      insert into public.invoices(organization_id, customer_id, invoice_number, invoice_date, status, gst_enabled, discount_enabled, subtotal_paise, taxable_value_paise, total_gst_paise, grand_total_paise, created_by)
      values (p_organization_id, v_customer_id, v_invoice_number, coalesce(nullif(v_row->>'invoice_date','')::date,current_date), 'issued', v_gst > 0, false, 0, 0, 0, 0, v_user)
      returning id into v_invoice_id;
      insert into mms_import_invoice_ids values (v_invoice_id);
      v_count := v_count + 1;
    elsif not exists (select 1 from mms_import_invoice_ids where invoice_id=v_invoice_id) then
      raise exception 'invoice_already_exists: %', v_invoice_number;
    end if;

    v_taxable := round(v_qty * v_unit_price * 100);
    v_total := round(v_taxable * (1 + v_gst / 100));

    insert into public.invoice_items(invoice_id, material_id, description, hsn_sac_code, unit_name, quantity, unit_price_paise, taxable_value_paise, gst_rate, igst_amount_paise, line_total_paise)
    select v_invoice_id, m.id, m.name, m.hsn_sac_code, u.name, v_qty, round(v_unit_price*100), v_taxable, v_gst, v_total-v_taxable, v_total
    from public.materials m left join public.units u on u.id=m.unit_id where m.id=v_material_id;
  end loop;

  update public.invoices i
  set subtotal_paise = x.subtotal_paise,
      taxable_value_paise = x.taxable_value_paise,
      total_gst_paise = x.total_gst_paise,
      grand_total_paise = x.grand_total_paise,
      gst_enabled = x.total_gst_paise > 0,
      cgst_amount_paise = 0,
      sgst_amount_paise = 0,
      igst_amount_paise = x.total_gst_paise
  from (
    select invoice_id, sum(line_total_paise - igst_amount_paise) as subtotal_paise, sum(taxable_value_paise) as taxable_value_paise, sum(igst_amount_paise) as total_gst_paise, sum(line_total_paise) as grand_total_paise
    from public.invoice_items where invoice_id in (select invoice_id from mms_import_invoice_ids) group by invoice_id
  ) x
  where i.id=x.invoice_id;

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
  v_amount bigint;
  v_count integer := 0;
  v_user uuid := auth.uid();
  v_method public.payment_method;
  v_existing bigint;
  v_total bigint;
begin
  if not public.is_org_admin(p_organization_id) then raise exception 'administrator_required'; end if;
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'rows_must_be_array'; end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_number := nullif(trim(v_row->>'invoice_number'), '');
    v_amount := round(nullif(v_row->>'amount', '')::numeric * 100);
    if v_number is null or v_amount is null or v_amount <= 0 then raise exception 'invalid_payment_import_row'; end if;
    select id, grand_total_paise into v_invoice, v_total from public.invoices where organization_id=p_organization_id and invoice_number=v_number for update;
    if v_invoice is null then raise exception 'invoice_not_found_for_payment_import: %', v_number; end if;
    select coalesce(sum(amount_paise),0) into v_existing from public.payments where invoice_id=v_invoice;
    if v_existing + v_amount > v_total then raise exception 'payment_import_exceeds_invoice_balance: %', v_number; end if;
    v_method := case lower(coalesce(trim(v_row->>'payment_method'),'other'))
      when 'cash' then 'cash'::public.payment_method when 'upi' then 'upi'::public.payment_method when 'bank_transfer' then 'bank_transfer'::public.payment_method when 'bank transfer' then 'bank_transfer'::public.payment_method when 'cheque' then 'cheque'::public.payment_method when 'card' then 'card'::public.payment_method else 'other'::public.payment_method end;
    insert into public.payments(organization_id, invoice_id, amount_paise, payment_date, payment_method, reference_number, notes, created_by)
    values (p_organization_id, v_invoice, v_amount, coalesce(nullif(v_row->>'payment_date','')::date,current_date), v_method, nullif(trim(v_row->>'reference_number'),''), nullif(trim(v_row->>'notes'),''), v_user);
    v_count := v_count + 1;
  end loop;

  insert into public.audit_log(organization_id, user_id, action, entity_type, details)
  values (p_organization_id, v_user, 'historical_import', 'payments', jsonb_build_object('count', v_count));
  return jsonb_build_object('imported', v_count);
end;
$$;

insert into public.app_schema_version(version) values (12) on conflict (version) do nothing;

commit;
