-- Allow a replacement contractor settlement after a previous settlement is cancelled.
-- A work order may have at most one non-cancelled settlement at a time.
-- Existing settlement rows are preserved; this migration never deletes financial history.

begin;

-- Fail safely rather than silently altering data if an unexpected duplicate exists.
do $$
begin
  if exists (
    select 1
    from public.contractor_settlements
    where status <> 'cancelled'
    group by work_order_id
    having count(*) > 1
  ) then
    raise exception 'cannot_apply_0016_duplicate_active_contractor_settlements';
  end if;
end
$$;

alter table public.contractor_settlements
  drop constraint if exists contractor_settlements_work_order_id_key;

create unique index if not exists idx_contractor_settlements_one_active_per_work_order
  on public.contractor_settlements (work_order_id)
  where status <> 'cancelled';

insert into public.app_schema_version(version)
values (16)
on conflict (version) do nothing;

commit;
