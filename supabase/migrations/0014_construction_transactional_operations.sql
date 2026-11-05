-- Material Management System
-- Transactional construction operations.
-- Apply after 0013_construction_domain_foundation.sql.

begin;

-- A settlement can produce a recovery balance when charges exceed the
-- contractor's earned amount. Never silently clamp that debt to zero.
alter table public.contractor_settlements
  add column if not exists contractor_recovery_paise bigint not null default 0
  check (contractor_recovery_paise >= 0);

-- ============================================================
-- Contractor work order creation. Percentage is snapshotted against the
-- contract's revised total value at the time the PO is created.
-- ============================================================

create or replace function public.create_contractor_work_order(
  p_organization_id uuid,
  p_po_number text,
  p_contract_id uuid,
  p_project_id uuid,
  p_contractor_id uuid,
  p_payment_basis text,
  p_fixed_amount_paise bigint default null,
  p_percentage_rate numeric default null,
  p_po_date date default current_date,
  p_work_description text default null,
  p_start_date date default null,
  p_expected_completion_date date default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_contract_value bigint;
  v_base bigint;
  v_agreed bigint;
  v_id uuid;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if nullif(trim(p_po_number),'') is null then raise exception 'po_number_required'; end if;

  select revised_value_paise into v_contract_value
  from public.contracts
  where id=p_contract_id and organization_id=p_organization_id
  for share;
  if not found then raise exception 'contract_not_found'; end if;

  if p_project_id is not null and not exists (
    select 1 from public.projects
    where id=p_project_id and organization_id=p_organization_id and contract_id=p_contract_id
  ) then raise exception 'project_does_not_belong_to_contract'; end if;

  if not exists (select 1 from public.contractors where id=p_contractor_id and organization_id=p_organization_id and is_active) then
    raise exception 'active_contractor_not_found';
  end if;

  if p_payment_basis='fixed' then
    if p_fixed_amount_paise is null or p_fixed_amount_paise < 0 then raise exception 'valid_fixed_amount_required'; end if;
    v_base := null;
    v_agreed := p_fixed_amount_paise;
  elsif p_payment_basis='percentage' then
    if p_percentage_rate is null or p_percentage_rate <= 0 or p_percentage_rate > 100 then raise exception 'valid_percentage_required'; end if;
    v_base := v_contract_value;
    v_agreed := round(v_base * p_percentage_rate / 100.0)::bigint;
  else
    raise exception 'invalid_payment_basis';
  end if;

  insert into public.contractor_work_orders(
    organization_id,po_number,contract_id,project_id,contractor_id,po_date,
    work_description,payment_basis,fixed_amount_paise,percentage_rate,
    percentage_base_value_paise,agreed_work_amount_paise,start_date,
    expected_completion_date,created_by
  ) values (
    p_organization_id,trim(p_po_number),p_contract_id,p_project_id,p_contractor_id,
    coalesce(p_po_date,current_date),p_work_description,p_payment_basis,
    case when p_payment_basis='fixed' then p_fixed_amount_paise end,
    case when p_payment_basis='percentage' then p_percentage_rate end,
    v_base,v_agreed,p_start_date,p_expected_completion_date,auth.uid()
  ) returning id into v_id;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'contractor_work_order_created','contractor_work_order',v_id,
    jsonb_build_object('po_number',trim(p_po_number),'payment_basis',p_payment_basis,
      'percentage_base_value_paise',v_base,'agreed_work_amount_paise',v_agreed));
  return v_id;
end;
$$;

-- ============================================================
-- Record material procurement and receive stock atomically.
-- p_items: [{material_id, quantity, unit_purchase_price_paise, gst_rate}]
-- ============================================================

