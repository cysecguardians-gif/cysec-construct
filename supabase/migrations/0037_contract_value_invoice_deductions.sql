-- CySec Construct: contract-value client invoices and itemized deductions
-- Apply manually in Supabase SQL Editor after migration 0036.

begin;

-- Preserve the existing deduction ledger and extend it for invoice-specific
-- percentage calculations. Existing rows remain valid and unchanged.
alter table public.client_deductions
  add column if not exists percentage_rate numeric(7,4),
  add column if not exists calculation_base_paise bigint,
  add column if not exists calculated_amount_paise bigint;

alter table public.client_deductions
  drop constraint if exists client_deductions_category_check;

alter table public.client_deductions
  add constraint client_deductions_category_check
  check (category in (
    'tds','retention','security_deposit','penalty','material_recovery',
    'labour_cess','liquidated_damages','gst_hold','cpbg_pbg','other'
  ));

-- A dedicated invoice-bound RPC stores the calculation inputs and final
-- editable amount together. It avoids direct writes to the protected ledger.
create or replace function public.record_invoice_deduction(
  p_organization_id uuid,
  p_invoice_id uuid,
  p_deduction_date date,
  p_category text,
  p_amount_paise bigint,
  p_description text default null,
  p_percentage_rate numeric default null,
  p_calculation_base_paise bigint default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_invoice public.invoices%rowtype;
  v_id uuid;
begin
  if not public.is_org_member(p_organization_id) then
    raise exception 'organization_membership_required';
  end if;
  if p_amount_paise <= 0 then
    raise exception 'deduction_amount_must_be_positive';
  end if;
  if p_category not in (
    'tds','retention','security_deposit','penalty','material_recovery',
    'labour_cess','liquidated_damages','gst_hold','cpbg_pbg','other'
  ) then
    raise exception 'invalid_deduction_category';
  end if;
  if p_percentage_rate is not null and
     (p_percentage_rate < 0 or p_percentage_rate > 100) then
    raise exception 'invalid_deduction_percentage';
  end if;

  select * into v_invoice
  from public.invoices
  where id=p_invoice_id and organization_id=p_organization_id
    and contract_id is not null and status='issued';
  if not found or v_invoice.client_bill_id is null then
    raise exception 'issued_contract_invoice_not_found';
  end if;

  insert into public.client_deductions(
    organization_id,contract_id,bill_id,deduction_date,category,
    amount_paise,description,recoverable,created_by,
    percentage_rate,calculation_base_paise,calculated_amount_paise
  ) values (
    p_organization_id,v_invoice.contract_id,v_invoice.client_bill_id,
    coalesce(p_deduction_date,current_date),p_category,p_amount_paise,
    p_description,false,auth.uid(),p_percentage_rate,
    p_calculation_base_paise,
    case when p_percentage_rate is not null
      then round(p_calculation_base_paise*p_percentage_rate/100.0)::bigint
      else null end
  ) returning id into v_id;

  insert into public.audit_log(
    organization_id,user_id,action,entity_type,entity_id,details
  ) values (
    p_organization_id,auth.uid(),'invoice_deduction_recorded',
    'client_deduction',v_id,
    jsonb_build_object(
      'invoice_id',p_invoice_id,'category',p_category,
      'amount_paise',p_amount_paise,'percentage_rate',p_percentage_rate,
      'calculation_base_paise',p_calculation_base_paise
    )
  );
  return v_id;
end;
$$;

grant execute on function public.record_invoice_deduction(
  uuid,uuid,date,text,bigint,text,numeric,bigint
) to authenticated;
revoke execute on function public.record_invoice_deduction(
  uuid,uuid,date,text,bigint,text,numeric,bigint
) from anon;

insert into public.app_schema_version(version)
values (37) on conflict (version) do nothing;

commit;
