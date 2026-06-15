// Pre-warms the gateway-side disk cache of large migrated solution PDFs so the
// first grader click never pays the ~minute cold-download cost. Hits
// /textbook/pdf/page for one page per migrated sol link, which forces the
// gateway to download + cache the original once.
//
// Usage: node gateway/scripts/adhoc_warm_solution_pages.mjs

import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
const gw = process.env.PB_GATEWAY_URL || 'http://localhost:8787';
const apiKey = process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '';
if (!url || !key) {
  console.error('missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY');
  process.exit(1);
}
const supa = createClient(url, key, { auth: { persistSession: false } });

// Optional: pass specific link ids to warm first/only,
//   e.g. node adhoc_warm_solution_pages.mjs 1040 1186
const onlyIds = process.argv.slice(2).map((s) => Number(s)).filter(Boolean);

const { data: rows, error } = await supa
  .from('resource_file_links')
  .select('id, grade, migration_status')
  .eq('migration_status', 'migrated');
if (error) throw error;

let sol = (rows || []).filter((r) =>
  String(r.grade || '').toLowerCase().includes('sol'),
);
if (onlyIds.length > 0) {
  sol = sol.filter((r) => onlyIds.includes(Number(r.id)));
}
console.log(`migrated 해설(sol) 책: ${sol.length}`);

for (const r of sol) {
  const started = Date.now();
  const uri = `${gw}/textbook/pdf/page?link_id=${r.id}&page=1`;
  try {
    const res = await fetch(uri, { headers: { 'x-api-key': apiKey } });
    const body = await res.json().catch(() => ({}));
    const secs = ((Date.now() - started) / 1000).toFixed(1);
    console.log(
      `  link=${r.id} grade="${r.grade}" -> ${res.status} ${body.ok ? 'ok' : body.error || ''} (${secs}s)`,
    );
  } catch (e) {
    const secs = ((Date.now() - started) / 1000).toFixed(1);
    console.log(`  link=${r.id} grade="${r.grade}" -> ERROR ${e?.message || e} (${secs}s)`);
  }
}
console.log('done');
process.exit(0);
