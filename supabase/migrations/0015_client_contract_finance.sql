-- Client-side tender finance operations.
-- Apply after 0014_construction_transactional_operations.sql.

begin;

create or replace function public.create_client_bill(
  p_organization_id uuid, p_contract_id uuid, p_bill_number text,
  p_amount_claimed_paise bigint, p_bill_date date default current_date,
  p_period_from date default null, p_period_to date default null,
  p_status text default 'submitted', p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if not exists(select 1 from public.contracts where id=p_contract_id and organization_id=p_organization_id and status not in ('cancelled')) then raise exception 'contract_not_found_or_cancelled'; end if;
  if nullif(trim(p_bill_number),'') is null or p_amount_claimed_paise<=0 then raise exception 'bill_number_and_positive_amount_required'; end if;
  if p_status not in ('draft','submitted','approved') then raise exception 'invalid_initial_bill_status'; end if;
  if p_period_from is not null and p_period_to is not null and p_period_to<p_period_from then raise exception 'invalid_bill_period'; end if;
  insert into public.client_bills(organization_id,contract_id,bill_number,bill_date,period_from,period_to,amount_claimed_paise,status,notes,created_by)
  values(p_organization_id,p_contract_id,trim(p_bill_number),p_bill_date,p_period_from,p_period_to,p_amount_claimed_paise,p_status,p_notes,auth.uid())
  returning id into v_id;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'client_bill_created','client_bill',v_id,jsonb_build_object('contract_id',p_contract_id,'bill_number',p_bill_number,'amount_claimed_paise',p_amount_claimed_paise));
  return v_id;
end $$;

create or replace function public.record_client_receipt(
  p_organization_id uuid, p_contract_id uuid, p_amount_paise bigint,
  p_bill_id uuid default null, p_receipt_date date default current_date,
  p_payment_method text default 'other', p_reference_number text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_bill public.client_bills%rowtype; v_received bigint; v_deducted bigint;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if not exists(select 1 from public.contracts where id=p_contract_id and organization_id=p_organization_id) then raise exception 'contract_not_found'; end if;
  if p_amount_paise<=0 then raise exception 'receipt_amount_must_be_positive'; end if;
  if p_payment_method not in ('cash','upi','bank_transfer','cheque','card','other') then raise exception 'invalid_payment_method'; end if;
  if p_bill_id is not null then
    select * into v_bill from public.client_bills where id=p_bill_id and contract_id=p_contract_id and organization_id=p_organization_id for update;
    if not found or v_bill.status in ('draft','rejected') then raise exception 'bill_not_receivable'; end if;
    select coalesce(sum(amount_paise),0)::bigint into v_received from public.client_receipts where bill_id=p_bill_id;
    select coalesce(sum(amount_paise),0)::bigint into v_deducted from public.client_deductions where bill_id=p_bill_id and deduction_type<>'retention';
    if v_received+v_deducted+p_amount_paise>v_bill.amount_claimed_paise then raise exception 'receipt_exceeds_bill_balance'; end if;
  end if;
  insert into public.client_receipts(organization_id,contract_id,bill_id,receipt_date,amount_paise,payment_method,reference_number,notes,recorded_by)
  values(p_organization_id,p_contract_id,p_bill_id,p_receipt_date,p_amount_paise,p_payment_method,p_reference_number,p_notes,auth.uid())
  returning id into v_id;
  if p_bill_id is not null then
    select coalesce(sum(amount_paise),0)::bigint into v_received from public.client_receipts where bill_id=p_bill_id;
    select coalesce(sum(amount_paise),0)::bigint into v_deducted from public.client_deductions where bill_id=p_bill_id and deduction_type<>'retention';
    update public.client_bills set status=case when v_received+v_deducted>=v_bill.amount_claimed_paise then 'paid' when v_received+v_deducted>0 then 'partially_paid' else status end where id=p_bill_id;
  end if;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'client_receipt_recorded','client_receipt',v_id,jsonb_build_object('contract_id',p_contract_id,'bill_id',p_bill_id,'amount_paise',p_amount_paise));
  return v_id;
end $$;

