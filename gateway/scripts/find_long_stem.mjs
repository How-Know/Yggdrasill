import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const BOOK_ID = 'c3ae29ad-4d99-4078-8381-00357074d151';
const ACADEMY_ID = '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677';

const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: crops, error } = await supa
  .from('textbook_problem_crops')
  .select('id,pb_question_uid,problem_number')
  .eq('academy_id', ACADEMY_ID)
  .eq('book_id', BOOK_ID)
  .eq('grade_label', '1-1')
  .eq('big_order', 1)
  .eq('is_set_header', false)
  .not('pb_question_uid', 'is', null);
if (error) throw new Error(error.message);

const byUid = new Map(crops.map((row) => [row.pb_question_uid, row]));
const uids = [...byUid.keys()];
const hits = [];
for (let i = 0; i < uids.length; i += 40) {
  const slice = uids.slice(i, i + 40);
  const { data, error: qError } = await supa
    .from('pb_questions')
    .select('question_uid,stem')
    .eq('academy_id', ACADEMY_ID)
    .in('question_uid', slice);
  if (qError) throw new Error(qError.message);
  for (const row of data || []) {
    const text = String(row.stem || '').replace(/\s+/g, ' ');
    hits.push({
      crop: byUid.get(row.question_uid).id,
      n: byUid.get(row.question_uid).problem_number,
      len: text.length,
      head: text.slice(0, 80),
    });
  }
}
hits.sort((a, b) => b.len - a.len);
console.log(JSON.stringify(hits.slice(0, 8), null, 2));
