-- Material Management System
-- Close/approve work orders and protect ledger tables from direct client writes.
-- All operational ledger mutations must use the validated transactional RPCs.

begin;

create or replace function public.complete_contractor_work_order(
  p_organization_id uuid,
  p_work_order_id uuid,
  p_actual_completion_date date default current_date
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  update public.contractor_work_orders
  set status='work_completed',actual_completion_date=coalesce(p_actual_completion_date,current_date)
  where id=p_work_order_id and organization_id=p_organization_id and status='active';
  if not found then raise exception 'active_work_order_not_found'; end if;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'contractor_work_order_completed','contractor_work_order',p_work_order_id,
    jsonb_build_object('actual_completion_date',coalesce(p_actual_completion_date,current_date)));
end;
$$;

create or replace function public.approve_contractor_settlement(
  p_organization_id uuid,
  p_settlement_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_org_admin(p_organization_id) then raise exception 'administrator_required_to_approve_settlement'; end if;
  update public.contractor_settlements
  set status='approved',approved_by=auth.uid()
  where id=p_settlement_id and organization_id=p_organization_id and status='draft';
  if not found then raise exception 'draft_settlement_not_found'; end if;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id)
  values (p_organization_id,auth.uid(),'contractor_settlement_approved','contractor_settlement',p_settlement_id);
end;
$$;

-- Client bill submission.
create or replace function public.record_client_bill(
  p_organization_id uuid,
  p_contract_id uuid,
  p_project_id uuid,
  p_bill_number text,
  p_bill_date date,
  p_amount_paise bigint,
  p_description text default null,
  p_period_from date default null,
  p_period_to date default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if p_amount_paise<=0 or nullif(trim(p_bill_number),'') is null then raise exception 'valid_bill_number_and_amount_required'; end if;
  if p_project_id is not null and not exists(
    select 1 from public.projects where id=p_project_id and organization_id=p_organization_id and contract_id=p_contract_id
  ) then raise exception 'project_does_not_belong_to_contract'; end if;
  insert into public.client_bills(
    organization_id,contract_id,project_id,bill_number,bill_date,amount_paise,
    description,period_from,period_to,status,created_by
  ) values (
    p_organization_id,p_contract_id,p_project_id,trim(p_bill_number),coalesce(p_bill_date,current_date),
    p_amount_paise,p_description,p_period_from,p_period_to,'submitted',auth.uid()
  ) returning id into v_id;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'client_bill_submitted','client_bill',v_id,
    jsonb_build_object('contract_id',p_contract_id,'amount_paise',p_amount_paise));
  return v_id;
end;
$$;

-- Record client receipts. Optional allocations must sum exactly to the receipt
-- amount; empty allocations represent an advance/unallocated receipt.
-- p_allocations: [{bill_id, amount_paise}]
create or replace function public.record_client_receipt(
  p_organization_id uuid,
  p_contract_id uuid,
  p_receipt_number text,
  p_receipt_date date,
  p_amount_paise bigint,
  p_payment_method public.payment_method default 'bank_transfer',
  p_reference_number text default null,
  p_notes text default null,
  p_allocations jsonb default '[]'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_item jsonb;
  v_bill uuid;
  v_alloc bigint;
  v_sum bigint := 0;
  v_bill_amount bigint;
  v_already bigint;
  v_remaining bigint;
  v_due bigint;
  v_allocated bigint;
  v_bill_row record;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if p_amount_paise<=0 then raise exception 'receipt_amount_must_be_positive'; end if;
  if jsonb_typeof(p_allocations)<>'array' then raise exception 'allocations_must_be_array'; end if;

  insert into public.client_receipts(
    organization_id,contract_id,receipt_number,receipt_date,amount_paise,
    payment_method,reference_number,notes,created_by
  ) values (
    p_organization_id,p_contract_id,nullif(trim(p_receipt_number),''),coalesce(p_receipt_date,current_date),
    p_amount_paise,coalesce(p_payment_method,'bank_transfer'),p_reference_number,p_notes,auth.uid()
  ) returning id into v_id;

  for v_item in select value from jsonb_array_elements(p_allocations) loop
    v_bill := (v_item->>'bill_id')::uuid;
    v_alloc := (v_item->>'amount_paise')::bigint;
    if v_alloc<=0 then raise exception 'allocation_must_be_positive'; end if;
    select amount_paise into v_bill_amount from public.client_bills
    where id=v_bill and organization_id=p_organization_id and contract_id=p_contract_id
      and status not in ('draft','rejected','cancelled') for update;
    if not found then raise exception 'bill_not_found_for_contract'; end if;
    select coalesce(sum(a.amount_paise),0) into v_already
    from public.client_receipt_allocations a
    where a.organization_id=p_organization_id and a.bill_id=v_bill;
    if v_already+v_alloc>v_bill_amount then raise exception 'allocation_exceeds_bill_balance'; end if;
    insert into public.client_receipt_allocations(organization_id,receipt_id,bill_id,amount_paise)
    values (p_organization_id,v_id,v_bill,v_alloc);
    v_sum := v_sum+v_alloc;
  end loop;

  -- Default allocation is FIFO across oldest outstanding bills. Any excess
  -- remains an unallocated contract receipt and is still visible as cash received.
  if jsonb_array_length(p_allocations)=0 then
    v_remaining := p_amount_paise;
    for v_bill_row in
      select id,amount_paise
      from public.client_bills
      where organization_id=p_organization_id and contract_id=p_contract_id
        and status not in ('draft','rejected','cancelled')
      order by bill_date,created_at
      for update
    loop
      select coalesce(sum(a.amount_paise),0) into v_already
      from public.client_receipt_allocations a
      where a.organization_id=p_organization_id and a.bill_id=v_bill_row.id;
      v_due := greatest(v_bill_row.amount_paise-v_already,0);
      if v_due>0 and v_remaining>0 then
        v_allocated := least(v_due,v_remaining);
        insert into public.client_receipt_allocations(organization_id,receipt_id,bill_id,amount_paise)
        values (p_organization_id,v_id,v_bill_row.id,v_allocated);
        v_sum := v_sum+v_allocated;
        v_remaining := v_remaining-v_allocated;
      end if;
      exit when v_remaining=0;
    end loop;
  elsif v_sum<>p_amount_paise then
    raise exception 'receipt_allocations_must_equal_receipt_amount';
  end if;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'client_receipt_recorded','client_receipt',v_id,
    jsonb_build_object('contract_id',p_contract_id,'amount_paise',p_amount_paise,'allocated_paise',v_sum,'unallocated_paise',p_amount_paise-v_sum));
  return v_id;
