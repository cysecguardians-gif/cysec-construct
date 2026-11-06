-- CySec Construct
-- Record contractor recovery collections separately from payments made to
-- contractors. Keep the settlement payable status semantically accurate.

begin;

alter table public.contractor_settlements
  add column if not exists recovery_status text not null default 'not_due'
  check (recovery_status in ('not_due','outstanding','partially_recovered','recovered'));

update public.contractor_settlements
set recovery_status = case
  when contractor_recovery_paise <= 0 then 'not_due'
  else 'outstanding'
end
where recovery_status = 'not_due'
  and contractor_recovery_paise > 0;

create table if not exists public.contractor_recovery_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  settlement_id uuid not null,
  recovery_date date not null default current_date,
  amount_paise bigint not null check (amount_paise > 0),
  payment_method public.payment_method not null default 'bank_transfer',
  reference_number text,
  notes text,
  received_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (organization_id, settlement_id)
    references public.contractor_settlements(organization_id, id) on delete restrict
);

create index if not exists idx_contractor_recovery_payments_settlement
  on public.contractor_recovery_payments(organization_id, settlement_id, recovery_date desc);

-- A bank/UPI reference identifies one incoming transaction within a tenant.
-- Keep it optional for cash receipts, but reject duplicate non-empty references.
create unique index if not exists uq_contractor_recovery_reference
  on public.contractor_recovery_payments(organization_id, lower(reference_number))
  where reference_number is not null and btrim(reference_number) <> '';

alter table public.contractor_recovery_payments enable row level security;
drop policy if exists contractor_recovery_payments_member_select on public.contractor_recovery_payments;
create policy contractor_recovery_payments_member_select
  on public.contractor_recovery_payments
  for select to authenticated
  using (public.is_org_member(organization_id));
revoke all on public.contractor_recovery_payments from anon, authenticated;
grant select on public.contractor_recovery_payments to authenticated;


create or replace function public.approve_contractor_settlement(
  p_organization_id uuid,
  p_settlement_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $
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

  v_new_status := case
    when v_final_payable = 0 and v_recovery = 0 then 'paid'
    else 'approved'
  end;
  v_recovery_status := case when v_recovery > 0 then 'outstanding' else 'not_due' end;

  update public.contractor_settlements
  set status = v_new_status,
      recovery_status = v_recovery_status,
      approved_by = auth.uid()
  where id = p_settlement_id
    and organization_id = p_organization_id;

  if v_new_status = 'paid' then
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
$;

grant execute on function public.approve_contractor_settlement(uuid,uuid) to authenticated;
revoke execute on function public.approve_contractor_settlement(uuid,uuid) from anon;

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
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'administrator_required_to_record_contractor_recovery';
  end if;
  if p_amount_paise is null or p_amount_paise <= 0 then
    raise exception 'recovery_amount_must_be_positive';
  end if;

  select work_order_id, contractor_recovery_paise, status
    into v_work_order_id, v_recovery_total, v_status
  from public.contractor_settlements
  where id = p_settlement_id
    and organization_id = p_organization_id
  for update;

  if not found then
    raise exception 'contractor_settlement_not_found';
  end if;
  if v_status not in ('approved','partially_paid') then
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

  if v_recovered = v_recovery_total then
    update public.contractor_work_orders
    set status = 'settled'
    where id = v_work_order_id
      and organization_id = p_organization_id
      and status = 'under_closure';
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

insert into public.app_schema_version(version) values (19)
on conflict (version) do nothing;

commit;
