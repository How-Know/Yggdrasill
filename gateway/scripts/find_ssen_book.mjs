import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const bookIds = [
  '257fc65a-1fa9-46a1-9d9a-2897be25b109',
  'c3ae29ad-4d99-4078-8381-00357074d151',
];

for (const bookId of bookIds) {
  const { data, error } = await supa
    .from('textbook_problem_crops')
    .select('grade_label,big_order,big_name,is_set_header,pb_question_uid')
    .eq('book_id', bookId)
    .eq('grade_label', '1-1')
    .eq('big_order', 1);
  if (error) {
    console.error(bookId, error.message);
    continue;
  }
  const rows = data || [];
  const names = new Set(rows.map((row) => row.big_name));
  const renderable = rows.filter(
    (row) => !row.is_set_header && row.pb_question_uid,
  );
  console.log(
    bookId,
    'rows',
    rows.length,
    'names',
    [...names].join(','),
    'renderable',
    renderable.length,
    'headers',
    rows.filter((row) => row.is_set_header).length,
    'unlinked',
    rows.filter((row) => !row.pb_question_uid).length,
  );
}
