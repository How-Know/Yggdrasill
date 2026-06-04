import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const port = process.env.PB_API_PORT || '8787';
const STYLE = 'answer-xelatex-v10-rightsheet-asset-driven';

const { data: docs } = await supa.from('pb_documents').select('academy_id');
const academies = [...new Set((docs || []).map((d) => d.academy_id))];

for (const academyId of academies) {
  const { data, error } = await supa
    .from('answer_render_assets')
    .select('source_id, render_error, answer_kind')
    .eq('academy_id', academyId)
    .eq('source_kind', 'pb_question')
    .eq('style_version', STYLE)
    .neq('render_error', '');
  if (error) { console.error('query err', error.message); continue; }
  const ids = [...new Set((data || []).map((r) => r.source_id))];
  console.log(`academy ${academyId}: failed rows=${data?.length || 0}, unique source_ids=${ids.length}`);
  if (ids.length === 0) continue;
  for (const r of (data || []).slice(0, 20)) {
    console.log('  fail:', r.source_id, r.answer_kind, JSON.stringify(r.render_error).slice(0, 160));
  }

  // 재시도 (force)
  const res = await fetch(`http://127.0.0.1:${port}/answers/render-assets/backfill`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ academy_id: academyId, source_kind: 'pb_question', source_ids: ids, force: true }),
  });
  const j = await res.json();
  console.log('  retry result:', JSON.stringify(j.render_assets || j));
}
console.log('RETRY DONE');