end;
$$;

create or replace function public.record_client_deduction(
  p_organization_id uuid,
  p_contract_id uuid,
  p_bill_id uuid,
  p_deduction_date date,
  p_category text,
  p_amount_paise bigint,
  p_description text default null,
  p_recoverable boolean default false,
  p_reference_number text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if p_amount_paise<=0 then raise exception 'deduction_amount_must_be_positive'; end if;
  if p_bill_id is not null and not exists(
    select 1 from public.client_bills where id=p_bill_id and organization_id=p_organization_id and contract_id=p_contract_id
  ) then raise exception 'bill_does_not_belong_to_contract'; end if;
  insert into public.client_deductions(
    organization_id,contract_id,bill_id,deduction_date,category,amount_paise,
    description,recoverable,reference_number,created_by
  ) values (
    p_organization_id,p_contract_id,p_bill_id,coalesce(p_deduction_date,current_date),
    p_category,p_amount_paise,p_description,coalesce(p_recoverable,false),p_reference_number,auth.uid()
  ) returning id into v_id;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'client_deduction_recorded','client_deduction',v_id,
    jsonb_build_object('contract_id',p_contract_id,'category',p_category,'amount_paise',p_amount_paise));
  return v_id;
end;
$$;

grant execute on function public.complete_contractor_work_order(uuid,uuid,date) to authenticated;
grant execute on function public.approve_contractor_settlement(uuid,uuid) to authenticated;
grant execute on function public.record_client_bill(uuid,uuid,uuid,text,date,bigint,text,date,date) to authenticated;
grant execute on function public.record_client_receipt(uuid,uuid,text,date,bigint,public.payment_method,text,text,jsonb) to authenticated;
grant execute on function public.record_client_deduction(uuid,uuid,uuid,date,text,bigint,text,boolean,text) to authenticated;

revoke execute on function public.complete_contractor_work_order(uuid,uuid,date) from anon;
revoke execute on function public.approve_contractor_settlement(uuid,uuid) from anon;
revoke execute on function public.record_client_bill(uuid,uuid,uuid,text,date,bigint,text,date,date) from anon;
revoke execute on function public.record_client_receipt(uuid,uuid,text,date,bigint,public.payment_method,text,text,jsonb) from anon;
revoke execute on function public.record_client_deduction(uuid,uuid,uuid,date,text,bigint,text,boolean,text) from anon;

-- Sensitive ledgers are read-only to direct PostgREST table writes. Their
-- SECURITY DEFINER functions above enforce organization membership, validate
-- amounts and update related stock/financial records atomically.
do $$
declare t text;
begin
  foreach t in array array[
    'client_bills','client_receipts','client_receipt_allocations','client_deductions',
    'material_purchases','material_purchase_items','material_issues','material_issue_items',
    'material_returns','material_return_items','contractor_advances','material_reconciliations',
    'contractor_settlements','contractor_settlement_payments'
  ] loop
    execute format('drop policy if exists %I on public.%I', t || '_member_all', t);
    execute format('drop policy if exists %I on public.%I', t || '_member_select', t);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.is_org_member(organization_id))',
      t || '_member_select', t
    );
  end loop;
end $$;

-- Existing stock ledger is also append-only through the stock RPCs.
drop policy if exists stock_movements_member_all on public.stock_movements;
drop policy if exists stock_movements_member_select on public.stock_movements;
create policy stock_movements_member_select on public.stock_movements
for select to authenticated using (public.is_org_member(organization_id));

insert into public.app_schema_version(version) values (15) on conflict (version) do nothing;

commit;
