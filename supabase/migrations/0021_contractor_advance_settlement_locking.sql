-- CySec Construct
-- Serialize contractor advances against settlement preparation so the
-- settlement snapshot cannot omit an advance committed concurrently.

begin;

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
declare
  v_id uuid;
  v_work_order_status text;
begin
  if not public.is_org_member(p_organization_id) then
    raise exception 'organization_membership_required';
  end if;
  if p_amount_paise is null or p_amount_paise <= 0 then
    raise exception 'advance_amount_must_be_positive';
  end if;

  -- Use the same parent-row lock as prepare_contractor_settlement.
  -- Whichever operation obtains it first determines whether this advance
  -- belongs in the settlement snapshot or must be rejected as too late.
  select status
    into v_work_order_status
  from public.contractor_work_orders
  where id = p_work_order_id
    and organization_id = p_organization_id
  for update;

  if not found or v_work_order_status not in ('active', 'work_completed') then
    raise exception 'work_order_not_available_for_advance';
  end if;

  insert into public.contractor_advances(
    organization_id, work_order_id, advance_date, amount_paise,
    payment_method, reference_number, notes, paid_by
  ) values (
    p_organization_id, p_work_order_id, coalesce(p_advance_date, current_date),
    p_amount_paise, coalesce(p_payment_method, 'cash'),
    nullif(btrim(p_reference_number), ''), nullif(btrim(p_notes), ''), auth.uid()
  ) returning id into v_id;

  insert into public.audit_log(
    organization_id, user_id, action, entity_type, entity_id, details
  ) values (
    p_organization_id, auth.uid(), 'contractor_advance_paid',
    'contractor_advance', v_id,
    jsonb_build_object(
      'work_order_id', p_work_order_id,
      'amount_paise', p_amount_paise
    )
  );

  return v_id;
end;
$$;

grant execute on function public.record_contractor_advance(
  uuid, uuid, date, bigint, public.payment_method, text, text
) to authenticated;
revoke execute on function public.record_contractor_advance(
  uuid, uuid, date, bigint, public.payment_method, text, text
) from anon;

insert into public.app_schema_version(version) values (21)
on conflict (version) do nothing;

commit;
