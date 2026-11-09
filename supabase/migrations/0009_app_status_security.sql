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
  -- Database setup verification runs before the first administrator exists.
  -- This endpoint exposes only non-sensitive schema metadata, so it must work
  -- for the anon client as well as authenticated users.
  return jsonb_build_object(
    'ok', true,
    'authenticated', auth.uid() is not null,
    'schema_version', (select max(version) from public.app_schema_version),
    'currency_code', 'INR',
    'locale', 'en-IN'
  );
end;
$$;

revoke execute on function public.get_app_status() from public;
grant execute on function public.get_app_status() to anon, authenticated;

commit;
