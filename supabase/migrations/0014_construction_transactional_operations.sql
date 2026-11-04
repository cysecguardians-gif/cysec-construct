-- Construction workflow transactional operations.
-- Apply after 0013_construction_workflow_foundation.sql.
-- All stock and financial writes are exposed through validated atomic RPCs.

begin;

-- ============================================================
-- Master records
-- ============================================================

create or replace function public.create_client_company(
  p_organization_id uuid, p_name text, p_gstin text default null, p_pan text default null,
  p_contact_person text default null, p_phone text default null, p_email text default null,
  p_address text default null, p_city text default null, p_state text default null,
  p_state_code text default null, p_postal_code text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  perform public.require_org_member(p_organization_id);
  if nullif(trim(p_name), '') is null then raise exception 'client_company_name_required'; end if;
  insert into public.client_companies(organization_id,name,gstin,pan,contact_person,phone,email,address,city,state,state_code,postal_code)
  values(p_organization_id,trim(p_name),nullif(trim(p_gstin),''),nullif(trim(p_pan),''),nullif(trim(p_contact_person),''),nullif(trim(p_phone),''),nullif(trim(p_email),''),nullif(trim(p_address),''),nullif(trim(p_city),''),nullif(trim(p_state),''),nullif(trim(p_state_code),''),nullif(trim(p_postal_code),''))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.create_contract(
  p_organization_id uuid, p_client_company_id uuid, p_contract_number text, p_title text,
  p_original_value_paise bigint, p_revised_value_paise bigint default null,
  p_contract_type text default 'tender', p_contract_date date default current_date,
  p_start_date date default null, p_expected_end_date date default null,
  p_scope_of_work text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  perform public.require_org_member(p_organization_id);
  if not exists(select 1 from public.client_companies where id=p_client_company_id and organization_id=p_organization_id and is_active) then raise exception 'client_company_not_found_or_inactive'; end if;
  if nullif(trim(p_contract_number),'') is null or nullif(trim(p_title),'') is null then raise exception 'contract_number_and_title_required'; end if;
  if p_original_value_paise < 0 or coalesce(p_revised_value_paise,p_original_value_paise) < 0 then raise exception 'contract_value_invalid'; end if;
  insert into public.contracts(organization_id,client_company_id,contract_number,title,contract_type,contract_date,start_date,expected_end_date,original_value_paise,revised_value_paise,scope_of_work,notes,created_by)
  values(p_organization_id,p_client_company_id,trim(p_contract_number),trim(p_title),p_contract_type,p_contract_date,p_start_date,p_expected_end_date,p_original_value_paise,coalesce(p_revised_value_paise,p_original_value_paise),p_scope_of_work,p_notes,auth.uid())
  returning id into v_id;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'contract_created','contract',v_id,jsonb_build_object('contract_number',p_contract_number,'original_value_paise',p_original_value_paise));
  return v_id;
end $$;

create or replace function public.create_project(
  p_organization_id uuid, p_contract_id uuid, p_name text, p_project_code text default null,
  p_site_address text default null, p_site_contact text default null, p_site_phone text default null,
  p_start_date date default null, p_expected_end_date date default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  perform public.require_org_member(p_organization_id);
  if not exists(select 1 from public.contracts where id=p_contract_id and organization_id=p_organization_id and status not in ('cancelled','closed')) then raise exception 'contract_not_found_or_closed'; end if;
  if nullif(trim(p_name),'') is null then raise exception 'project_name_required'; end if;
  insert into public.projects(organization_id,contract_id,project_code,name,site_address,site_contact,site_phone,start_date,expected_end_date,notes)
  values(p_organization_id,p_contract_id,nullif(trim(p_project_code),''),trim(p_name),p_site_address,p_site_contact,p_site_phone,p_start_date,p_expected_end_date,p_notes)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.create_vendor(
  p_organization_id uuid, p_name text, p_gstin text default null, p_pan text default null,
  p_contact_person text default null, p_phone text default null, p_email text default null,
  p_address text default null, p_city text default null, p_state text default null,
  p_state_code text default null, p_postal_code text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  perform public.require_org_member(p_organization_id);
  if nullif(trim(p_name),'') is null then raise exception 'vendor_name_required'; end if;
  insert into public.vendors(organization_id,name,gstin,pan,contact_person,phone,email,address,city,state,state_code,postal_code)
  values(p_organization_id,trim(p_name),nullif(trim(p_gstin),''),nullif(trim(p_pan),''),nullif(trim(p_contact_person),''),nullif(trim(p_phone),''),nullif(trim(p_email),''),nullif(trim(p_address),''),nullif(trim(p_city),''),nullif(trim(p_state),''),nullif(trim(p_state_code),''),nullif(trim(p_postal_code),''))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.create_contractor(
  p_organization_id uuid, p_name text, p_contractor_type text default 'subcontractor',
  p_gstin text default null, p_pan text default null, p_contact_person text default null,
  p_phone text default null, p_email text default null, p_address text default null,
  p_city text default null, p_state text default null, p_state_code text default null,
  p_postal_code text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  perform public.require_org_member(p_organization_id);
  if nullif(trim(p_name),'') is null then raise exception 'contractor_name_required'; end if;
  insert into public.contractors(organization_id,name,contractor_type,gstin,pan,contact_person,phone,email,address,city,state,state_code,postal_code,notes)
  values(p_organization_id,trim(p_name),p_contractor_type,nullif(trim(p_gstin),''),nullif(trim(p_pan),''),nullif(trim(p_contact_person),''),nullif(trim(p_phone),''),nullif(trim(p_email),''),nullif(trim(p_address),''),nullif(trim(p_city),''),nullif(trim(p_state),''),nullif(trim(p_state_code),''),nullif(trim(p_postal_code),''),p_notes)
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.create_contractor_work_order(
  p_organization_id uuid, p_project_id uuid, p_contractor_id uuid, p_po_number text,
  p_payment_basis text, p_fixed_amount_paise bigint default null, p_agreed_percentage numeric default null,
  p_po_date date default current_date, p_materials_chargeable boolean default true,
  p_start_date date default null, p_expected_end_date date default null,
  p_scope_of_work text default null, p_terms_and_conditions text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_contract_value bigint; v_amount bigint;
begin
  perform public.require_org_member(p_organization_id);
  if nullif(trim(p_po_number),'') is null then raise exception 'po_number_required'; end if;
  if not exists(select 1 from public.projects where id=p_project_id and organization_id=p_organization_id and status not in ('cancelled','closed')) then raise exception 'project_not_found_or_closed'; end if;
  if not exists(select 1 from public.contractors where id=p_contractor_id and organization_id=p_organization_id and is_active) then raise exception 'contractor_not_found_or_inactive'; end if;
  select c.revised_value_paise into v_contract_value from public.projects p join public.contracts c on c.id=p.contract_id where p.id=p_project_id and c.organization_id=p_organization_id for share of c;
  if p_payment_basis='fixed' then
    if p_fixed_amount_paise is null or p_fixed_amount_paise < 0 or p_agreed_percentage is not null then raise exception 'invalid_fixed_work_order_amount'; end if;
    v_amount := p_fixed_amount_paise;
  elsif p_payment_basis='percentage' then
    if p_agreed_percentage is null or p_agreed_percentage <= 0 or p_agreed_percentage > 100 or p_fixed_amount_paise is not null then raise exception 'invalid_percentage_work_order'; end if;
    v_amount := round(v_contract_value * p_agreed_percentage / 100);
  else raise exception 'payment_basis_must_be_fixed_or_percentage'; end if;
  insert into public.contractor_work_orders(organization_id,project_id,contractor_id,po_number,po_date,payment_basis,fixed_amount_paise,agreed_percentage,basis_contract_value_paise,agreed_work_amount_paise,materials_chargeable,start_date,expected_end_date,status,scope_of_work,terms_and_conditions,notes,created_by)
  values(p_organization_id,p_project_id,p_contractor_id,trim(p_po_number),p_po_date,p_payment_basis,p_fixed_amount_paise,p_agreed_percentage,v_contract_value,v_amount,p_materials_chargeable,p_start_date,p_expected_end_date,'active',p_scope_of_work,p_terms_and_conditions,p_notes,auth.uid())
  returning id into v_id;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'contractor_work_order_created','contractor_work_order',v_id,jsonb_build_object('po_number',p_po_number,'payment_basis',p_payment_basis,'basis_contract_value_paise',v_contract_value,'agreed_work_amount_paise',v_amount));
  return v_id;
end $$;

-- ============================================================
-- Vendor purchase: purchase record, stock update and ledger rows are atomic.
-- p_items: [{material_id, quantity, unit_cost_paise, gst_rate}]
-- ============================================================

create or replace function public.record_material_purchase(
  p_organization_id uuid, p_vendor_id uuid, p_items jsonb,
  p_purchase_date date default current_date, p_purchase_number text default null,
  p_vendor_invoice_number text default null, p_other_charges_paise bigint default 0, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_purchase uuid; v_item jsonb; v_material public.materials%rowtype;
  v_qty numeric(14,3); v_cost bigint; v_rate numeric(5,2); v_subtotal bigint:=0;
  v_gst bigint:=0; v_line bigint; v_line_gst bigint; v_count integer:=0;
begin
  perform public.require_org_member(p_organization_id);
  if not exists(select 1 from public.vendors where id=p_vendor_id and organization_id=p_organization_id and is_active) then raise exception 'vendor_not_found_or_inactive'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'purchase_requires_items'; end if;
  if coalesce(p_other_charges_paise,0)<0 then raise exception 'other_charges_cannot_be_negative'; end if;
  insert into public.material_purchases(organization_id,vendor_id,purchase_number,vendor_invoice_number,purchase_date,other_charges_paise,notes,created_by)
  values(p_organization_id,p_vendor_id,nullif(trim(p_purchase_number),''),nullif(trim(p_vendor_invoice_number),''),p_purchase_date,coalesce(p_other_charges_paise,0),p_notes,auth.uid())
  returning id into v_purchase;
  for v_item in select value from jsonb_array_elements(p_items) loop
    select * into v_material from public.materials where id=(v_item->>'material_id')::uuid and organization_id=p_organization_id and is_active for update;
    if not found then raise exception 'purchase_material_not_found_or_inactive'; end if;
    v_qty := (v_item->>'quantity')::numeric;
    v_cost := (v_item->>'unit_cost_paise')::bigint;
    v_rate := coalesce(nullif(v_item->>'gst_rate','')::numeric,v_material.gst_rate);
    if v_qty is null or v_qty<=0 or v_cost<0 or v_rate<0 or v_rate>100 then raise exception 'invalid_purchase_item'; end if;
    v_line := round(v_qty*v_cost); v_line_gst := round(v_line*v_rate/100);
    v_subtotal := v_subtotal+v_line; v_gst := v_gst+v_line_gst;
    insert into public.material_purchase_items(organization_id,purchase_id,material_id,description_snapshot,unit_name_snapshot,quantity,unit_cost_paise,gst_rate,line_subtotal_paise,line_gst_paise)
    values(p_organization_id,v_purchase,v_material.id,v_material.name,(select name from public.units where id=v_material.unit_id),v_qty,v_cost,v_rate,v_line,v_line_gst);
    update public.materials set current_quantity=current_quantity+v_qty,purchase_price_paise=v_cost,updated_at=now() where id=v_material.id;
    insert into public.stock_movements(organization_id,material_id,movement_type,quantity,reference_type,reference_id,notes,created_by)
    values(p_organization_id,v_material.id,'purchase',v_qty,'material_purchase',v_purchase,'Vendor purchase',auth.uid());
    v_count:=v_count+1;
  end loop;
  update public.material_purchases set subtotal_paise=v_subtotal,gst_amount_paise=v_gst,total_amount_paise=v_subtotal+v_gst+coalesce(p_other_charges_paise,0) where id=v_purchase;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'material_purchase_recorded','material_purchase',v_purchase,jsonb_build_object('line_count',v_count,'subtotal_paise',v_subtotal,'gst_paise',v_gst));
  return v_purchase;
end $$;

-- ============================================================
-- Daily issue: purchase cost is shown as default; contractor rate is editable.
-- p_items: [{material_id, quantity, contractor_unit_rate_paise?}]
-- ============================================================

create or replace function public.issue_materials_to_contractor(
  p_organization_id uuid, p_work_order_id uuid, p_items jsonb,
  p_issue_date date default current_date, p_issue_number text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_issue uuid; v_wo public.contractor_work_orders%rowtype; v_item jsonb;
  v_material public.materials%rowtype; v_qty numeric(14,3); v_rate bigint; v_count integer:=0;
begin
  perform public.require_org_member(p_organization_id);
  select * into v_wo from public.contractor_work_orders where id=p_work_order_id and organization_id=p_organization_id for update;
  if not found or v_wo.status not in ('active','on_hold') then raise exception 'work_order_not_active'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'material_issue_requires_items'; end if;
  insert into public.material_issues(organization_id,work_order_id,contractor_id,project_id,issue_number,issue_date,notes,issued_by)
  values(p_organization_id,v_wo.id,v_wo.contractor_id,v_wo.project_id,nullif(trim(p_issue_number),''),p_issue_date,p_notes,auth.uid())
  returning id into v_issue;
  for v_item in select value from jsonb_array_elements(p_items) loop
    select * into v_material from public.materials where id=(v_item->>'material_id')::uuid and organization_id=p_organization_id and is_active for update;
    if not found then raise exception 'issue_material_not_found_or_inactive'; end if;
    v_qty := (v_item->>'quantity')::numeric;
    v_rate := coalesce(nullif(v_item->>'contractor_unit_rate_paise','')::bigint,v_material.purchase_price_paise);
    if v_qty is null or v_qty<=0 or v_rate<0 then raise exception 'invalid_material_issue_item'; end if;
    if v_material.current_quantity<v_qty then raise exception 'insufficient_stock_for_material: %',v_material.name; end if;
    insert into public.material_issue_items(organization_id,issue_id,material_id,description_snapshot,unit_name_snapshot,quantity_issued,purchase_unit_cost_paise,contractor_unit_rate_paise)
    values(p_organization_id,v_issue,v_material.id,v_material.name,(select name from public.units where id=v_material.unit_id),v_qty,v_material.purchase_price_paise,v_rate);
    update public.materials set current_quantity=current_quantity-v_qty,updated_at=now() where id=v_material.id;
    insert into public.stock_movements(organization_id,material_id,movement_type,quantity,reference_type,reference_id,notes,created_by)
    values(p_organization_id,v_material.id,'sale',v_qty,'contractor_material_issue',v_issue,'Material issued against PO '||v_wo.po_number,auth.uid());
    v_count:=v_count+1;
  end loop;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'contractor_materials_issued','material_issue',v_issue,jsonb_build_object('work_order_id',v_wo.id,'line_count',v_count));
  return v_issue;
end $$;

-- ============================================================
-- Returns: only usable returns are added back to available stock.
-- p_items: [{issue_item_id, quantity_returned, condition, notes}]
-- ============================================================

create or replace function public.return_contractor_materials(
  p_organization_id uuid, p_issue_id uuid, p_items jsonb,
  p_return_date date default current_date, p_return_number text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_return uuid; v_issue public.material_issues%rowtype; v_item jsonb;
  v_line public.material_issue_items%rowtype; v_qty numeric(14,3);
  v_already numeric(14,3); v_condition text; v_count integer:=0;
begin
  perform public.require_org_member(p_organization_id);
  select * into v_issue from public.material_issues where id=p_issue_id and organization_id=p_organization_id for update;
  if not found or v_issue.status='cancelled' then raise exception 'material_issue_not_found_or_cancelled'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'return_requires_items'; end if;
  insert into public.material_returns(organization_id,issue_id,work_order_id,contractor_id,project_id,return_number,return_date,notes,received_by)
  values(p_organization_id,v_issue.id,v_issue.work_order_id,v_issue.contractor_id,v_issue.project_id,nullif(trim(p_return_number),''),p_return_date,p_notes,auth.uid())
  returning id into v_return;
  for v_item in select value from jsonb_array_elements(p_items) loop
    select * into v_line from public.material_issue_items where id=(v_item->>'issue_item_id')::uuid and issue_id=v_issue.id and organization_id=p_organization_id for update;
    if not found then raise exception 'return_issue_item_not_found'; end if;
    v_qty := (v_item->>'quantity_returned')::numeric;
    v_condition := coalesce(nullif(v_item->>'condition',''),'usable');
    if v_qty is null or v_qty<=0 or v_condition not in ('usable','damaged','scrap') then raise exception 'invalid_material_return_item'; end if;
    select coalesce(sum(ri.quantity_returned),0) into v_already from public.material_return_items ri where ri.issue_item_id=v_line.id;
    if v_already+v_qty>v_line.quantity_issued then raise exception 'return_quantity_exceeds_issued_quantity'; end if;
    insert into public.material_return_items(organization_id,return_id,issue_item_id,material_id,quantity_returned,condition,notes)
    values(p_organization_id,v_return,v_line.id,v_line.material_id,v_qty,v_condition,nullif(v_item->>'notes',''));
    if v_condition='usable' then
      update public.materials set current_quantity=current_quantity+v_qty,updated_at=now() where id=v_line.material_id;
      insert into public.stock_movements(organization_id,material_id,movement_type,quantity,reference_type,reference_id,notes,created_by)
      values(p_organization_id,v_line.material_id,'return_in',v_qty,'contractor_material_return',v_return,'Usable material returned by contractor',auth.uid());
    end if;
    v_count:=v_count+1;
  end loop;
  update public.material_issues set status='partially_returned' where id=v_issue.id and status='issued';
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'contractor_materials_returned','material_return',v_return,jsonb_build_object('issue_id',v_issue.id,'line_count',v_count));
  return v_return;
end $$;

create or replace function public.record_contractor_advance(
  p_organization_id uuid, p_work_order_id uuid, p_amount_paise bigint,
  p_advance_date date default current_date, p_payment_method text default 'cash',
  p_reference_number text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_wo public.contractor_work_orders%rowtype; v_id uuid;
begin
  perform public.require_org_member(p_organization_id);
  select * into v_wo from public.contractor_work_orders where id=p_work_order_id and organization_id=p_organization_id for update;
  if not found or v_wo.status in ('settled','cancelled') then raise exception 'work_order_not_open_for_advance'; end if;
  if p_amount_paise<=0 then raise exception 'advance_amount_must_be_positive'; end if;
  if p_payment_method not in ('cash','upi','bank_transfer','cheque','card','other') then raise exception 'invalid_payment_method'; end if;
  insert into public.contractor_advances(organization_id,work_order_id,contractor_id,advance_date,amount_paise,payment_method,reference_number,notes,paid_by)
  values(p_organization_id,v_wo.id,v_wo.contractor_id,p_advance_date,p_amount_paise,p_payment_method,p_reference_number,p_notes,auth.uid())
  returning id into v_id;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'contractor_advance_paid','contractor_advance',v_id,jsonb_build_object('work_order_id',v_wo.id,'amount_paise',p_amount_paise));
  return v_id;
end $$;

-- ============================================================
-- Reconciliation: every issued line must balance exactly.
-- p_rows: [{issue_item_id, quantity_used, unaccounted_reason}]
-- ============================================================

create or replace function public.reconcile_contractor_materials(
  p_organization_id uuid, p_work_order_id uuid, p_rows jsonb
) returns integer
language plpgsql security definer set search_path = public
as $$
declare v_wo public.contractor_work_orders%rowtype; v_row jsonb; v_line public.material_issue_items%rowtype;
  v_returned numeric(14,3); v_used numeric(14,3); v_unaccounted numeric(14,3); v_count integer:=0; v_expected integer;
begin
  perform public.require_org_member(p_organization_id);
  select * into v_wo from public.contractor_work_orders where id=p_work_order_id and organization_id=p_organization_id for update;
  if not found or v_wo.status not in ('active','on_hold','completed','settlement_pending') then raise exception 'work_order_not_available_for_reconciliation'; end if;
  if jsonb_typeof(p_rows)<>'array' then raise exception 'reconciliation_rows_must_be_array'; end if;
  select count(*) into v_expected from public.material_issue_items ii join public.material_issues mi on mi.id=ii.issue_id where mi.work_order_id=v_wo.id and mi.status<>'cancelled';
  for v_row in select value from jsonb_array_elements(p_rows) loop
    select ii.* into v_line from public.material_issue_items ii join public.material_issues mi on mi.id=ii.issue_id
    where ii.id=(v_row->>'issue_item_id')::uuid and mi.work_order_id=v_wo.id and mi.organization_id=p_organization_id for update of ii;
    if not found then raise exception 'reconciliation_issue_item_not_found'; end if;
    v_used := (v_row->>'quantity_used')::numeric;
    if v_used is null or v_used<0 then raise exception 'invalid_quantity_used'; end if;
    select coalesce(sum(ri.quantity_returned),0) into v_returned from public.material_return_items ri where ri.issue_item_id=v_line.id;
    if v_used+v_returned>v_line.quantity_issued then raise exception 'used_and_returned_exceed_issued_quantity'; end if;
    v_unaccounted := round(v_line.quantity_issued-v_used-v_returned,3);
    if v_unaccounted>0 and nullif(trim(v_row->>'unaccounted_reason'),'') is null then raise exception 'unaccounted_material_reason_required'; end if;
    insert into public.material_reconciliations(organization_id,work_order_id,issue_item_id,quantity_issued,quantity_used,quantity_returned,quantity_unaccounted,unaccounted_reason,verified_by)
    values(p_organization_id,v_wo.id,v_line.id,v_line.quantity_issued,v_used,v_returned,v_unaccounted,nullif(trim(v_row->>'unaccounted_reason'),''),auth.uid())
    on conflict(issue_item_id) do update set quantity_issued=excluded.quantity_issued,quantity_used=excluded.quantity_used,quantity_returned=excluded.quantity_returned,quantity_unaccounted=excluded.quantity_unaccounted,unaccounted_reason=excluded.unaccounted_reason,verified_by=auth.uid(),verified_at=now();
    v_count:=v_count+1;
  end loop;
  if v_count<>v_expected then raise exception 'all_issued_material_lines_must_be_reconciled'; end if;
  update public.material_issues set status='reconciled' where work_order_id=v_wo.id and status<>'cancelled';
  update public.contractor_work_orders set status='completed',actual_end_date=coalesce(actual_end_date,current_date) where id=v_wo.id and status in ('active','on_hold');
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'contractor_materials_reconciled','contractor_work_order',v_wo.id,jsonb_build_object('reconciled_lines',v_count));
  return v_count;
end $$;

-- ============================================================
-- Settlement: material charges and advances are deducted from agreed work amount.
-- Excess deductions become recovery_due_paise, never silently disappear.
-- ============================================================

create or replace function public.create_contractor_settlement(
  p_organization_id uuid, p_work_order_id uuid, p_settlement_number text,
  p_settlement_date date default current_date, p_other_deductions_paise bigint default 0,
  p_adjustments_paise bigint default 0, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_wo public.contractor_work_orders%rowtype; v_id uuid; v_advances bigint:=0;
  v_material_charges bigint:=0; v_raw bigint; v_line record; v_returned numeric(14,3); v_charge_qty numeric(14,3);
begin
  perform public.require_org_member(p_organization_id);
  select * into v_wo from public.contractor_work_orders where id=p_work_order_id and organization_id=p_organization_id for update;
  if not found or v_wo.status not in ('completed','settlement_pending') then raise exception 'work_order_must_be_completed_before_settlement'; end if;
  if nullif(trim(p_settlement_number),'') is null then raise exception 'settlement_number_required'; end if;
  if coalesce(p_other_deductions_paise,0)<0 then raise exception 'other_deductions_cannot_be_negative'; end if;
  if exists(select 1 from public.material_issue_items ii join public.material_issues mi on mi.id=ii.issue_id where mi.work_order_id=v_wo.id and mi.status<>'cancelled' and not exists(select 1 from public.material_reconciliations mr where mr.issue_item_id=ii.id)) then
    raise exception 'all_materials_must_be_reconciled_before_settlement';
  end if;
  select coalesce(sum(amount_paise),0)::bigint into v_advances from public.contractor_advances where work_order_id=v_wo.id;
  for v_line in
    select ii.id,ii.description_snapshot,ii.unit_name_snapshot,ii.quantity_issued,ii.contractor_unit_rate_paise,
      coalesce(sum(ri.quantity_returned),0)::numeric(14,3) as returned_qty
    from public.material_issue_items ii
    join public.material_issues mi on mi.id=ii.issue_id
    left join public.material_return_items ri on ri.issue_item_id=ii.id
    where mi.work_order_id=v_wo.id and mi.status<>'cancelled'
    group by ii.id
  loop
    v_returned:=v_line.returned_qty;
    v_charge_qty:=greatest(v_line.quantity_issued-v_returned,0);
    if v_wo.materials_chargeable then
      v_material_charges:=v_material_charges+round(v_charge_qty*v_line.contractor_unit_rate_paise);
    end if;
  end loop;
  v_raw:=v_wo.agreed_work_amount_paise-v_material_charges-v_advances-coalesce(p_other_deductions_paise,0)+coalesce(p_adjustments_paise,0);
  insert into public.contractor_settlements(organization_id,work_order_id,settlement_number,settlement_date,basis_contract_value_paise,payment_basis,agreed_percentage,agreed_work_amount_paise,material_charges_paise,advances_adjusted_paise,other_deductions_paise,adjustments_paise,final_payable_paise,recovery_due_paise,status,notes,prepared_by)
  values(p_organization_id,v_wo.id,trim(p_settlement_number),p_settlement_date,v_wo.basis_contract_value_paise,v_wo.payment_basis,v_wo.agreed_percentage,v_wo.agreed_work_amount_paise,v_material_charges,v_advances,coalesce(p_other_deductions_paise,0),coalesce(p_adjustments_paise,0),greatest(v_raw,0),greatest(-v_raw,0),'draft',p_notes,auth.uid())
  returning id into v_id;
  for v_line in
    select ii.id,ii.description_snapshot,ii.unit_name_snapshot,ii.quantity_issued,ii.contractor_unit_rate_paise,
      coalesce(sum(ri.quantity_returned),0)::numeric(14,3) as returned_qty
    from public.material_issue_items ii join public.material_issues mi on mi.id=ii.issue_id
    left join public.material_return_items ri on ri.issue_item_id=ii.id
    where mi.work_order_id=v_wo.id and mi.status<>'cancelled'
    group by ii.id
  loop
    v_charge_qty:=greatest(v_line.quantity_issued-v_line.returned_qty,0);
    insert into public.contractor_settlement_material_lines(organization_id,settlement_id,issue_item_id,material_name_snapshot,unit_name_snapshot,quantity_issued,quantity_returned,chargeable_quantity,contractor_unit_rate_paise,line_charge_paise)
    values(p_organization_id,v_id,v_line.id,v_line.description_snapshot,v_line.unit_name_snapshot,v_line.quantity_issued,v_line.returned_qty,v_charge_qty,v_line.contractor_unit_rate_paise,case when v_wo.materials_chargeable then round(v_charge_qty*v_line.contractor_unit_rate_paise) else 0 end);
  end loop;
  update public.contractor_work_orders set status='settlement_pending' where id=v_wo.id;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'contractor_settlement_created','contractor_settlement',v_id,jsonb_build_object('work_order_id',v_wo.id,'agreed_work_amount_paise',v_wo.agreed_work_amount_paise,'material_charges_paise',v_material_charges,'advances_paise',v_advances,'final_payable_paise',greatest(v_raw,0),'recovery_due_paise',greatest(-v_raw,0)));
  return v_id;
end $$;

create or replace function public.approve_contractor_settlement(
  p_organization_id uuid, p_settlement_id uuid
) returns void
language plpgsql security definer set search_path = public
as $$
declare v_settlement public.contractor_settlements%rowtype;
begin
  perform public.require_org_admin(p_organization_id);
  select * into v_settlement from public.contractor_settlements where id=p_settlement_id and organization_id=p_organization_id for update;
  if not found or v_settlement.status<>'draft' then raise exception 'draft_settlement_not_found'; end if;
  update public.contractor_settlements set status=case when final_payable_paise=0 then 'paid' else 'approved' end,approved_by=auth.uid(),approved_at=now() where id=v_settlement.id;
  update public.contractor_work_orders set status='settled' where id=v_settlement.work_order_id and v_settlement.final_payable_paise=0;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id)
  values(p_organization_id,auth.uid(),'contractor_settlement_approved','contractor_settlement',v_settlement.id);
end $$;

create or replace function public.record_contractor_settlement_payment(
  p_organization_id uuid, p_settlement_id uuid, p_amount_paise bigint,
  p_payment_date date default current_date, p_payment_method text default 'other',
  p_reference_number text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_settlement public.contractor_settlements%rowtype; v_paid bigint; v_id uuid;
begin
  perform public.require_org_member(p_organization_id);
  select * into v_settlement from public.contractor_settlements where id=p_settlement_id and organization_id=p_organization_id for update;
  if not found or v_settlement.status not in ('approved','partially_paid') then raise exception 'settlement_not_approved_or_already_paid'; end if;
  if p_amount_paise<=0 or p_payment_method not in ('cash','upi','bank_transfer','cheque','card','other') then raise exception 'invalid_settlement_payment'; end if;
  select coalesce(sum(amount_paise),0)::bigint into v_paid from public.contractor_settlement_payments where settlement_id=v_settlement.id;
  if v_paid+p_amount_paise>v_settlement.final_payable_paise then raise exception 'settlement_payment_exceeds_balance'; end if;
  insert into public.contractor_settlement_payments(organization_id,settlement_id,payment_date,amount_paise,payment_method,reference_number,notes,paid_by)
  values(p_organization_id,v_settlement.id,p_payment_date,p_amount_paise,p_payment_method,p_reference_number,p_notes,auth.uid())
  returning id into v_id;
  select coalesce(sum(amount_paise),0)::bigint into v_paid from public.contractor_settlement_payments where settlement_id=v_settlement.id;
  update public.contractor_settlements set status=case when v_paid>=final_payable_paise then 'paid' else 'partially_paid' end where id=v_settlement.id;
  if v_paid>=v_settlement.final_payable_paise then update public.contractor_work_orders set status='settled' where id=v_settlement.work_order_id; end if;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'contractor_settlement_payment_recorded','contractor_settlement_payment',v_id,jsonb_build_object('settlement_id',v_settlement.id,'amount_paise',p_amount_paise));
  return v_id;
end $$;

-- Explicit grants: only authenticated organization members can invoke these RPCs.
revoke all on function public.create_client_company(uuid,text,text,text,text,text,text,text,text,text,text,text) from public, anon;
grant execute on function public.create_client_company(uuid,text,text,text,text,text,text,text,text,text,text,text) to authenticated;
revoke all on function public.create_contract(uuid,uuid,text,text,bigint,bigint,text,date,date,date,text,text) from public, anon;
grant execute on function public.create_contract(uuid,uuid,text,text,bigint,bigint,text,date,date,date,text,text) to authenticated;
revoke all on function public.create_project(uuid,uuid,text,text,text,text,text,date,date,text) from public, anon;
grant execute on function public.create_project(uuid,uuid,text,text,text,text,text,date,date,text) to authenticated;
revoke all on function public.create_vendor(uuid,text,text,text,text,text,text,text,text,text,text,text) from public, anon;
grant execute on function public.create_vendor(uuid,text,text,text,text,text,text,text,text,text,text,text) to authenticated;
revoke all on function public.create_contractor(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text) from public, anon;
grant execute on function public.create_contractor(uuid,text,text,text,text,text,text,text,text,text,text,text,text,text,text) to authenticated;
revoke all on function public.create_contractor_work_order(uuid,uuid,uuid,text,text,bigint,numeric,date,boolean,date,date,text,text,text) from public, anon;
grant execute on function public.create_contractor_work_order(uuid,uuid,uuid,text,text,bigint,numeric,date,boolean,date,date,text,text,text) to authenticated;
revoke all on function public.record_material_purchase(uuid,uuid,jsonb,date,text,text,bigint,text) from public, anon;
grant execute on function public.record_material_purchase(uuid,uuid,jsonb,date,text,text,bigint,text) to authenticated;
revoke all on function public.issue_materials_to_contractor(uuid,uuid,jsonb,date,text,text) from public, anon;
grant execute on function public.issue_materials_to_contractor(uuid,uuid,jsonb,date,text,text) to authenticated;
revoke all on function public.return_contractor_materials(uuid,uuid,jsonb,date,text,text) from public, anon;
grant execute on function public.return_contractor_materials(uuid,uuid,jsonb,date,text,text) to authenticated;
revoke all on function public.record_contractor_advance(uuid,uuid,bigint,date,text,text,text) from public, anon;
grant execute on function public.record_contractor_advance(uuid,uuid,bigint,date,text,text,text) to authenticated;
revoke all on function public.reconcile_contractor_materials(uuid,uuid,jsonb) from public, anon;
grant execute on function public.reconcile_contractor_materials(uuid,uuid,jsonb) to authenticated;
revoke all on function public.create_contractor_settlement(uuid,uuid,text,date,bigint,bigint,text) from public, anon;
grant execute on function public.create_contractor_settlement(uuid,uuid,text,date,bigint,bigint,text) to authenticated;
revoke all on function public.approve_contractor_settlement(uuid,uuid) from public, anon;
grant execute on function public.approve_contractor_settlement(uuid,uuid) to authenticated;
revoke all on function public.record_contractor_settlement_payment(uuid,uuid,bigint,date,text,text,text) from public, anon;
grant execute on function public.record_contractor_settlement_payment(uuid,uuid,bigint,date,text,text,text) to authenticated;

insert into public.app_schema_version(version) values (14) on conflict (version) do nothing;

commit;
