import { corsHeaders } from '../_shared/cors.ts';
import { createUserClient, createAdminClient } from '../_shared/supabase.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'GET') return new Response('Method not allowed', { status: 405, headers: corsHeaders });

  const userClient = createUserClient(req);
  const { data: userData } = await userClient.auth.getUser();
  if (!userData?.user) return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  const url = new URL(req.url);
  const run_id = (url.searchParams.get('id') ?? '').trim();
  if (!run_id) return new Response(JSON.stringify({ error: 'missing id' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  const admin = createAdminClient();
  const { data: run, error } = await admin.from('trait_report_runs').select('*').eq('id', run_id).maybeSingle();
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  if (!run) return new Response(JSON.stringify({ error: 'not found' }), { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  const expSecs = 3600;
  let jsonUrl: string | null = null;
  let htmlUrl: string | null = null;
  if (run.report_json_path) {
    const { data } = await admin.storage.from('reports').createSignedUrl(run.report_json_path, expSecs);
    jsonUrl = (data as any)?.signedUrl ?? null;
  }
  if (run.report_html_path) {
    const { data } = await admin.storage.from('reports').createSignedUrl(run.report_html_path, expSecs);
    htmlUrl = (data as any)?.signedUrl ?? null;
  }

  return new Response(JSON.stringify({ run, signed: { json: jsonUrl, html: htmlUrl, expires_in: expSecs } }), { headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
});

