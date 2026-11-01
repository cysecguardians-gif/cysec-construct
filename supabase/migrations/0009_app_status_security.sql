-- Material Management System
-- Secure schema-version verification for the desktop application.
-- Apply after 0008_login_session_tracking.sql.
-- This migration is safe to apply to an existing v8 database.

begin;

create table if not exists public.app_schema_version (
  version integer primary key,
  applied_at timestamptz not null default now()
);

insert into public.app_schema_version(version)
values (9)
on conflict (version) do nothing;

create or replace function public.get_app_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication_required';
  end if;

  return jsonb_build_object(
    'ok', true,
    'authenticated', true,
    'schema_version', (select max(version) from public.app_schema_version),
    'currency_code', 'INR',
    'locale', 'en-IN'
  );
end;
$$;

revoke execute on function public.get_app_status() from public;
grant execute on function public.get_app_status() to authenticated;

commit;