create or replace function public.receive_material_purchase(
  p_organization_id uuid,
  p_vendor_id uuid,
  p_purchase_number text,
  p_vendor_invoice_number text,
  p_purchase_date date,
  p_items jsonb,
  p_other_charges_paise bigint default 0,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_purchase uuid;
  v_item jsonb;
  v_material uuid;
  v_qty numeric;
  v_rate bigint;
  v_gst numeric;
  v_line bigint;
  v_subtotal bigint := 0;
  v_gst_total bigint := 0;
  v_name text;
  v_unit text;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if not exists(select 1 from public.vendors where id=p_vendor_id and organization_id=p_organization_id and is_active) then raise exception 'active_vendor_not_found'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items)=0 then raise exception 'purchase_items_required'; end if;
  if coalesce(p_other_charges_paise,0)<0 then raise exception 'other_charges_cannot_be_negative'; end if;

  insert into public.material_purchases(
    organization_id,vendor_id,purchase_number,vendor_invoice_number,purchase_date,
    status,other_charges_paise,notes,created_by
  ) values (
    p_organization_id,p_vendor_id,nullif(trim(p_purchase_number), ''),
    nullif(trim(p_vendor_invoice_number),''),coalesce(p_purchase_date,current_date),
    'received',coalesce(p_other_charges_paise,0),p_notes,auth.uid()
  ) returning id into v_purchase;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_material := (v_item->>'material_id')::uuid;
    v_qty := (v_item->>'quantity')::numeric;
    v_rate := (v_item->>'unit_purchase_price_paise')::bigint;
    v_gst := coalesce((v_item->>'gst_rate')::numeric,0);
    if v_qty<=0 or v_rate<0 or v_gst<0 or v_gst>100 then raise exception 'invalid_purchase_item'; end if;

    select m.name, coalesce(u.name,u.short_code)
      into v_name,v_unit
    from public.materials m left join public.units u on u.id=m.unit_id
    where m.id=v_material and m.organization_id=p_organization_id
    for update of m;
    if not found then raise exception 'material_not_found'; end if;

    v_line := round(v_qty*v_rate)::bigint;
    v_subtotal := v_subtotal + v_line;
    v_gst_total := v_gst_total + round(v_line*v_gst/100.0)::bigint;

    insert into public.material_purchase_items(
      organization_id,purchase_id,material_id,material_name_snapshot,unit_name_snapshot,
      quantity,unit_purchase_price_paise,gst_rate,line_total_paise
    ) values (p_organization_id,v_purchase,v_material,v_name,v_unit,v_qty,v_rate,v_gst,v_line);

    update public.materials set current_quantity=current_quantity+v_qty where id=v_material;
    insert into public.stock_movements(
      organization_id,material_id,movement_type,quantity,reference_type,reference_id,notes,created_by
    ) values (p_organization_id,v_material,'purchase',v_qty,'material_purchase',v_purchase,
      'Vendor purchase '||coalesce(p_purchase_number,v_purchase::text),auth.uid());
  end loop;

  update public.material_purchases
  set subtotal_paise=v_subtotal,gst_amount_paise=v_gst_total,
      total_amount_paise=v_subtotal+v_gst_total+coalesce(p_other_charges_paise,0)
  where id=v_purchase;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'material_purchase_received','material_purchase',v_purchase,
    jsonb_build_object('subtotal_paise',v_subtotal,'gst_amount_paise',v_gst_total));
  return v_purchase;
end;
$$;

