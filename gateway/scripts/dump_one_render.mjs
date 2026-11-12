import 'dotenv/config';
import { writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: assets, error } = await supa
  .from('question_render_assets')
  .select('crop_id,renderer_version,storage_path,rendered_at')
  .eq('crop_id', process.argv[2])
  .order('rendered_at', { ascending: false });
if (error) throw new Error(error.message);
if (!process.argv[2]) {
  const { data: sample, error: sampleError } = await supa
    .from('question_render_assets')
    .select('crop_id,renderer_version')
    .eq('renderer_version', 'pb_render_v4_colontext_12:student-single-v5')
    .limit(1);
  if (sampleError) throw new Error(sampleError.message);
  console.log(JSON.stringify(sample));
  process.exit(0);
}
console.log(JSON.stringify(assets, null, 2));
for (const row of assets || []) {
  const { data: file, error: dlError } = await supa.storage
    .from('question-renders')
    .download(row.storage_path);
  if (dlError) throw new Error(dlError.message);
  const name = row.renderer_version.replace(/[^\w.-]+/g, '_') + '.pdf';
  writeFileSync(name, Buffer.from(await file.arrayBuffer()));
  console.log('wrote', name, row.renderer_version);
}
