import { createClient } from '@supabase/supabase-js';

export function getSupabaseConfig(): { url: string; anonKey: string; ok: boolean; source: string } {
  const envUrl = (import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? '';
  const envAnon = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined) ?? '';
  if (envUrl && envAnon) return { url: envUrl, anonKey: envAnon, ok: true, source: 'vite_env' };

  const w = window as any;
  const injectedUrl = (w?.__YGG_SUPABASE_URL as string | undefined) ?? '';
  const injectedAnon = (w?.__YGG_SUPABASE_ANON_KEY as string | undefined) ?? '';
  if (injectedUrl && injectedAnon) return { url: injectedUrl, anonKey: injectedAnon, ok: true, source: 'injected_window' };

  // fallback: query string (앱에서 주입/디버깅 용)
  try {
    const q = new URLSearchParams(window.location.search);
    const qUrl = q.get('sbUrl') ?? '';
    const qAnon = q.get('sbAnon') ?? '';
    if (qUrl && qAnon) return { url: qUrl, anonKey: qAnon, ok: true, source: 'query' };
  } catch {}

  return { url: '', anonKey: '', ok: false, source: 'missing' };
}

const cfg = getSupabaseConfig();
if (!cfg.ok) {
  console.warn('Supabase env vars are missing (VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY).');
}

// ✅ config 미설정 시에도 앱 전체가 하얗게 죽지 않도록 dummy로 생성(실제 호출은 실패)
export const supabase = createClient(cfg.url || 'http://localhost:54321', cfg.anonKey || 'anon', {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
  },
});