-- ============================================================
-- Issue materials to a contractor PO. Purchase rate is snapshotted from
-- latest received purchase; contractor rate is supplied by the user.
-- p_items: [{material_id, quantity, contractor_unit_rate_paise}]
-- ============================================================

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
set search_path = public
as $$
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
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  select contractor_id into v_contractor from public.contractor_work_orders where id=p_work_order_id and organization_id=p_organization_id and status='active' for share;
  if not found then
    raise exception 'active_work_order_not_found';
  end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'issue_items_required'; end if;

  insert into public.material_issues(organization_id,issue_number,work_order_id,issue_date,notes,issued_by)
  values (p_organization_id,trim(p_issue_number),p_work_order_id,coalesce(p_issue_date,current_date),p_notes,auth.uid())
  returning id into v_issue;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_material := (v_item->>'material_id')::uuid;
    v_qty := (v_item->>'quantity')::numeric;
    v_rate := (v_item->>'contractor_unit_rate_paise')::bigint;
    if v_qty<=0 or v_rate<0 then raise exception 'invalid_issue_item'; end if;

    select m.name,coalesce(u.name,u.short_code),m.current_quantity
      into v_name,v_unit,v_stock
    from public.materials m left join public.units u on u.id=m.unit_id
    where m.id=v_material and m.organization_id=p_organization_id and m.is_active
    for update of m;
    if not found then raise exception 'active_material_not_found'; end if;
    if v_stock<v_qty then raise exception 'insufficient_stock_for_material: %',v_name; end if;

    select pi.unit_purchase_price_paise into v_cost
    from public.material_purchase_items pi
    join public.material_purchases mp on mp.id=pi.purchase_id and mp.organization_id=pi.organization_id
    where pi.organization_id=p_organization_id and pi.material_id=v_material and mp.status='received'
    order by mp.purchase_date desc,mp.created_at desc limit 1;
    v_cost := coalesce(v_cost,0);

    insert into public.contractor_material_rates(organization_id,contractor_id,material_id,unit_rate_paise)
    values (p_organization_id,v_contractor,v_material,v_rate)
    on conflict (organization_id,contractor_id,material_id)
    do update set unit_rate_paise=excluded.unit_rate_paise,updated_at=now();

    insert into public.material_issue_items(
      organization_id,issue_id,material_id,material_name_snapshot,unit_name_snapshot,
      quantity_issued,purchase_unit_cost_paise,contractor_unit_rate_paise
    ) values (p_organization_id,v_issue,v_material,v_name,v_unit,v_qty,v_cost,v_rate);

    update public.materials set current_quantity=current_quantity-v_qty where id=v_material;
    insert into public.stock_movements(
      organization_id,material_id,movement_type,quantity,reference_type,reference_id,notes,created_by
    ) values (p_organization_id,v_material,'sale',v_qty,'material_issue',v_issue,
      'Issued against contractor PO '||p_work_order_id::text,auth.uid());
  end loop;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'contractor_materials_issued','material_issue',v_issue,
    jsonb_build_object('work_order_id',p_work_order_id));
  return v_issue;
end;
$$;

-- ============================================================
-- Return materials. A return is linked to the original issue line and cannot
-- exceed the quantity issued less prior returns.
-- p_items: [{issue_item_id, quantity_returned}]
-- ============================================================

create or replace function public.return_contractor_materials(
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
set search_path = public
as $$
declare
  v_return uuid;
  v_item jsonb;
  v_issue_item uuid;
  v_qty numeric;
  v_issued numeric;
  v_already numeric;
  v_used numeric;
  v_material uuid;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'return_items_required'; end if;
  if not exists(select 1 from public.contractor_work_orders where id=p_work_order_id and organization_id=p_organization_id and status in ('active','work_completed')) then raise exception 'work_order_not_open_for_material_returns'; end if;

  insert into public.material_returns(organization_id,return_number,work_order_id,return_date,notes,received_by)
  values (p_organization_id,trim(p_return_number),p_work_order_id,coalesce(p_return_date,current_date),p_notes,auth.uid())
  returning id into v_return;

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_issue_item := (v_item->>'issue_item_id')::uuid;
    v_qty := (v_item->>'quantity_returned')::numeric;
    if v_qty<=0 then raise exception 'return_quantity_must_be_positive'; end if;

    select ii.quantity_issued,ii.material_id into v_issued,v_material
    from public.material_issue_items ii
    join public.material_issues mi on mi.id=ii.issue_id and mi.organization_id=ii.organization_id
    where ii.id=v_issue_item and ii.organization_id=p_organization_id
      and mi.work_order_id=p_work_order_id and mi.status='issued'
    for update of ii;
    if not found then raise exception 'issue_item_not_found_for_work_order'; end if;

    select coalesce(sum(quantity_returned),0) into v_already
    from public.material_return_items
    where organization_id=p_organization_id and issue_item_id=v_issue_item;
    select coalesce(quantity_used,0) into v_used
    from public.material_reconciliations
    where organization_id=p_organization_id and issue_item_id=v_issue_item;
    if v_already+coalesce(v_used,0)+v_qty>v_issued then raise exception 'return_quantity_plus_recorded_usage_exceeds_issued_quantity'; end if;

    insert into public.material_return_items(organization_id,return_id,issue_item_id,material_id,quantity_returned)
    values (p_organization_id,v_return,v_issue_item,v_material,v_qty);

    update public.materials set current_quantity=current_quantity+v_qty
    where id=v_material and organization_id=p_organization_id;
    insert into public.stock_movements(
      organization_id,material_id,movement_type,quantity,reference_type,reference_id,notes,created_by
    ) values (p_organization_id,v_material,'return_in',v_qty,'material_return',v_return,
      'Returned against contractor PO '||p_work_order_id::text,auth.uid());
  end loop;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'contractor_materials_returned','material_return',v_return,
    jsonb_build_object('work_order_id',p_work_order_id));
  return v_return;
