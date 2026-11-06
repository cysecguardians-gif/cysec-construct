-- CySec Construct
-- Make material master imports idempotent and preserve stock balances.
-- Re-importing a workbook must not fail on existing material or unit records.

begin;

create or replace function public.import_materials(p_organization_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_inserted integer := 0;
  v_updated integer := 0;
  v_skipped integer := 0;
  v_user uuid := auth.uid();
  v_unit_id uuid;
  v_category_id uuid;
  v_existing_material_id uuid;
  v_name text;
  v_unit text;
  v_unit_code text;
  v_category text;
  v_price numeric;
  v_gst numeric;
  v_hsn text;
  v_rows_affected integer;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'administrator_required';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows_must_be_array';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_name := nullif(trim(v_row->>'name'), '');
    if v_name is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_unit := nullif(trim(v_row->>'unit'), '');
    v_category := nullif(trim(v_row->>'category'), '');
    v_price := coalesce(nullif(v_row->>'selling_price', '')::numeric, 0);
    v_gst := coalesce(nullif(v_row->>'gst_rate', '')::numeric, 0);
    v_hsn := nullif(trim(v_row->>'hsn_sac_code'), '');

    if v_price < 0 or v_gst < 0 or v_gst > 100 then
      raise exception 'invalid_material_numeric_value: %', v_name;
    end if;

    v_unit_id := null;
    if v_unit is not null then
      select id into v_unit_id
      from public.units
      where organization_id = p_organization_id
        and (lower(name) = lower(v_unit) or lower(short_code) = lower(v_unit))
      order by case when lower(name) = lower(v_unit) then 0 else 1 end
      limit 1;

      if v_unit_id is null then
        v_unit_code := lower(regexp_replace(v_unit, '[^a-zA-Z0-9]+', '', 'g'));
        if v_unit_code = '' then
          raise exception 'invalid_material_unit: %', v_unit;
        end if;

        insert into public.units(organization_id, name, short_code)
        values (p_organization_id, v_unit, v_unit_code)
        on conflict (organization_id, short_code)
        do update set name = public.units.name
        returning id into v_unit_id;
      end if;
    end if;

    v_category_id := null;
    if v_category is not null then
      insert into public.material_categories(organization_id, name)
      values (p_organization_id, v_category)
      on conflict (organization_id, name)
      do update set name = excluded.name
      returning id into v_category_id;
    end if;

    -- Match case-insensitively first so capitalization differences don't
    -- create a second master record. Stock quantity is intentionally untouched.
    select id into v_existing_material_id
    from public.materials
    where organization_id = p_organization_id
      and lower(name) = lower(v_name)
    order by created_at, id
    limit 1;

    if v_existing_material_id is not null then
      update public.materials
      set unit_id = coalesce(v_unit_id, unit_id),
          category_id = coalesce(v_category_id, category_id),
          hsn_sac_code = coalesce(v_hsn, hsn_sac_code),
          gst_rate = case when v_row ? 'gst_rate' then v_gst else gst_rate end,
          selling_price_paise = case when v_row ? 'selling_price'
            then round(v_price * 100)::bigint else selling_price_paise end
      where id = v_existing_material_id;
      v_updated := v_updated + 1;
    else
      insert into public.materials(
        organization_id, unit_id, category_id, name, hsn_sac_code,
        gst_rate, selling_price_paise
      )
      values (
        p_organization_id, v_unit_id, v_category_id, v_name, v_hsn,
        v_gst, round(v_price * 100)::bigint
      )
      on conflict (organization_id, name)
      do update set
        unit_id = coalesce(excluded.unit_id, public.materials.unit_id),
        category_id = coalesce(excluded.category_id, public.materials.category_id),
        hsn_sac_code = coalesce(excluded.hsn_sac_code, public.materials.hsn_sac_code),
        gst_rate = case when v_row ? 'gst_rate' then excluded.gst_rate else public.materials.gst_rate end,
        selling_price_paise = case when v_row ? 'selling_price' then excluded.selling_price_paise else public.materials.selling_price_paise end
      returning id into v_existing_material_id;
      get diagnostics v_rows_affected = row_count;
      if v_rows_affected > 0 then
        v_inserted := v_inserted + 1;
      end if;
    end if;
  end loop;

  insert into public.audit_log(organization_id, user_id, action, entity_type, details)
  values (
    p_organization_id, v_user, 'historical_import', 'materials',
    jsonb_build_object(
      'inserted', v_inserted,
      'updated', v_updated,
      'skipped', v_skipped,
      'stock_quantity_changed', false
    )
  );

  return jsonb_build_object(
    'inserted', v_inserted,
    'updated', v_updated,
    'skipped', v_skipped,
    'stock_quantity_changed', false
  );
end;
$$;

grant execute on function public.import_materials(uuid, jsonb) to authenticated;
revoke execute on function public.import_materials(uuid, jsonb) from anon;

insert into public.app_schema_version(version)
values (27)
on conflict (version) do nothing;

commit;
