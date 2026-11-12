import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const BOOK_ID = 'c3ae29ad-4d99-4078-8381-00357074d151';
const ACADEMY_ID = '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677';
const VERSION = 'pb_render_v4_colontext_12:student-single-v5';

const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: crops, error } = await supa
  .from('textbook_problem_crops')
  .select('id')
  .eq('academy_id', ACADEMY_ID)
  .eq('book_id', BOOK_ID)
  .eq('grade_label', '1-1')
  .eq('big_order', 1)
  .eq('is_set_header', false)
  .not('pb_question_uid', 'is', null);
if (error) throw new Error(error.message);
const ids = (crops || []).map((row) => row.id);

let ready = 0;
let errored = 0;
for (let i = 0; i < ids.length; i += 80) {
  const slice = ids.slice(i, i + 80);
  const { data, error: assetError } = await supa
    .from('question_render_assets')
    .select('crop_id,render_error,rendered_at')
    .eq('renderer_version', VERSION)
    .in('crop_id', slice);
  if (assetError) throw new Error(assetError.message);
  for (const row of data || []) {
    if (row.rendered_at && !row.render_error) ready += 1;
    else errored += 1;
  }
}
console.log(JSON.stringify({
  renderable: ids.length,
  ready,
  errored,
  missing: ids.length - ready - errored,
}));
