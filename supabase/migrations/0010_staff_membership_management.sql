-- Material Management System
-- Admin-only staff membership provisioning.
-- Creates the application membership for an Auth user that has already been created.
-- Apply after 0009_app_status_security.sql.
-- Safe to apply more than once.

begin;

create or replace function public.add_staff_member(
  p_organization_id uuid,
  p_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_membership_id uuid;
begin
  if auth.uid() is null then
    raise exception 'authentication_required';
  end if;

  if not public.is_org_admin(p_organization_id) then
    raise exception 'Only organization admins can add employees';
  end if;

  if not exists (select 1 from auth.users where id = p_user_id) then
    raise exception 'Auth user not found';
  end if;

  insert into public.profiles(id)
  values (p_user_id)
  on conflict (id) do nothing;

  insert into public.organization_members(organization_id, user_id, role, is_active)
  values (p_organization_id, p_user_id, 'staff', true)
  on conflict (organization_id, user_id)
  do update set is_active = true
  returning id into v_membership_id;

  insert into public.audit_log(
    organization_id,
    user_id,
    action,
    entity_type,
    entity_id,
    details
  )
  values (
    p_organization_id,
    auth.uid(),
    'staff_member_added',
    'organization_member',
    v_membership_id,
    jsonb_build_object('user_id', p_user_id, 'role', 'staff')
  );

  return v_membership_id;
end;
$$;

grant execute on function public.add_staff_member(uuid, uuid) to authenticated;
revoke execute on function public.add_staff_member(uuid, uuid) from anon;

commit;
