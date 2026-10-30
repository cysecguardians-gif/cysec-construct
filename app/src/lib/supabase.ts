import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import type { SupabaseConfig } from './config';
import { closeTrackedLoginSession } from './sessionTracking';

let client: SupabaseClient | null = null;
let activeConfig: SupabaseConfig | null = null;

export function getSupabaseClient(config: SupabaseConfig): SupabaseClient {
  if (
    client &&
    activeConfig?.url === config.url &&
    activeConfig.publishableKey === config.publishableKey
  ) {
    return client;
  }

  client = createClient(config.url, config.publishableKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
    },
  });
  activeConfig = config;
  return client;
}

export function resetSupabaseClient(): void {
  void closeTrackedLoginSession('connection_changed');
  client = null;
  activeConfig = null;
}
