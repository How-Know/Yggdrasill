import { corsHeaders } from '../_shared/cors.ts';
import { createUserClient, createAdminClient } from '../_shared/supabase.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: corsHeaders });

  const userClient = createUserClient(req);
  const { data: userData } = await userClient.auth.getUser();
  if (!userData?.user) return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  const url = new URL(req.url);
  const filters_hash = (url.searchParams.get('filters_hash') ?? '').trim();
  const limit = Math.min(50, Math.max(1, Number(url.searchParams.get('limit') ?? 20)));

  const admin = createAdminClient();
  let q = admin.from('trait_report_runs').select('*').order('created_at', { ascending: false }).limit(limit);
  if (filters_hash) q = q.eq('filters_hash', filters_hash);
  const { data, error } = await q;
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  return new Response(JSON.stringify({ runs: data ?? [] }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
});

