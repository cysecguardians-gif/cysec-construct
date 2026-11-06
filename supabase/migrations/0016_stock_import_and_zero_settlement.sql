-- CySec Construct
-- Serialize historical stock imports per material and prevent negative balances.
-- Also close zero-payable, zero-recovery contractor settlements on admin approval.

begin;

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
  v_current numeric;
  v_next numeric;
  v_delta numeric;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'administrator_required';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'rows_must_be_array';
  end if;

  -- Lock every referenced material in a deterministic order before applying
  -- any movement. Concurrent imports touching the same materials serialize.
  for v_material in
    select m.id
    from public.materials m
    where m.organization_id = p_organization_id
      and lower(m.name) in (
        select lower(trim(x.value->>'material'))
        from jsonb_array_elements(p_rows) as x(value)
      )
    order by m.id
    for update
  loop
    null;
  end loop;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_name := nullif(trim(v_row->>'material'), '');
    v_type := lower(trim(v_row->>'movement_type'));
    v_qty := nullif(v_row->>'quantity', '')::numeric;

    if v_name is null or v_qty is null or v_qty <= 0
       or v_qty::text in ('NaN', 'Infinity', '-Infinity') then
      raise exception 'invalid_stock_row';
    end if;

    select id, current_quantity
      into v_material, v_current
    from public.materials
    where organization_id = p_organization_id
      and lower(name) = lower(v_name)
    order by id
    limit 1
    for update;

    if v_material is null then
      raise exception 'material_not_found_for_stock_import: %', v_name;
    end if;

    v_enum := case v_type
      when 'opening' then 'opening'::public.stock_movement_type
      when 'purchase' then 'purchase'::public.stock_movement_type
      when 'sale' then 'sale'::public.stock_movement_type
      when 'adjustment_in' then 'adjustment_in'::public.stock_movement_type
      when 'adjustment_out' then 'adjustment_out'::public.stock_movement_type
      when 'return_in' then 'return_in'::public.stock_movement_type
      when 'return_out' then 'return_out'::public.stock_movement_type
      else null
    end;
    if v_enum is null then
      raise exception 'invalid_stock_movement_type: %', v_type;
    end if;

    v_delta := case
      when v_enum in ('opening','purchase','adjustment_in','return_in') then v_qty
      else -v_qty
    end;
    v_next := v_current + v_delta;
    if v_next < 0 then
      raise exception 'stock_import_would_create_negative_stock: %', v_name;
    end if;

    v_created := coalesce(nullif(v_row->>'movement_date','')::timestamptz, now());

    insert into public.stock_movements(
      organization_id, material_id, movement_type, quantity, notes, created_by, created_at
    ) values (
      p_organization_id, v_material, v_enum, v_qty,
      nullif(trim(v_row->>'notes'), ''), v_user, v_created
    );

    update public.materials
      set current_quantity = v_next
      where id = v_material
        and organization_id = p_organization_id;

    v_count := v_count + 1;
  end loop;

  insert into public.audit_log(organization_id, user_id, action, entity_type, details)
  values (p_organization_id, v_user, 'historical_import', 'stock_movements',
    jsonb_build_object('count', v_count));

  return jsonb_build_object('imported', v_count);
end;
$$;

grant execute on function public.import_stock_movements(uuid, jsonb) to authenticated;
revoke execute on function public.import_stock_movements(uuid, jsonb) from anon;

-- A zero payable settlement with no recovery is complete on approval:
-- no fictitious zero-value payment row is needed.
create or replace function public.approve_contractor_settlement(
  p_organization_id uuid,
  p_settlement_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_work_order_id uuid;
  v_final_payable bigint;
  v_recovery bigint;
  v_new_status text;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'administrator_required_to_approve_settlement';
  end if;

  select work_order_id, final_payable_paise, contractor_recovery_paise
    into v_work_order_id, v_final_payable, v_recovery
  from public.contractor_settlements
  where id = p_settlement_id
    and organization_id = p_organization_id
    and status = 'draft'
  for update;

  if not found then
    raise exception 'draft_settlement_not_found';
  end if;

  v_new_status := case
    when v_final_payable = 0 and v_recovery = 0 then 'paid'
    else 'approved'
  end;

  update public.contractor_settlements
  set status = v_new_status,
      approved_by = auth.uid()
  where id = p_settlement_id
    and organization_id = p_organization_id;

  if v_new_status = 'paid' then
    update public.contractor_work_orders
    set status = 'settled'
    where id = v_work_order_id
      and organization_id = p_organization_id
      and status = 'under_closure';
  end if;

  insert into public.audit_log(
    organization_id, user_id, action, entity_type, entity_id, details
  ) values (
    p_organization_id, auth.uid(), 'contractor_settlement_approved',
    'contractor_settlement', p_settlement_id,
    jsonb_build_object(
      'status', v_new_status,
      'final_payable_paise', v_final_payable,
      'contractor_recovery_paise', v_recovery
    )
  );
end;
$$;

grant execute on function public.approve_contractor_settlement(uuid, uuid) to authenticated;
revoke execute on function public.approve_contractor_settlement(uuid, uuid) from anon;

insert into public.app_schema_version(version) values (16)
on conflict (version) do nothing;

commit;
