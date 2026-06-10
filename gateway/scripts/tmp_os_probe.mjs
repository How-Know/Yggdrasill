import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const { data: d1 } = await supa.from('pb_documents').select('*').eq('id', '6940ec38-3342-498d-85ab-dd34c171b9c8').single();
console.log('DOC COLS', Object.keys(d1 || {}).join(','));
console.log('source bucket/path:', d1?.source_storage_bucket, '|', d1?.source_storage_path);
process.exit(0);
const docs = [];
for (const d of docs || []) {
  if (!/오성중|중2|중\s*2/.test(String(d.source_filename))) continue;
  const { data: rows } = await supa.from('pb_questions').select('*').eq('document_id', d.id).order('source_order');
  const want = ['1', '11'];
  const qs = (rows || []).filter((q) => want.includes(String(q.question_number).trim()));
  for (const q of qs) {
    console.log('\n==== DOC', d.id, d.source_filename, '| Q', q.question_number, 'uid', q.question_uid);
    console.log('  type', q.question_type);
    console.log('  STEM:\n', String(q.stem || ''));
    console.log('  EQUATIONS:', JSON.stringify(q.equations));
  }
}
