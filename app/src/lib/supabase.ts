import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { getCurrent, onOpenUrl } from '@tauri-apps/plugin-deep-link';
import type { SupabaseConfig } from './config';
import { closeTrackedLoginSession } from './sessionTracking';

let client: SupabaseClient | null = null;
let activeConfig: SupabaseConfig | null = null;
let deepLinkStarted = false;
const AUTH_DEEP_LINK_PREFIX = 'materialmanagement://auth/callback';
const LAST_AUTH_DEEP_LINK_KEY = 'mms.lastAuthDeepLink';

function isAuthDeepLink(value: string): boolean {
  return value === AUTH_DEEP_LINK_PREFIX || value.startsWith(`${AUTH_DEEP_LINK_PREFIX}?`) || value.startsWith(`${AUTH_DEEP_LINK_PREFIX}#`);
}

async function processAuthDeepLink(url: string, supabase: SupabaseClient): Promise<void> {
  if (!isAuthDeepLink(url)) return;

  // Tauri can expose the same startup URL again when the webview is reloaded.
  // Ignore the exact callback once it has already been consumed successfully.
  if (sessionStorage.getItem(LAST_AUTH_DEEP_LINK_KEY) === url) return;

  try {
    const parsed = new URL(url);
    const query = new URLSearchParams(parsed.search);
    const hash = new URLSearchParams(parsed.hash.replace(/^#/, ''));
    const errorDescription = hash.get('error_description') ?? query.get('error_description');

    if (errorDescription) {
      console.error('Supabase authentication callback failed:', errorDescription);
      return;
    }

    const accessToken = hash.get('access_token');
    const refreshToken = hash.get('refresh_token');
    const code = query.get('code');

    if (code) {
      const { error } = await supabase.auth.exchangeCodeForSession(code);
      if (error) throw error;
    } else if (accessToken && refreshToken) {
      const { error } = await supabase.auth.setSession({
        access_token: accessToken,
        refresh_token: refreshToken,
      });
      if (error) throw error;
    } else {
      console.error('Supabase authentication callback did not contain a usable session.');
      return;
    }

    sessionStorage.setItem(LAST_AUTH_DEEP_LINK_KEY, url);
    window.location.reload();
  } catch (error) {
    console.error('Could not complete Supabase authentication callback:', error);
  }
}

function startDeepLinkHandling(supabase: SupabaseClient): void {
  if (deepLinkStarted) return;
  deepLinkStarted = true;

  // getCurrent handles the case where Windows launched a new app instance from
  // the confirmation link. onOpenUrl handles a link opened while the app is running.
  void getCurrent()
    .then((urls) => {
      if (urls?.[0]) void processAuthDeepLink(urls[0], supabase);
    })
    .catch(() => {
      // The normal browser/Vite build does not have the Tauri deep-link runtime.
    });

  void onOpenUrl((urls) => {
    if (urls?.[0]) void processAuthDeepLink(urls[0], supabase);
  }).catch(() => {
    // The normal browser/Vite build does not have the Tauri deep-link runtime.
  });
}

export function getSupabaseClient(config: SupabaseConfig): SupabaseClient {
  if (
    client &&
    activeConfig?.url === config.url &&
    activeConfig.publishableKey === config.publishableKey
  ) {
    startDeepLinkHandling(client);
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
  startDeepLinkHandling(client);
  return client;
}

export function resetSupabaseClient(): void {
  void closeTrackedLoginSession('connection_changed');
  client = null;
  activeConfig = null;
  deepLinkStarted = false;
}
