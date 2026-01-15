import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.49.1';

export function getSupabaseUrl(): string {
  const url = Deno.env.get('SUPABASE_URL');
  if (!url) throw new Error('Missing SUPABASE_URL');
  return url;
}

export function getAnonKey(): string {
  const key = Deno.env.get('SUPABASE_ANON_KEY');
  if (!key) throw new Error('Missing SUPABASE_ANON_KEY');
  return key;
}

export function getServiceRoleKey(): string {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key) throw new Error('Missing SUPABASE_SERVICE_ROLE_KEY');
  return key;
}

export function createAdminClient() {
  return createClient(getSupabaseUrl(), getServiceRoleKey(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

export function createUserClient(req: Request) {
  const authHeader = req.headers.get('Authorization') ?? '';
  return createClient(getSupabaseUrl(), getAnonKey(), {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

