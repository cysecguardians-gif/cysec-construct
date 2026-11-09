-- Align contractor material issue inserts with the live material_issue_items schema.
-- The live snapshot column is description_snapshot, not material_name_snapshot.
-- Preserve contract-level POs with a NULL project_id and snapshot contractor
-- and project IDs from the selected active PO.

begin;

-- Normalize the fresh-install snapshot column to the name used by the
-- corrected contractor issue RPC below. Existing customer databases that
-- already have description_snapshot are left unchanged.
do $migration$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'material_issue_items'
      and column_name = 'material_name_snapshot'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'material_issue_items'
      and column_name = 'description_snapshot'
  ) then
    alter table public.material_issue_items
      rename column material_name_snapshot to description_snapshot;
  end if;
end
$migration$;

alter table public.material_issues
  alter column project_id drop not null;

create or replace function public.issue_contractor_materials(
  p_organization_id uuid,
  p_work_order_id uuid,
  p_issue_number text,
  p_issue_date date,
  p_items jsonb,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_issue uuid;
  v_item jsonb;
  v_material uuid;
  v_qty numeric;
  v_rate bigint;
  v_cost bigint;
  v_name text;
  v_unit text;
  v_stock numeric;
  v_contractor uuid;
  v_project uuid;
begin
  if not public.is_org_member(p_organization_id) then
    raise exception 'organization_membership_required';
  end if;

  select contractor_id, project_id
    into v_contractor, v_project
  from public.contractor_work_orders
  where id = p_work_order_id
    and organization_id = p_organization_id
    and status = 'active'
  for share;

  if not found then
    raise exception 'active_work_order_not_found';
  end if;

  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'issue_items_required';
  end if;

  insert into public.material_issues(
    organization_id, work_order_id, contractor_id, project_id,
    issue_number, issue_date, notes, issued_by
  )
  values (
    p_organization_id, p_work_order_id, v_contractor, v_project,
    trim(p_issue_number), coalesce(p_issue_date, current_date),
    p_notes, auth.uid()
  )
  returning id into v_issue;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_material := (v_item->>'material_id')::uuid;
    v_qty := (v_item->>'quantity')::numeric;
    v_rate := (v_item->>'contractor_unit_rate_paise')::bigint;

    if v_qty is null or v_qty <= 0 or v_rate is null or v_rate < 0 then
      raise exception 'invalid_issue_item';
    end if;

    select m.name, coalesce(u.name, u.short_code), m.current_quantity
      into v_name, v_unit, v_stock
    from public.materials m
    left join public.units u on u.id = m.unit_id
    where m.id = v_material
      and m.organization_id = p_organization_id
      and m.is_active
    for update of m;

    if not found then
      raise exception 'active_material_not_found';
    end if;

    if v_stock < v_qty then
      raise exception 'insufficient_stock_for_material: %', v_name;
    end if;

    select pi.unit_cost_paise
      into v_cost
    from public.material_purchase_items pi
    join public.material_purchases mp
      on mp.id = pi.purchase_id
     and mp.organization_id = pi.organization_id
    where pi.organization_id = p_organization_id
      and pi.material_id = v_material
      and mp.status = 'received'
    order by mp.purchase_date desc, mp.created_at desc
    limit 1;

    v_cost := coalesce(v_cost, 0);

    insert into public.contractor_material_rates(
      organization_id, contractor_id, material_id, unit_rate_paise
    )
    values (
      p_organization_id, v_contractor, v_material, v_rate
    )
    on conflict (organization_id, contractor_id, material_id)
    do update set
      unit_rate_paise = excluded.unit_rate_paise,
      updated_at = now();

    insert into public.material_issue_items(
      organization_id, issue_id, material_id, description_snapshot,
      unit_name_snapshot, quantity_issued, purchase_unit_cost_paise,
      contractor_unit_rate_paise
    )
    values (
      p_organization_id, v_issue, v_material, v_name, v_unit,
      v_qty, v_cost, v_rate
    );

    update public.materials
    set current_quantity = current_quantity - v_qty,
        updated_at = now()
    where id = v_material
      and organization_id = p_organization_id;

    insert into public.stock_movements(
      organization_id, material_id, movement_type, quantity,
      reference_type, reference_id, notes, created_by
    )
    values (
      p_organization_id, v_material, 'sale', v_qty,
      'material_issue', v_issue,
      'Issued against contractor PO ' || p_work_order_id::text,
      auth.uid()
    );
  end loop;

  insert into public.audit_log(
    organization_id, user_id, action, entity_type, entity_id, details
  )
  values (
    p_organization_id, auth.uid(), 'contractor_materials_issued',
    'material_issue', v_issue,
    jsonb_build_object(
      'work_order_id', p_work_order_id,
      'contractor_id', v_contractor,
      'project_id', v_project
    )
  );

  return v_issue;
end;
$function$;

commit;
