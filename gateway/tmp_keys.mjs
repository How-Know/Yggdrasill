// 임시: 문항 행에 출처 구분이 어떻게 저장돼 있는지 본다(읽기 전용).
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const ids = ['c3ea76bb-a3b9-4cce-9629-c5d7f8364a26', '4e6909f7-3028-4d54-b317-74cd412a1904'];
for (const id of ids) {
  const { data: q } = await supa.from('pb_questions').select('*').eq('id', id).maybeSingle();
  if (!q) continue;
  console.log(`열: ${Object.keys(q).join(', ')}`);
  console.log(`source_type_code=${q.source_type_code} | meta.textbook_scope=${JSON.stringify(q.meta?.textbook_scope || null).slice(0, 120)} | meta.textbook_crop_page=${q.meta?.textbook_crop_page ?? null}`);
  const { data: d } = await supa.from('pb_documents').select('source_type_code, classification_detail').eq('id', q.document_id).maybeSingle();
  console.log(`문서: source_type_code=${d?.source_type_code} | detail keys=${Object.keys(d?.classification_detail || {}).join(',')}`);
}
