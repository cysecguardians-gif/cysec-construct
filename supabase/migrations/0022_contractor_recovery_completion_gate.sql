-- CySec Construct
-- Keep outgoing settlement payments and incoming contractor recovery independent.
-- A work order is settled only after both the payable and recovery balances are clear.

begin;

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
  v_work_order_id uuid;
  v_recovery_total bigint;
  v_recovered bigint;
begin
  if not public.is_org_member(p_organization_id) then raise exception 'organization_membership_required'; end if;
  if p_amount_paise<=0 then raise exception 'payment_amount_must_be_positive'; end if;
  select final_payable_paise, work_order_id, contractor_recovery_paise
    into v_total, v_work_order_id, v_recovery_total
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
    select coalesce(sum(amount_paise),0)::bigint into v_recovered
    from public.contractor_recovery_payments
    where organization_id=p_organization_id and settlement_id=p_settlement_id;

    if v_recovery_total <= v_recovered then
      update public.contractor_work_orders
      set status='settled'
      where id=v_work_order_id and organization_id=p_organization_id;
    end if;
  end if;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (p_organization_id,auth.uid(),'contractor_settlement_payment_recorded','contractor_settlement_payment',v_id,
    jsonb_build_object('settlement_id',p_settlement_id,'amount_paise',p_amount_paise));
  return v_id;
end;
$$;

grant execute on function public.record_contractor_settlement_payment(uuid,uuid,date,bigint,public.payment_method,text,text) to authenticated;
revoke execute on function public.record_contractor_settlement_payment(uuid,uuid,date,bigint,public.payment_method,text,text) from anon;

-- Upgrade already-approved/paid settlements without changing their money values.
-- Only reopen work orders that were closed solely by outgoing payment while
-- the recovery ledger still has an outstanding balance.
update public.contractor_work_orders wo
set status = 'under_closure'
from public.contractor_settlements st
where st.organization_id = wo.organization_id
  and st.work_order_id = wo.id
  and st.status = 'paid'
  and st.contractor_recovery_paise > coalesce((
    select sum(rp.amount_paise)
    from public.contractor_recovery_payments rp
    where rp.organization_id = st.organization_id
      and rp.settlement_id = st.id
  ), 0)
  and wo.status = 'settled';

insert into public.app_schema_version(version) values (22)
on conflict (version) do nothing;

commit;