end;
$$;

-- ============================================================
-- Record daily advance against a contractor PO.
-- ============================================================

create or replace function public.record_contractor_advance(
  p_organization_id uuid,
  p_work_order_id uuid,
  p_advance_date date,
  p_amount_paise bigint,
  p_payment_method public.payment_method default 'cash',
  p_reference_number text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if p_amount_paise<=0 then raise exception 'advance_amount_must_be_positive'; end if;
  if not exists(select 1 from public.contractor_work_orders where id=p_work_order_id and organization_id=p_organization_id and status in ('active','work_completed','under_closure')) then
    raise exception 'work_order_not_available_for_advance';
  end if;
  insert into public.contractor_advances(
    organization_id,work_order_id,advance_date,amount_paise,payment_method,reference_number,notes,paid_by
  ) values (
    p_organization_id,p_work_order_id,coalesce(p_advance_date,current_date),p_amount_paise,
    coalesce(p_payment_method,'cash'),p_reference_number,p_notes,auth.uid()
  ) returning id into v_id;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'contractor_advance_paid','contractor_advance',v_id,
    jsonb_build_object('work_order_id',p_work_order_id,'amount_paise',p_amount_paise));
  return v_id;
end;
$$;

-- ============================================================
-- Record consumption reconciliation for one issue line.
-- Returns are recorded separately through return_contractor_materials.
-- ============================================================

