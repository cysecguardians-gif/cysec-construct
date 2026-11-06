-- CySec Construct
-- Ensure legacy contract tables contain the date columns used by the app.
-- CREATE TABLE IF NOT EXISTS does not add columns to an existing table.

begin;

alter table public.contracts
  add column if not exists contract_date date,
  add column if not exists start_date date,
  add column if not exists expected_completion_date date,
  add column if not exists actual_completion_date date;

insert into public.app_schema_version(version)
values (28)
on conflict (version) do nothing;

commit;
