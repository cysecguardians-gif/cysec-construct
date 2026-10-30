begin;

-- ============================================================
-- Login/session tracking
-- ============================================================

create or replace function public.start_login_session(p_organization_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not public.is_org_member(p_organization_id) then
    raise exception 'You are not an active member of this organization';
  end if;

  -- End stale open sessions for this user in this organization before starting a new one.
  update public.login_sessions
     set logout_at = now(),
         ended_reason = 'replaced_by_new_login'
   where organization_id = p_organization_id
     and user_id = auth.uid()
     and logout_at is null;

  insert into public.login_sessions (organization_id, user_id, login_at, last_seen_at)
  values (p_organization_id, auth.uid(), now(), now())
  returning id into v_session_id;

  return v_session_id;
end;
$$;

grant execute on function public.start_login_session(uuid) to authenticated;

create or replace function public.touch_login_session(p_session_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return false;
  end if;

  update public.login_sessions
     set last_seen_at = now()
   where id = p_session_id
     and user_id = auth.uid()
     and logout_at is null;

  return found;
end;
$$;

grant execute on function public.touch_login_session(uuid) to authenticated;

create or replace function public.end_login_session(p_session_id uuid, p_reason text default 'logout')
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return false;
  end if;

  update public.login_sessions
     set logout_at = now(),
         ended_reason = coalesce(nullif(trim(p_reason), ''), 'logout'),
         last_seen_at = greatest(last_seen_at, now())
   where id = p_session_id
     and user_id = auth.uid()
     and logout_at is null;

  return found;
end;
$$;

grant execute on function public.end_login_session(uuid, text) to authenticated;

-- Users may only see their own session history; Admins may see the organization's sessions.
drop policy if exists login_sessions_select on public.login_sessions;
create policy login_sessions_select
on public.login_sessions
for select
to authenticated
using (
  user_id = auth.uid()
  or public.is_org_admin(organization_id)
);

drop policy if exists login_sessions_insert on public.login_sessions;
create policy login_sessions_insert
on public.login_sessions
for insert
to authenticated
with check (user_id = auth.uid() and public.is_org_member(organization_id));

drop policy if exists login_sessions_update on public.login_sessions;
create policy login_sessions_update
on public.login_sessions
for update
to authenticated
using (user_id = auth.uid() or public.is_org_admin(organization_id))
with check (user_id = auth.uid() or public.is_org_admin(organization_id));

create index if not exists idx_login_sessions_org_active
  on public.login_sessions(organization_id, logout_at)
  where logout_at is null;

create index if not exists idx_login_sessions_user_date
  on public.login_sessions(user_id, login_at desc);

commit;
