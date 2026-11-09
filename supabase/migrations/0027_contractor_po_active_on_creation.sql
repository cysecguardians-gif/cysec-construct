-- Make newly created contractor purchase orders active immediately.
-- This matches the current UI workflow: material issue and advances are
-- available as soon as the PO is created. The legacy status default remains
-- unchanged for direct/legacy inserts that do not use this RPC.

begin;

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
  if not public.is_org_member(p_organization_id) then
    raise exception 'organization_membership_required';
  end if;
  if nullif(trim(p_po_number),'') is null then
    raise exception 'po_number_required';
  end if;

  select revised_value_paise into v_contract_value
  from public.contracts
  where id=p_contract_id and organization_id=p_organization_id
  for share;
  if not found then
    raise exception 'contract_not_found';
  end if;

  if p_project_id is not null and not exists (
    select 1 from public.projects
    where id=p_project_id
      and organization_id=p_organization_id
      and contract_id=p_contract_id
  ) then
    raise exception 'project_does_not_belong_to_contract';
  end if;

  if not exists (
    select 1 from public.contractors
    where id=p_contractor_id
      and organization_id=p_organization_id
      and is_active
  ) then
    raise exception 'active_contractor_not_found';
  end if;

  if p_payment_basis='fixed' then
    if p_fixed_amount_paise is null or p_fixed_amount_paise < 0 then
      raise exception 'valid_fixed_amount_required';
    end if;
    v_base := null;
    v_agreed := p_fixed_amount_paise;
  elsif p_payment_basis='percentage' then
    if p_percentage_rate is null or p_percentage_rate <= 0 or p_percentage_rate > 100 then
      raise exception 'valid_percentage_required';
    end if;
    v_base := v_contract_value;
    v_agreed := round(v_base * p_percentage_rate / 100.0)::bigint;
  else
    raise exception 'invalid_payment_basis';
  end if;

  insert into public.contractor_work_orders(
    organization_id,po_number,contract_id,project_id,contractor_id,po_date,
    work_description,payment_basis,fixed_amount_paise,percentage_rate,
    percentage_base_value_paise,agreed_work_amount_paise,start_date,
    expected_completion_date,status,created_by
  ) values (
    p_organization_id,trim(p_po_number),p_contract_id,p_project_id,p_contractor_id,
    coalesce(p_po_date,current_date),p_work_description,p_payment_basis,
    case when p_payment_basis='fixed' then p_fixed_amount_paise end,
    case when p_payment_basis='percentage' then p_percentage_rate end,
    v_base,v_agreed,p_start_date,p_expected_completion_date,'active',auth.uid()
  ) returning id into v_id;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (
    p_organization_id,auth.uid(),'contractor_work_order_created',
    'contractor_work_order',v_id,
    jsonb_build_object(
      'po_number',trim(p_po_number),
      'payment_basis',p_payment_basis,
      'percentage_base_value_paise',v_base,
      'agreed_work_amount_paise',v_agreed,
      'status','active'
    )
  );

  return v_id;
end;
$$;

commit;
