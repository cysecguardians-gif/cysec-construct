-- CySec Construct
-- Prevent one bank/UPI/cheque reference from being recorded against multiple
-- financial ledger entries within the same customer organisation.
-- A shared advisory lock serializes concurrent inserts across all ledgers.

begin;

create or replace function public.guard_construction_financial_reference()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reference text;
  v_duplicate boolean;
begin
  v_reference := nullif(lower(btrim(new.reference_number)), '');
  if v_reference is null then
    new.reference_number := null;
    return new;
  end if;

  new.reference_number := btrim(new.reference_number);

  perform pg_advisory_xact_lock(
    hashtextextended(new.organization_id::text || ':' || v_reference, 0)
  );

  select exists (
    select 1 from public.client_receipts x
    where x.organization_id = new.organization_id
      and lower(btrim(x.reference_number)) = v_reference
    union all
    select 1 from public.contractor_advances x
    where x.organization_id = new.organization_id
      and lower(btrim(x.reference_number)) = v_reference
    union all
    select 1 from public.contractor_settlement_payments x
    where x.organization_id = new.organization_id
      and lower(btrim(x.reference_number)) = v_reference
    union all
    select 1 from public.contractor_recovery_payments x
    where x.organization_id = new.organization_id
      and lower(btrim(x.reference_number)) = v_reference
  ) into v_duplicate;

  if v_duplicate then
    raise exception 'financial_reference_already_recorded'
      using errcode = '23505',
            detail = 'This bank, UPI or cheque reference is already recorded in this organisation.';
  end if;

  return new;
end;
$$;

revoke all on function public.guard_construction_financial_reference() from public, anon, authenticated;

drop trigger if exists trg_client_receipts_unique_financial_reference on public.client_receipts;
create trigger trg_client_receipts_unique_financial_reference
before insert on public.client_receipts
for each row execute function public.guard_construction_financial_reference();

drop trigger if exists trg_contractor_advances_unique_financial_reference on public.contractor_advances;
create trigger trg_contractor_advances_unique_financial_reference
before insert on public.contractor_advances
for each row execute function public.guard_construction_financial_reference();

drop trigger if exists trg_contractor_settlement_payments_unique_financial_reference on public.contractor_settlement_payments;
create trigger trg_contractor_settlement_payments_unique_financial_reference
before insert on public.contractor_settlement_payments
for each row execute function public.guard_construction_financial_reference();

drop trigger if exists trg_contractor_recovery_payments_unique_financial_reference on public.contractor_recovery_payments;
create trigger trg_contractor_recovery_payments_unique_financial_reference
before insert on public.contractor_recovery_payments
for each row execute function public.guard_construction_financial_reference();

insert into public.app_schema_version(version) values (20)
on conflict (version) do nothing;

commit;
