-- Consolidate contractor material returns into the work-order RPC used by
-- the current UI. Populate required return header references from the source
-- issue and allow contract-level returns where project_id is NULL.

begin;

-- Bring older/fresh schemas to the canonical contractor return shape before
-- defining the RPC. All additions are nullable or safely defaulted so existing
-- customer records remain intact.
alter table public.material_issues
  add column if not exists contractor_id uuid;

alter table public.material_returns
  add column if not exists issue_id uuid,
  add column if not exists contractor_id uuid,
  add column if not exists project_id uuid;

alter table public.material_return_items
  add column if not exists condition text not null default 'usable',
  add column if not exists notes text;

alter table public.contractor_advances
  add column if not exists contractor_id uuid;

alter table public.material_returns
  alter column project_id drop not null;

drop function if exists public.return_contractor_materials(
  uuid, uuid, text, date, jsonb, text
);

drop function if exists public.return_contractor_materials(
  uuid, uuid, jsonb, date, text, text
);

create function public.return_contractor_materials(
  p_organization_id uuid,
  p_work_order_id uuid,
  p_return_number text,
  p_return_date date,
  p_items jsonb,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_return uuid;
  v_item jsonb;
  v_issue_id uuid;
  v_contractor_id uuid;
  v_project_id uuid;
  v_issue_status text;
  v_issue_item uuid;
  v_qty numeric;
  v_issued numeric;
  v_already numeric;
  v_used numeric;
  v_material uuid;
  v_condition text;
begin
  if not public.is_org_member(p_organization_id) then
    raise exception 'organization_membership_required';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'return_items_required';
  end if;

  -- Lock the PO and source issue so returns cannot race with closure or
  -- another return against the same issue.
  perform 1
  from public.contractor_work_orders
  where id = p_work_order_id
    and organization_id = p_organization_id
    and status in ('active', 'work_completed')
  for update;

  if not found then
    raise exception 'work_order_not_open_for_material_returns';
  end if;

  select id, contractor_id, project_id, status
    into v_issue_id, v_contractor_id, v_project_id, v_issue_status
  from public.material_issues
  where work_order_id = p_work_order_id
    and organization_id = p_organization_id
    and status <> 'cancelled'
  order by created_at desc
  limit 1
  for update;

  -- The selected issue is resolved per item below. A return may contain
  -- lines from only one source issue, as required by material_returns.issue_id.
  if not found then
    raise exception 'material_issue_not_found_for_work_order';
  end if;

  -- Derive the exact source issue from the first requested line, then ensure
  -- every line in this return belongs to that same issue and selected PO.
  v_issue_item := (p_items->0->>'issue_item_id')::uuid;

  select mi.id, mi.contractor_id, mi.project_id, mi.status
    into v_issue_id, v_contractor_id, v_project_id, v_issue_status
  from public.material_issue_items ii
  join public.material_issues mi
    on mi.id = ii.issue_id
   and mi.organization_id = ii.organization_id
  where ii.id = v_issue_item
    and ii.organization_id = p_organization_id
    and mi.work_order_id = p_work_order_id
    and mi.status <> 'cancelled'
  for update of mi;

  if not found then
    raise exception 'issue_item_not_found_for_work_order';
  end if;

  insert into public.material_returns(
    organization_id, issue_id, work_order_id, contractor_id, project_id,
    return_number, return_date, notes, received_by
  )
  values (
    p_organization_id, v_issue_id, p_work_order_id, v_contractor_id, v_project_id,
    nullif(btrim(p_return_number), ''), coalesce(p_return_date, current_date),
    p_notes, auth.uid()
  )
  returning id into v_return;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_issue_item := (v_item->>'issue_item_id')::uuid;
    v_qty := (v_item->>'quantity_returned')::numeric;
    v_condition := coalesce(nullif(v_item->>'condition', ''), 'usable');

    if v_qty is null or v_qty <= 0
       or v_condition not in ('usable', 'damaged', 'scrap') then
      raise exception 'invalid_material_return_item';
    end if;

    select ii.quantity_issued, ii.material_id
      into v_issued, v_material
    from public.material_issue_items ii
    join public.material_issues mi
      on mi.id = ii.issue_id
     and mi.organization_id = ii.organization_id
    where ii.id = v_issue_item
      and ii.issue_id = v_issue_id
      and ii.organization_id = p_organization_id
      and mi.work_order_id = p_work_order_id
      and mi.status <> 'cancelled'
    for update of ii;

    if not found then
      raise exception 'issue_item_not_found_for_work_order';
    end if;

    select coalesce(sum(ri.quantity_returned), 0)
      into v_already
    from public.material_return_items ri
    where ri.organization_id = p_organization_id
      and ri.issue_item_id = v_issue_item;

    select coalesce(max(mr.quantity_used), 0)
      into v_used
    from public.material_reconciliations mr
    where mr.organization_id = p_organization_id
      and mr.issue_item_id = v_issue_item;

    if v_already + v_used + v_qty > v_issued then
      raise exception 'return_quantity_plus_recorded_usage_exceeds_issued_quantity';
    end if;

    insert into public.material_return_items(
      organization_id, return_id, issue_item_id, material_id,
      quantity_returned, condition, notes
    )
    values (
      p_organization_id, v_return, v_issue_item, v_material,
      v_qty, v_condition, nullif(btrim(v_item->>'notes'), '')
    );

    if v_condition = 'usable' then
      update public.materials
      set current_quantity = current_quantity + v_qty,
          updated_at = now()
      where id = v_material
        and organization_id = p_organization_id;

      insert into public.stock_movements(
        organization_id, material_id, movement_type, quantity,
        reference_type, reference_id, notes, created_by
      )
      values (
        p_organization_id, v_material, 'return_in', v_qty,
        'material_return', v_return,
        'Usable material returned by contractor against PO ' || p_work_order_id::text,
        auth.uid()
      );
    end if;
  end loop;

  update public.material_issues
  set status = 'partially_returned'
  where id = v_issue_id
    and status = 'issued';

  insert into public.audit_log(
    organization_id, user_id, action, entity_type, entity_id, details
  )
  values (
    p_organization_id, auth.uid(), 'contractor_materials_returned',
    'material_return', v_return,
    jsonb_build_object(
      'issue_id', v_issue_id,
      'work_order_id', p_work_order_id,
      'contractor_id', v_contractor_id,
      'project_id', v_project_id,
      'item_count', jsonb_array_length(p_items)
    )
  );

  return v_return;
end;
$function$;

commit;
