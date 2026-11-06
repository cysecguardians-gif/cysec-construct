-- CySec Construct
-- Allow contractor recovery collection after the outgoing settlement reaches paid.
-- The recovery and payable balances are independent and either may clear first.

begin;

create or replace function public.record_contractor_recovery_payment(
  p_organization_id uuid,
  p_settlement_id uuid,
  p_recovery_date date,
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
  v_work_order_id uuid;
  v_recovery_total bigint;
  v_recovered bigint;
  v_id uuid;
  v_status text;
  v_final_payable bigint;
  v_paid bigint;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'administrator_required_to_record_contractor_recovery';
  end if;
  if p_amount_paise is null or p_amount_paise <= 0 then
    raise exception 'recovery_amount_must_be_positive';
  end if;

  select work_order_id, contractor_recovery_paise, status, final_payable_paise
    into v_work_order_id, v_recovery_total, v_status, v_final_payable
  from public.contractor_settlements
  where id = p_settlement_id
    and organization_id = p_organization_id
  for update;

  if not found then
    raise exception 'contractor_settlement_not_found';
  end if;
  -- Recovery collection remains valid before or after the payable is cleared.
  if v_status not in ('approved','partially_paid','paid') then
    raise exception 'approved_settlement_required_for_recovery';
  end if;
  if v_recovery_total <= 0 then
    raise exception 'settlement_has_no_contractor_recovery';
  end if;

  select coalesce(sum(amount_paise),0)::bigint
    into v_recovered
  from public.contractor_recovery_payments
  where organization_id = p_organization_id
    and settlement_id = p_settlement_id;

  if p_amount_paise > v_recovery_total - v_recovered then
    raise exception 'recovery_payment_exceeds_outstanding_balance';
  end if;

  insert into public.contractor_recovery_payments(
    organization_id, settlement_id, recovery_date, amount_paise,
    payment_method, reference_number, notes, received_by
  ) values (
    p_organization_id, p_settlement_id, coalesce(p_recovery_date,current_date),
    p_amount_paise, coalesce(p_payment_method,'bank_transfer'),
    nullif(trim(p_reference_number),''), nullif(trim(p_notes),''), auth.uid()
  ) returning id into v_id;

  v_recovered := v_recovered + p_amount_paise;
  update public.contractor_settlements
  set recovery_status = case
    when v_recovered = v_recovery_total then 'recovered'
    else 'partially_recovered'
  end
  where id = p_settlement_id
    and organization_id = p_organization_id;

  -- Close only after both the outgoing payable and incoming recovery clear.
  if v_recovered = v_recovery_total and v_status = 'paid' then
    select coalesce(sum(amount_paise),0)::bigint
      into v_paid
    from public.contractor_settlement_payments
    where organization_id = p_organization_id
      and settlement_id = p_settlement_id;

    if v_paid >= v_final_payable then
      update public.contractor_work_orders
      set status = 'settled'
      where id = v_work_order_id
        and organization_id = p_organization_id
        and status = 'under_closure';
    end if;
  end if;

  insert into public.audit_log(
    organization_id, user_id, action, entity_type, entity_id, details
  ) values (
    p_organization_id, auth.uid(), 'contractor_recovery_payment_recorded',
    'contractor_recovery_payment', v_id,
    jsonb_build_object(
      'settlement_id', p_settlement_id,
      'amount_paise', p_amount_paise,
      'total_recovered_paise', v_recovered,
      'recovery_total_paise', v_recovery_total
    )
  );

  return v_id;
end;
$$;

grant execute on function public.record_contractor_recovery_payment(uuid,uuid,date,bigint,public.payment_method,text,text) to authenticated;
revoke execute on function public.record_contractor_recovery_payment(uuid,uuid,date,bigint,public.payment_method,text,text) from anon;

insert into public.app_schema_version(version) values (24)
on conflict (version) do nothing;

commit;
