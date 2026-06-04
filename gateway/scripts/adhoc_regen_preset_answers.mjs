import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const presetId = process.argv[2] || '50bec19e-54c1-490b-a018-96ca88fc006d';
const port = process.env.PB_API_PORT || '8787';

const { data: preset, error } = await supa
  .from('pb_export_presets')
  .select('id, academy_id, display_name, selected_question_ids')
  .eq('id', presetId)
  .single();

if (error || !preset) {
  console.error('preset not found', error?.message);
  process.exit(1);
}

const ids = Array.isArray(preset.selected_question_ids) ? preset.selected_question_ids : [];
console.log(`preset: ${preset.display_name} | questions: ${ids.length}`);

const res = await fetch(`http://127.0.0.1:${port}/answers/render-assets/backfill`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({
    academy_id: preset.academy_id,
    source_kind: 'pb_question',
    source_ids: ids,
    limit: 200,
    force: true,
  }),
});

const json = await res.json();
console.log('backfill status:', res.status);
console.log(JSON.stringify(json, null, 2));
