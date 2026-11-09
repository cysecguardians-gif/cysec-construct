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
  -- Verification is intentionally authenticated. The first-run application
  -- flow installs the schema, creates/signs in the first administrator, and
  -- only then invokes this function. Do not expose schema metadata anonymously.
  if auth.uid() is null then
    raise exception using
      errcode = 'P0001',
      message = 'authentication_required';
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
revoke execute on function public.get_app_status() from anon;
grant execute on function public.get_app_status() to authenticated;

commit;