create or replace function public.record_client_deduction(
  p_organization_id uuid, p_contract_id uuid, p_deduction_type text, p_amount_paise bigint,
  p_bill_id uuid default null, p_deduction_date date default current_date,
  p_is_recoverable boolean default false, p_reference_number text default null, p_notes text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid; v_bill public.client_bills%rowtype; v_received bigint; v_deducted bigint;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if not exists(select 1 from public.contracts where id=p_contract_id and organization_id=p_organization_id) then raise exception 'contract_not_found'; end if;
  if p_amount_paise<=0 then raise exception 'deduction_amount_must_be_positive'; end if;
  if p_deduction_type not in ('tds','retention','security_deposit','penalty','material_recovery','other') then raise exception 'invalid_deduction_type'; end if;
  if p_bill_id is not null then
    select * into v_bill from public.client_bills where id=p_bill_id and contract_id=p_contract_id and organization_id=p_organization_id for update;
    if not found or v_bill.status in ('draft','rejected') then raise exception 'bill_not_available_for_deduction'; end if;
    select coalesce(sum(amount_paise),0)::bigint into v_received from public.client_receipts where bill_id=p_bill_id;
    select coalesce(sum(amount_paise),0)::bigint into v_deducted from public.client_deductions where bill_id=p_bill_id and deduction_type<>'retention';
    if p_deduction_type<>'retention' and v_received+v_deducted+p_amount_paise>v_bill.amount_claimed_paise then raise exception 'deduction_exceeds_bill_balance'; end if;
  end if;
  insert into public.client_deductions(organization_id,contract_id,bill_id,deduction_date,deduction_type,amount_paise,is_recoverable,reference_number,notes,recorded_by)
  values(p_organization_id,p_contract_id,p_bill_id,p_deduction_date,p_deduction_type,p_amount_paise,p_is_recoverable,p_reference_number,p_notes,auth.uid())
  returning id into v_id;
  if p_bill_id is not null then
    select coalesce(sum(amount_paise),0)::bigint into v_received from public.client_receipts where bill_id=p_bill_id;
    select coalesce(sum(amount_paise),0)::bigint into v_deducted from public.client_deductions where bill_id=p_bill_id and deduction_type<>'retention';
    update public.client_bills set status=case when v_received+v_deducted>=v_bill.amount_claimed_paise then 'paid' when v_received+v_deducted>0 then 'partially_paid' else status end where id=p_bill_id;
  end if;
  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values(p_organization_id,auth.uid(),'client_deduction_recorded','client_deduction',v_id,jsonb_build_object('contract_id',p_contract_id,'bill_id',p_bill_id,'deduction_type',p_deduction_type,'amount_paise',p_amount_paise));
  return v_id;
end $$;

create or replace view public.client_bill_finance_summary
with (security_invoker = true) as
select
  b.id as bill_id,
  b.organization_id,
  b.contract_id,
  b.bill_number,
  b.bill_date,
  b.amount_claimed_paise,
  coalesce(r.received_paise,0)::bigint as received_paise,
  coalesce(d.deducted_paise,0)::bigint as deducted_paise,
  coalesce(d.retention_paise,0)::bigint as retention_paise,
  greatest(b.amount_claimed_paise-coalesce(r.received_paise,0)-coalesce(d.non_retention_paise,0),0)::bigint as pending_receivable_paise,
  b.status
from public.client_bills b
left join (
  select bill_id,sum(amount_paise)::bigint as received_paise
  from public.client_receipts where bill_id is not null group by bill_id
) r on r.bill_id=b.id
left join (
  select bill_id,sum(amount_paise)::bigint as deducted_paise,
    (sum(amount_paise) filter (where deduction_type='retention'))::bigint as retention_paise,
    (sum(amount_paise) filter (where deduction_type<>'retention'))::bigint as non_retention_paise
  from public.client_deductions where bill_id is not null group by bill_id
) d on d.bill_id=b.id;

revoke all on function public.create_client_bill(uuid,uuid,text,bigint,date,date,date,text,text) from public, anon;
grant execute on function public.create_client_bill(uuid,uuid,text,bigint,date,date,date,text,text) to authenticated;
revoke all on function public.record_client_receipt(uuid,uuid,bigint,uuid,date,text,text,text) from public, anon;
grant execute on function public.record_client_receipt(uuid,uuid,bigint,uuid,date,text,text,text) to authenticated;
revoke all on function public.record_client_deduction(uuid,uuid,text,bigint,uuid,date,boolean,text,text) from public, anon;
grant execute on function public.record_client_deduction(uuid,uuid,text,bigint,uuid,date,boolean,text,text) to authenticated;

insert into public.app_schema_version(version) values (15) on conflict (version) do nothing;

commit;
