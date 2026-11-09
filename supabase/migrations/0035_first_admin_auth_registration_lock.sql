-- Prevent first-administrator registration from reopening after the first
-- Supabase Auth account has been created but before organization bootstrap.
-- The first Auth account is the only account eligible for initial bootstrap;
-- bootstrap_organization remains the database-enforced, serialized admin claim.

begin;

create or replace function public.get_setup_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, auth
as $$
declare
  v_admin_exists boolean;
  v_schema_version integer;
begin
  -- A Supabase Auth account may exist before organization_members is populated.
  -- Treat that state as first-admin registration already claimed so the client
  -- routes the signed-in account to organization setup instead of signup again.
  select (
    exists (
      select 1
      from public.organization_members
      where role = 'admin'
        and is_active = true
    )
    or exists (
      select 1
      from auth.users
    )
  ) into v_admin_exists;

  select coalesce(max(version), 0)
    into v_schema_version
    from public.app_schema_version;

  return jsonb_build_object(
    'initialized', v_admin_exists,
    'admin_exists', v_admin_exists,
    'schema_version', v_schema_version
  );
end;
$$;

revoke execute on function public.get_setup_status() from public;
grant execute on function public.get_setup_status() to anon, authenticated;

insert into public.app_schema_version(version)
values (35)
on conflict (version) do nothing;

commit;
