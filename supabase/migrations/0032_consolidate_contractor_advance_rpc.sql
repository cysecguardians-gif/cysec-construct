-- Consolidate the overloaded contractor advance RPC into one canonical
-- signature. The live contractor_advances table requires contractor_id.
-- Preserve the parent-row lock used to coordinate with settlement preparation.

begin;

drop function if exists public.record_contractor_advance(
  uuid, uuid, bigint, date, text, text, text
);

drop function if exists public.record_contractor_advance(
  uuid, uuid, date, bigint, public.payment_method, text, text
);

create function public.record_contractor_advance(
  p_organization_id uuid,
  p_work_order_id uuid,
  p_advance_date date,
  p_amount_paise bigint,
  p_payment_method text default 'cash',
  p_reference_number text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id uuid;
  v_contractor_id uuid;
  v_work_order_status text;
begin
  if not public.is_org_member(p_organization_id) then
    raise exception 'organization_membership_required';
  end if;

  if p_amount_paise is null or p_amount_paise <= 0 then
    raise exception 'advance_amount_must_be_positive';
  end if;

  if coalesce(p_payment_method, 'cash') not in
     ('cash', 'upi', 'bank_transfer', 'cheque', 'card', 'other') then
    raise exception 'invalid_payment_method';
  end if;

  -- Lock the parent PO so advance recording remains serialized with
  -- settlement preparation and cannot arrive after the settlement snapshot.
  select contractor_id, status
    into v_contractor_id, v_work_order_status
  from public.contractor_work_orders
  where id = p_work_order_id
    and organization_id = p_organization_id
  for update;

  if not found or v_work_order_status not in ('active', 'work_completed') then
    raise exception 'work_order_not_available_for_advance';
  end if;

  insert into public.contractor_advances(
    organization_id, work_order_id, contractor_id, advance_date,
    amount_paise, payment_method, reference_number, notes, paid_by
  )
  values (
    p_organization_id, p_work_order_id, v_contractor_id,
    coalesce(p_advance_date, current_date), p_amount_paise,
    coalesce(p_payment_method, 'cash'),
    nullif(btrim(p_reference_number), ''),
    nullif(btrim(p_notes), ''),
    auth.uid()
  )
  returning id into v_id;

  insert into public.audit_log(
    organization_id, user_id, action, entity_type, entity_id, details
  )
  values (
    p_organization_id, auth.uid(), 'contractor_advance_paid',
    'contractor_advance', v_id,
    jsonb_build_object(
      'work_order_id', p_work_order_id,
      'contractor_id', v_contractor_id,
      'amount_paise', p_amount_paise,
      'payment_method', coalesce(p_payment_method, 'cash')
    )
  );

  return v_id;
end;
$function$;

commit;
