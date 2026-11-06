-- CySec Construct
-- Repair legacy customer databases where material_purchases was created
-- without the status column expected by the vendor-purchase workspace.
-- Existing rows are treated as received because the original purchase flow
-- updated stock atomically when the purchase was recorded.

begin;

alter table public.material_purchases
  add column if not exists status text not null default 'received';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.material_purchases'::regclass
      and conname = 'material_purchases_status_check'
  ) then
    alter table public.material_purchases
      add constraint material_purchases_status_check
      check (status in ('draft', 'received', 'cancelled'));
  end if;
end;
$$;

insert into public.app_schema_version(version)
values (26)
on conflict (version) do nothing;

commit;
