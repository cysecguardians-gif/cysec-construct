-- CySec Construct
-- Validate historical invoice amounts before bigint conversion and round unit
-- prices to paise before calculating line taxable values.

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
  v_unit_price_paise bigint;
  v_taxable_numeric numeric;
  v_taxable bigint;
  v_gst numeric;
  v_total_numeric numeric;
  v_total bigint;
  v_invoice_date date;
  v_count integer := 0;
  v_user uuid := auth.uid();
  v_batch_customer_id uuid;
  v_batch_invoice_date date;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'administrator_required';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows_must_be_array';
  end if;
  if jsonb_array_length(p_rows) = 0 then
    raise exception 'invoice_import_rows_required';
  end if;

  create temp table if not exists cysec_import_invoice_batch_v18 (
    invoice_id uuid primary key,
    customer_id uuid not null,
    invoice_date date not null
  ) on commit drop;
  truncate cysec_import_invoice_batch_v18;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception 'invalid_invoice_import_row';
    end if;

    v_invoice_number := nullif(trim(v_row->>'invoice_number'), '');
    v_customer_name := nullif(trim(v_row->>'customer'), '');
    v_material_name := nullif(trim(v_row->>'material'), '');
    v_qty := nullif(trim(v_row->>'quantity'), '')::numeric;
    v_unit_price := coalesce(nullif(trim(v_row->>'unit_price'), '')::numeric, 0);
    v_gst := coalesce(nullif(trim(v_row->>'gst_rate'), '')::numeric, 0);
    v_invoice_date := coalesce(nullif(trim(v_row->>'invoice_date'), '')::date, current_date);

    if v_invoice_number is null or v_customer_name is null
       or v_material_name is null or v_qty is null
       or v_qty::text in ('NaN', 'Infinity', '-Infinity')
       or v_qty <= 0 then
      raise exception 'invalid_invoice_import_row';
    end if;

    if v_unit_price::text in ('NaN', 'Infinity', '-Infinity')
       or v_gst::text in ('NaN', 'Infinity', '-Infinity')
       or v_unit_price < 0 or v_gst < 0 or v_gst > 100 then
      raise exception 'invalid_invoice_numeric_value';
    end if;

    v_unit_price_paise := round(v_unit_price * 100);
    if v_unit_price_paise < 0 then
      raise exception 'invalid_invoice_numeric_value';
    end if;

    -- Use the rounded paise price as the basis for the line total. This keeps
    -- the saved unit price and taxable amount arithmetically consistent.
    v_taxable_numeric := round(v_qty * v_unit_price_paise);
    if v_taxable_numeric < 0 or v_taxable_numeric > 9223372036854775807 then
      raise exception 'invoice_line_amount_exceeds_supported_range';
    end if;
    v_taxable := v_taxable_numeric::bigint;

    v_total_numeric := round(v_taxable * (1 + v_gst / 100));
    if v_total_numeric < v_taxable or v_total_numeric > 9223372036854775807 then
      raise exception 'invoice_line_total_exceeds_supported_range';
    end if;
    v_total := v_total_numeric::bigint;

    select id into v_customer_id
    from public.customers
    where organization_id = p_organization_id
      and lower(name) = lower(v_customer_name)
    order by id
    limit 1;
    if v_customer_id is null then
      raise exception 'customer_not_found_for_invoice_import: %', v_customer_name;
    end if;

    select id into v_material_id
    from public.materials
    where organization_id = p_organization_id
      and lower(name) = lower(v_material_name)
    order by id
    limit 1;
    if v_material_id is null then
      raise exception 'material_not_found_for_invoice_import: %', v_material_name;
    end if;

    select id into v_invoice_id
    from public.invoices
    where organization_id = p_organization_id
      and invoice_number = v_invoice_number
    limit 1;

    if v_invoice_id is null then
      insert into public.invoices(
        organization_id, customer_id, invoice_number, invoice_date, status,
        gst_enabled, discount_enabled, subtotal_paise, taxable_value_paise,
        total_gst_paise, grand_total_paise, created_by
      ) values (
        p_organization_id, v_customer_id, v_invoice_number, v_invoice_date,
        'issued', v_gst > 0, false, 0, 0, 0, 0, v_user
      )
      returning id into v_invoice_id;

      insert into cysec_import_invoice_batch_v18(invoice_id, customer_id, invoice_date)
      values (v_invoice_id, v_customer_id, v_invoice_date);
      v_count := v_count + 1;
    else
      select customer_id, invoice_date
        into v_batch_customer_id, v_batch_invoice_date
      from cysec_import_invoice_batch_v18
      where invoice_id = v_invoice_id;

      if not found then
        raise exception 'invoice_already_exists: %', v_invoice_number;
      end if;
      if v_batch_customer_id <> v_customer_id
         or v_batch_invoice_date <> v_invoice_date then
        raise exception 'invoice_import_header_mismatch: %', v_invoice_number;
      end if;
    end if;

    insert into public.invoice_items(
      invoice_id, material_id, description, hsn_sac_code, unit_name,
      quantity, unit_price_paise, taxable_value_paise, gst_rate,
      igst_amount_paise, line_total_paise
    )
    select
      v_invoice_id, m.id, m.name, m.hsn_sac_code, u.name,
      v_qty, v_unit_price_paise, v_taxable, v_gst,
      v_total - v_taxable, v_total
    from public.materials m
    left join public.units u on u.id = m.unit_id
    where m.id = v_material_id;
  end loop;

  update public.invoices i
  set subtotal_paise = x.taxable_value_paise,
      taxable_value_paise = x.taxable_value_paise,
      total_gst_paise = x.total_gst_paise,
      grand_total_paise = x.grand_total_paise,
      gst_enabled = x.total_gst_paise > 0,
      cgst_amount_paise = 0,
      sgst_amount_paise = 0,
      igst_amount_paise = x.total_gst_paise
  from (
    select
      invoice_id,
      sum(taxable_value_paise)::bigint as taxable_value_paise,
      sum(igst_amount_paise)::bigint as total_gst_paise,
      sum(line_total_paise)::bigint as grand_total_paise
    from public.invoice_items
    where invoice_id in (select invoice_id from cysec_import_invoice_batch_v18)
    group by invoice_id
  ) x
  where i.id = x.invoice_id;

  insert into public.audit_log(organization_id, user_id, action, entity_type, details)
  values (
    p_organization_id, v_user, 'historical_import', 'invoices',
    jsonb_build_object('count', v_count)
  );

  return jsonb_build_object('imported_invoices', v_count);
end;
$$;

grant execute on function public.import_historical_invoices(uuid, jsonb) to authenticated;
revoke execute on function public.import_historical_invoices(uuid, jsonb) from anon;

insert into public.app_schema_version(version) values (18)
on conflict (version) do nothing;

commit;
