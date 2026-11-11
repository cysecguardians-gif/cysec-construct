-- Track GST Hold release/clearance separately from invoice payment.
-- Apply manually after migration 0037.

begin;

alter table public.client_deductions
  add column if not exists is_cleared boolean not null default false,
  add column if not exists cleared_date date,
  add column if not exists clearance_reference text,
  add column if not exists clearance_notes text;

create index if not exists idx_client_deductions_gst_hold_clearance
  on public.client_deductions(organization_id, category, is_cleared, deduction_date desc);

create or replace function public.set_client_deduction_clearance(
  p_organization_id uuid,
  p_deduction_id uuid,
  p_is_cleared boolean,
  p_cleared_date date default null,
  p_clearance_reference text default null,
  p_clearance_notes text default null
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_category text;
  v_amount bigint;
begin
  if not public.is_org_member(p_organization_id) then
    raise exception 'organization_membership_required';
  end if;

  select category, amount_paise into v_category, v_amount
  from public.client_deductions
  where id=p_deduction_id and organization_id=p_organization_id
  for update;

  if not found then raise exception 'deduction_not_found'; end if;
  if v_category <> 'gst_hold' then raise exception 'only_gst_hold_can_be_cleared_here'; end if;
  if p_is_cleared and p_cleared_date is null then
    raise exception 'clearance_date_required';
  end if;

  update public.client_deductions
  set is_cleared=p_is_cleared,
      cleared_date=case when p_is_cleared then p_cleared_date else null end,
      clearance_reference=case when p_is_cleared then nullif(trim(p_clearance_reference),'') else null end,
      clearance_notes=case when p_is_cleared then nullif(trim(p_clearance_notes),'') else null end
  where id=p_deduction_id and organization_id=p_organization_id;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (
    p_organization_id,auth.uid(),
    case when p_is_cleared then 'gst_hold_cleared' else 'gst_hold_clearance_reversed' end,
    'client_deduction',p_deduction_id,
    jsonb_build_object('amount_paise',v_amount,'cleared_date',p_cleared_date,
      'clearance_reference',p_clearance_reference,'clearance_notes',p_clearance_notes)
  );
end;
$$;

grant execute on function public.set_client_deduction_clearance(uuid,uuid,boolean,date,text,text) to authenticated;
revoke execute on function public.set_client_deduction_clearance(uuid,uuid,boolean,date,text,text) from anon;

insert into public.app_schema_version(version) values (38) on conflict (version) do nothing;

commit;
