import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import { PDFDocument } from 'pdf-lib';

const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data, error } = await supa
  .from('question_render_assets')
  .select('storage_path,renderer_version,page_count,rendered_at,crop_id')
  .eq('renderer_version', 'pb_render_v4_colontext_12:student-single-v5')
  .order('rendered_at', { ascending: false })
  .limit(1);
if (error) throw new Error(error.message);
const row = data?.[0];
if (!row) {
  console.log('no v5 asset yet');
  process.exit(0);
}
const { data: file, error: dlError } = await supa.storage
  .from('question-renders')
  .download(row.storage_path);
if (dlError) throw new Error(dlError.message);
const bytes = new Uint8Array(await file.arrayBuffer());
const doc = await PDFDocument.load(bytes);
const page = doc.getPage(0);
const size = page.getSize();
console.log(JSON.stringify({
  crop_id: row.crop_id,
  version: row.renderer_version,
  pages: doc.getPageCount(),
  widthPt: Math.round(size.width * 10) / 10,
  heightPt: Math.round(size.height * 10) / 10,
  widthMm: Math.round((size.width * 25.4) / 72 * 10) / 10,
}));