create or replace function public.reconcile_contractor_material_usage(
  p_organization_id uuid,
  p_work_order_id uuid,
  p_issue_item_id uuid,
  p_quantity_used numeric,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_issued numeric;
  v_returned numeric;
  v_id uuid;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if p_quantity_used<0 then raise exception 'used_quantity_cannot_be_negative'; end if;
  if not exists(select 1 from public.contractor_work_orders where id=p_work_order_id and organization_id=p_organization_id and status='work_completed') then raise exception 'work_order_must_be_completed_before_final_material_reconciliation'; end if;
  select quantity_issued into v_issued
  from public.material_issue_items
  where id=p_issue_item_id and organization_id=p_organization_id
  for update;
  if not found then raise exception 'issue_item_not_found'; end if;
  if not exists(
    select 1 from public.material_issues
    where id=(select issue_id from public.material_issue_items where id=p_issue_item_id)
      and organization_id=p_organization_id and work_order_id=p_work_order_id
  ) then raise exception 'issue_item_does_not_belong_to_work_order'; end if;
  select coalesce(sum(quantity_returned),0) into v_returned
  from public.material_return_items where organization_id=p_organization_id and issue_item_id=p_issue_item_id;
  if p_quantity_used+v_returned>v_issued then raise exception 'used_plus_returned_exceeds_issued_quantity'; end if;

  insert into public.material_reconciliations(
    organization_id,work_order_id,issue_item_id,quantity_used,notes,reconciled_by
  ) values (p_organization_id,p_work_order_id,p_issue_item_id,p_quantity_used,p_notes,auth.uid())
  on conflict (organization_id,work_order_id,issue_item_id)
  do update set quantity_used=excluded.quantity_used,notes=excluded.notes,
    reconciled_by=auth.uid(),reconciled_at=now()
  returning id into v_id;
  return v_id;
end;
$$;

-- ============================================================
-- Prepare settlement from authoritative ledgers. All material issue lines
-- must be reconciled. Material charges use issued minus returned, at the
-- contractor rate snapshotted at issue time. Advances are fully adjusted.
-- ============================================================

create or replace function public.prepare_contractor_settlement(
  p_organization_id uuid,
  p_work_order_id uuid,
  p_settlement_number text,
  p_settlement_date date default current_date,
  p_other_deductions_paise bigint default 0,
  p_adjustments_paise bigint default 0,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_work bigint;
  v_material bigint;
  v_advances bigint;
  v_final bigint;
  v_recovery bigint;
  v_id uuid;
  v_unreconciled integer;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if coalesce(p_other_deductions_paise,0)<0 then raise exception 'deductions_cannot_be_negative'; end if;
  select agreed_work_amount_paise into v_work
  from public.contractor_work_orders
  where id=p_work_order_id and organization_id=p_organization_id and status in ('work_completed','under_closure')
  for update;
  if not found then raise exception 'work_order_must_be_completed_before_settlement'; end if;

  select count(*) into v_unreconciled
  from public.material_issue_items ii
  join public.material_issues mi on mi.id=ii.issue_id and mi.organization_id=ii.organization_id
  left join public.material_reconciliations mr on mr.organization_id=ii.organization_id and mr.issue_item_id=ii.id
  where ii.organization_id=p_organization_id and mi.work_order_id=p_work_order_id
    and mi.status='issued' and mr.id is null;
  if v_unreconciled>0 then raise exception 'all_issued_material_lines_must_be_reconciled'; end if;

  select coalesce(round(sum(material_charge_paise)),0)::bigint into v_material
  from public.contractor_material_reconciliation_summary
  where organization_id=p_organization_id and work_order_id=p_work_order_id;

  select coalesce(sum(amount_paise),0)::bigint into v_advances
  from public.contractor_advances where organization_id=p_organization_id and work_order_id=p_work_order_id;

  v_final := greatest(v_work-v_material-v_advances-coalesce(p_other_deductions_paise,0)+coalesce(p_adjustments_paise,0),0);
  v_recovery := greatest(v_material+v_advances+coalesce(p_other_deductions_paise,0)-v_work-coalesce(p_adjustments_paise,0),0);

  insert into public.contractor_settlements(
    organization_id,settlement_number,work_order_id,settlement_date,
    agreed_work_amount_paise,material_charges_paise,advances_adjusted_paise,
    other_deductions_paise,adjustments_paise,final_payable_paise,
    contractor_recovery_paise,status,notes,prepared_by
  ) values (
    p_organization_id,trim(p_settlement_number),p_work_order_id,coalesce(p_settlement_date,current_date),
    v_work,v_material,v_advances,coalesce(p_other_deductions_paise,0),
    coalesce(p_adjustments_paise,0),v_final,v_recovery,'draft',p_notes,auth.uid()
  ) returning id into v_id;

  update public.contractor_work_orders set status='under_closure' where id=p_work_order_id;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'contractor_settlement_prepared','contractor_settlement',v_id,
    jsonb_build_object('agreed_work_amount_paise',v_work,'material_charges_paise',v_material,
      'advances_adjusted_paise',v_advances,'final_payable_paise',v_final,'contractor_recovery_paise',v_recovery));
  return v_id;
end;
$$;

-- Record partial/final settlement payments; prevent overpayment.
create or replace function public.record_contractor_settlement_payment(
  p_organization_id uuid,
  p_settlement_id uuid,
  p_payment_date date,
  p_amount_paise bigint,
  p_payment_method public.payment_method default 'bank_transfer',
  p_reference_number text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_total bigint;
  v_paid bigint;
  v_id uuid;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if p_amount_paise<=0 then raise exception 'payment_amount_must_be_positive'; end if;
  select final_payable_paise into v_total
  from public.contractor_settlements
  where id=p_settlement_id and organization_id=p_organization_id and status in ('approved','partially_paid')
  for update;
  if not found then raise exception 'approved_settlement_not_found'; end if;
  select coalesce(sum(amount_paise),0) into v_paid
  from public.contractor_settlement_payments
  where organization_id=p_organization_id and settlement_id=p_settlement_id;
  if v_paid+p_amount_paise>v_total then raise exception 'payment_exceeds_settlement_balance'; end if;

  insert into public.contractor_settlement_payments(
    organization_id,settlement_id,payment_date,amount_paise,payment_method,reference_number,notes,paid_by
  ) values (
    p_organization_id,p_settlement_id,coalesce(p_payment_date,current_date),p_amount_paise,
    coalesce(p_payment_method,'bank_transfer'),p_reference_number,p_notes,auth.uid()
  ) returning id into v_id;

  update public.contractor_settlements
  set status=case when v_paid+p_amount_paise=v_total then 'paid' else 'partially_paid' end
  where id=p_settlement_id;

  if v_paid+p_amount_paise=v_total then
    update public.contractor_work_orders wo
    set status='settled'
    where wo.id=(select work_order_id from public.contractor_settlements where id=p_settlement_id);
  end if;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'contractor_settlement_payment_recorded','contractor_settlement_payment',v_id,
    jsonb_build_object('settlement_id',p_settlement_id,'amount_paise',p_amount_paise));
  return v_id;
end;
$$;

-- Summary view for closure workspace.
create or replace view public.contractor_work_order_finance_summary
with (security_invoker = true) as
select
  wo.id as work_order_id,
  wo.organization_id,
  wo.po_number,
  wo.contractor_id,
  wo.contract_id,
  wo.project_id,
  wo.payment_basis,
  wo.percentage_rate,
  wo.percentage_base_value_paise,
  wo.agreed_work_amount_paise,
  coalesce(mat.material_charges_paise,0)::bigint as material_charges_paise,
  coalesce(mat.quantity_issued,0)::numeric(14,3) as quantity_issued,
  coalesce(mat.quantity_returned,0)::numeric(14,3) as quantity_returned,
  coalesce(mat.quantity_used,0)::numeric(14,3) as quantity_used,
  coalesce(mat.quantity_unaccounted,0)::numeric(14,3) as quantity_unaccounted,
  coalesce(adv.advances_paise,0)::bigint as advances_paise,
  coalesce(st.final_payable_paise,0)::bigint as final_payable_paise,
  coalesce(st.contractor_recovery_paise,0)::bigint as contractor_recovery_paise,
  st.status as settlement_status
from public.contractor_work_orders wo
left join (
  select organization_id,work_order_id,
    sum(quantity_issued) quantity_issued,
    sum(quantity_returned) quantity_returned,
    sum(quantity_used) quantity_used,
    sum(quantity_unaccounted) quantity_unaccounted,
    sum(material_charge_paise) material_charges_paise
  from public.contractor_material_reconciliation_summary
  group by organization_id,work_order_id
) mat on mat.organization_id=wo.organization_id and mat.work_order_id=wo.id
left join (
  select organization_id,work_order_id,sum(amount_paise) advances_paise
  from public.contractor_advances group by organization_id,work_order_id
) adv on adv.organization_id=wo.organization_id and adv.work_order_id=wo.id
left join public.contractor_settlements st
  on st.organization_id=wo.organization_id and st.work_order_id=wo.id and st.status<>'cancelled';

-- Enriched stock ledger: identify the vendor for purchases and the
-- contractor, PO, contract and project for material issues/returns.
create or replace view public.construction_stock_ledger
with (security_invoker = true) as
select
  sm.id,
  sm.organization_id,
  sm.material_id,
  sm.movement_type,
  sm.quantity,
  sm.reference_type,
  sm.reference_id,
  sm.notes,
  sm.created_by,
  sm.created_at,
  m.name as material_name,
  m.selling_price_paise,
  u.short_code as unit_short_code,
  coalesce(ct.name,v.name) as counterparty_name,
  p.name as project_name,
  c.contract_number,
  wo.po_number,
  mp.vendor_invoice_number
from public.stock_movements sm
join public.materials m on m.id=sm.material_id and m.organization_id=sm.organization_id
left join public.units u on u.id=m.unit_id and u.organization_id=m.organization_id
left join public.material_issues mi
  on sm.reference_type='material_issue' and mi.id=sm.reference_id and mi.organization_id=sm.organization_id
left join public.material_returns mr
  on sm.reference_type='material_return' and mr.id=sm.reference_id and mr.organization_id=sm.organization_id
left join public.contractor_work_orders wo
  on wo.id=coalesce(mi.work_order_id,mr.work_order_id) and wo.organization_id=sm.organization_id
left join public.contractors ct
  on ct.id=wo.contractor_id and ct.organization_id=sm.organization_id
left join public.contracts c
  on c.id=wo.contract_id and c.organization_id=sm.organization_id
left join public.projects p
  on p.id=wo.project_id and p.organization_id=sm.organization_id
left join public.material_purchases mp
  on sm.reference_type='material_purchase' and mp.id=sm.reference_id and mp.organization_id=sm.organization_id
left join public.vendors v
  on v.id=mp.vendor_id and v.organization_id=sm.organization_id;

-- Explicit grants: RPCs are callable by signed-in organization members;
-- each function performs its own tenant and business validation.
grant execute on function public.create_contractor_work_order(uuid,text,uuid,uuid,uuid,text,bigint,numeric,date,text,date,date) to authenticated;
grant execute on function public.receive_material_purchase(uuid,uuid,text,text,date,jsonb,bigint,text) to authenticated;
grant execute on function public.issue_contractor_materials(uuid,uuid,text,date,jsonb,text) to authenticated;
grant execute on function public.return_contractor_materials(uuid,uuid,text,date,jsonb,text) to authenticated;
grant execute on function public.record_contractor_advance(uuid,uuid,date,bigint,public.payment_method,text,text) to authenticated;
grant execute on function public.reconcile_contractor_material_usage(uuid,uuid,uuid,numeric,text) to authenticated;
grant execute on function public.prepare_contractor_settlement(uuid,uuid,text,date,bigint,bigint,text) to authenticated;
grant execute on function public.record_contractor_settlement_payment(uuid,uuid,date,bigint,public.payment_method,text,text) to authenticated;

revoke execute on function public.create_contractor_work_order(uuid,text,uuid,uuid,uuid,text,bigint,numeric,date,text,date,date) from anon;
revoke execute on function public.receive_material_purchase(uuid,uuid,text,text,date,jsonb,bigint,text) from anon;
revoke execute on function public.issue_contractor_materials(uuid,uuid,text,date,jsonb,text) from anon;
revoke execute on function public.return_contractor_materials(uuid,uuid,text,date,jsonb,text) from anon;
revoke execute on function public.record_contractor_advance(uuid,uuid,date,bigint,public.payment_method,text,text) from anon;
revoke execute on function public.reconcile_contractor_material_usage(uuid,uuid,uuid,numeric,text) from anon;
revoke execute on function public.prepare_contractor_settlement(uuid,uuid,text,date,bigint,bigint,text) from anon;
revoke execute on function public.record_contractor_settlement_payment(uuid,uuid,date,bigint,public.payment_method,text,text) from anon;

insert into public.app_schema_version(version) values (14) on conflict (version) do nothing;

commit;
