import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const docId = process.argv[2] || 'c2e37ceb-164f-4d0f-96f6-f63e2112ea74';
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const { data } = await supa
  .from('pb_questions')
  .select('question_number, stem')
  .eq('document_id', docId);
data.sort((a, b) => Number(a.question_number || 0) - Number(b.question_number || 0));
const target = new Set(['10', '11', '13']);
for (const q of data) {
  if (!target.has(String(q.question_number))) continue;
  console.log(`===== Q${q.question_number} =====`);
  console.log(JSON.stringify(q.stem).slice(0, 800));
  console.log();
}
