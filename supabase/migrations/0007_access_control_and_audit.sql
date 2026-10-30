-- Material Management System
-- Admin access control, team management and audit helpers.
-- Apply manually in each customer's Supabase SQL Editor after 0006.

begin;

-- ============================================================
-- Current membership
-- ============================================================

create or replace function public.get_current_membership(p_organization_id uuid)
returns table (
  organization_id uuid,
  user_id uuid,
  role public.app_role,
  is_active boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select om.organization_id, om.user_id, om.role, om.is_active
  from public.organization_members om
  where om.organization_id = p_organization_id
    and om.user_id = auth.uid()
  limit 1;
$$;

grant execute on function public.get_current_membership(uuid) to authenticated;

-- ============================================================
-- Admin team list
-- Email is read from auth.users inside a security-definer function;
-- the desktop client never receives broad access to auth.users.
-- ============================================================

create or replace function public.admin_list_members(p_organization_id uuid)
returns table (
  membership_id uuid,
  user_id uuid,
  email text,
  full_name text,
  role public.app_role,
  is_active boolean,
  joined_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'Only organization admins can manage users';
  end if;

  return query
  select
    om.id,
    om.user_id,
    au.email::text,
    p.full_name,
    om.role,
    om.is_active,
    om.created_at
  from public.organization_members om
  join auth.users au on au.id = om.user_id
  left join public.profiles p on p.id = om.user_id
  where om.organization_id = p_organization_id
  order by om.created_at asc;
end;
$$;

grant execute on function public.admin_list_members(uuid) to authenticated;

-- ============================================================
-- Admin role / active-state changes
-- ============================================================

create or replace function public.set_member_role(
  p_organization_id uuid,
  p_user_id uuid,
  p_role public.app_role
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_role public.app_role;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'Only organization admins can change roles';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'You cannot change your own role';
  end if;

  select role into v_old_role
  from public.organization_members
  where organization_id = p_organization_id and user_id = p_user_id
  for update;

  if v_old_role is null then
    raise exception 'Organization member not found';
  end if;

  update public.organization_members
  set role = p_role
  where organization_id = p_organization_id and user_id = p_user_id;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  select p_organization_id, auth.uid(), 'member_role_changed', 'organization_member', om.id,
         jsonb_build_object('user_id',p_user_id,'old_role',v_old_role,'new_role',p_role)
  from public.organization_members om
  where om.organization_id = p_organization_id and om.user_id = p_user_id;
end;
$$;

grant execute on function public.set_member_role(uuid,uuid,public.app_role) to authenticated;

create or replace function public.set_member_active(
  p_organization_id uuid,
  p_user_id uuid,
  p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_active boolean;
  v_member_id uuid;
begin
  if not public.is_org_admin(p_organization_id) then
    raise exception 'Only organization admins can change member access';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'You cannot deactivate your own account';
  end if;

  select id, is_active into v_member_id, v_old_active
  from public.organization_members
  where organization_id = p_organization_id and user_id = p_user_id
  for update;

  if v_member_id is null then
    raise exception 'Organization member not found';
  end if;

  update public.organization_members
  set is_active = p_is_active
  where id = v_member_id;

  insert into public.audit_log(organization_id,user_id,action,entity_type,entity_id,details)
  values (
    p_organization_id,
    auth.uid(),
    case when p_is_active then 'member_activated' else 'member_deactivated' end,
    'organization_member',
    v_member_id,
    jsonb_build_object('user_id',p_user_id,'old_active',v_old_active,'new_active',p_is_active)
  );
end;
$$;

grant execute on function public.set_member_active(uuid,uuid,boolean) to authenticated;

-- Audit entries are application history, not editable business data.
-- Keep direct inserts admin-only; existing transactional security-definer functions
-- can continue to write audit rows because they run with their owner's privileges.
drop policy if exists audit_log_member_insert on public.audit_log;
create policy audit_log_admin_insert on public.audit_log
for insert to authenticated
with check (public.is_org_admin(organization_id));

drop policy if exists audit_log_member_update on public.audit_log;
create policy audit_log_no_update on public.audit_log
for update to authenticated
using (false)
with check (false);

drop policy if exists audit_log_member_delete on public.audit_log;
create policy audit_log_no_delete on public.audit_log
for delete to authenticated
using (false);

create index if not exists idx_org_members_active on public.organization_members(organization_id, is_active, role);

commit;
