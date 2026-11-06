-- CySec Construct
-- Treat a zero contractor payable as paid independently of recovery.
-- The settlement status tracks the outgoing payable; recovery_status tracks
-- the incoming recovery. Work-order closure still requires both to clear.

begin;

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
  v_recovery_status text;
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

  -- The payable status represents only the amount owed to the contractor.
  -- A zero payable is already clear even if a recovery remains outstanding.
  v_new_status := case
    when v_final_payable = 0 then 'paid'
    else 'approved'
  end;
  v_recovery_status := case
    when v_recovery > 0 then 'outstanding'
    else 'not_due'
  end;

  update public.contractor_settlements
  set status = v_new_status,
      recovery_status = v_recovery_status,
      approved_by = auth.uid()
  where id = p_settlement_id
    and organization_id = p_organization_id;

  -- Never close here merely because the payable is zero. Recovery may still
  -- be outstanding; record_contractor_recovery_payment closes after both
  -- sides are clear.
  if v_new_status = 'paid' and v_recovery = 0 then
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
      'recovery_status', v_recovery_status,
      'final_payable_paise', v_final_payable,
      'contractor_recovery_paise', v_recovery
    )
  );
end;
$$;

grant execute on function public.approve_contractor_settlement(uuid,uuid) to authenticated;
revoke execute on function public.approve_contractor_settlement(uuid,uuid) from anon;

insert into public.app_schema_version(version) values (25)
on conflict (version) do nothing;

commit;
