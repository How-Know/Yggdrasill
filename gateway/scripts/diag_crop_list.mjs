// 특정 범위의 crop 을 문항 연결 여부까지 함께 본다 (읽기 전용).
//
// 사용: node scripts/diag_crop_list.mjs <book_id> <grade> <sub_key> <from> <to>
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const [bookId, gradeLabel, subKey, from, to] = process.argv.slice(2);
if (!bookId || !gradeLabel || !subKey) {
  throw new Error('book_id, grade_label, sub_key 는 필수입니다');
}

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

let query = supabase
  .from('textbook_problem_crops')
  .select(
    'sub_key,sub_index,raw_page,problem_number,section,item_name,' +
      'pb_question_uid,updated_at',
  )
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .eq('sub_key', subKey);
if (from) query = query.gte('raw_page', Number(from));
if (to) query = query.lte('raw_page', Number(to));
const { data, error } = await query.order('raw_page').order('problem_number');
if (error) throw new Error(error.message);

for (const c of data ?? []) {
  console.log(
    `p${String(c.raw_page).padEnd(3)} ${c.sub_key}#${c.sub_index} ` +
      `${String(c.problem_number).padEnd(10)} ${String(c.item_name || '').padEnd(14)} ` +
      `${c.pb_question_uid ? '문항연결' : '연결없음'} ${c.updated_at.slice(5, 19)}`,
  );
}
console.log(`총 ${(data ?? []).length}건`);
