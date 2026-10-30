export type SupabaseConfig = {
  url: string;
  publishableKey: string;
};

const STORAGE_KEY = 'mms.supabase.config';

export function loadSupabaseConfig(): SupabaseConfig | null {
  const raw = localStorage.getItem(STORAGE_KEY);
  if (!raw) return null;

  try {
    const parsed = JSON.parse(raw) as Partial<SupabaseConfig>;
    if (typeof parsed.url !== 'string' || typeof parsed.publishableKey !== 'string') {
      return null;
    }
    return { url: parsed.url, publishableKey: parsed.publishableKey };
  } catch {
    return null;
  }
}

export function saveSupabaseConfig(config: SupabaseConfig): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
}

export function clearSupabaseConfig(): void {
  localStorage.removeItem(STORAGE_KEY);
}

export function normalizeSupabaseUrl(value: string): string {
  return value.trim().replace(/\/+$/, '');
}
