import type { SupabaseClient } from '@supabase/supabase-js';

let trackedClient: SupabaseClient | null = null;
let trackedSessionId: string | null = null;

export async function startLoginSession(supabase: SupabaseClient, organizationId: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('start_login_session', {
    p_organization_id: organizationId,
  });

  if (error) {
    console.error('Could not start login session:', error);
    return null;
  }

  const sessionId = typeof data === 'string' ? data : null;
  if (sessionId) {
    trackedClient = supabase;
    trackedSessionId = sessionId;
  }
  return sessionId;
}

export async function touchLoginSession(supabase: SupabaseClient, sessionId: string): Promise<boolean> {
  const { error } = await supabase.rpc('touch_login_session', {
    p_session_id: sessionId,
  });

  if (error) {
    console.error('Could not update login session heartbeat:', error);
    return false;
  }

  return true;
}

export async function endLoginSession(
  supabase: SupabaseClient,
  sessionId: string,
  reason = 'logout',
): Promise<boolean> {
  const { error } = await supabase.rpc('end_login_session', {
    p_session_id: sessionId,
    p_reason: reason,
  });

  if (error) {
    console.error('Could not end login session:', error);
    return false;
  }

  if (trackedSessionId === sessionId) {
    trackedClient = null;
    trackedSessionId = null;
  }

  return true;
}

export async function closeTrackedLoginSession(reason = 'session_cleanup'): Promise<boolean> {
  const client = trackedClient;
  const sessionId = trackedSessionId;
  trackedClient = null;
  trackedSessionId = null;

  if (!client || !sessionId) return true;
  return endLoginSession(client, sessionId, reason);
}
