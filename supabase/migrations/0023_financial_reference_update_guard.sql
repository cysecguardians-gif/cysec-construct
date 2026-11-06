-- CySec Construct
-- Extend financial reference protection to updates, and exclude the current row
-- when checking its own ledger. Advisory locking still serializes concurrent
-- writes for the same organisation/reference pair.

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

  -- Existing historical duplicates must not block unrelated edits. Recheck
  -- uniqueness only when the tenant or normalized reference actually changes.
  if tg_op = 'UPDATE'
     and new.organization_id is not distinct from old.organization_id
     and lower(btrim(coalesce(new.reference_number, ''))) is not distinct from
         lower(btrim(coalesce(old.reference_number, ''))) then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(new.organization_id::text || ':' || v_reference, 0)
  );

  select exists (
    select 1 from public.client_receipts x
    where x.organization_id = new.organization_id
      and lower(btrim(x.reference_number)) = v_reference
      and (tg_table_name <> 'client_receipts' or x.id is distinct from new.id)
    union all
    select 1 from public.contractor_advances x
    where x.organization_id = new.organization_id
      and lower(btrim(x.reference_number)) = v_reference
      and (tg_table_name <> 'contractor_advances' or x.id is distinct from new.id)
    union all
    select 1 from public.contractor_settlement_payments x
    where x.organization_id = new.organization_id
      and lower(btrim(x.reference_number)) = v_reference
      and (tg_table_name <> 'contractor_settlement_payments' or x.id is distinct from new.id)
    union all
    select 1 from public.contractor_recovery_payments x
    where x.organization_id = new.organization_id
      and lower(btrim(x.reference_number)) = v_reference
      and (tg_table_name <> 'contractor_recovery_payments' or x.id is distinct from new.id)
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
before insert or update on public.client_receipts
for each row execute function public.guard_construction_financial_reference();

drop trigger if exists trg_contractor_advances_unique_financial_reference on public.contractor_advances;
create trigger trg_contractor_advances_unique_financial_reference
before insert or update on public.contractor_advances
for each row execute function public.guard_construction_financial_reference();

drop trigger if exists trg_contractor_settlement_payments_unique_financial_reference on public.contractor_settlement_payments;
create trigger trg_contractor_settlement_payments_unique_financial_reference
before insert or update on public.contractor_settlement_payments
for each row execute function public.guard_construction_financial_reference();

drop trigger if exists trg_contractor_recovery_payments_unique_financial_reference on public.contractor_recovery_payments;
create trigger trg_contractor_recovery_payments_unique_financial_reference
before insert or update on public.contractor_recovery_payments
for each row execute function public.guard_construction_financial_reference();

insert into public.app_schema_version(version) values (23)
on conflict (version) do nothing;

commit;
