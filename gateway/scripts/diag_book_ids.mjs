// grade_label 이 같은 교재가 여럿일 때 book_id 와 시리즈를 구분해 본다.
//
// 사용: node scripts/diag_book_ids.mjs <grade_label>
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const gradeLabel = String(process.argv[2] || '1-1').trim();

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data, error } = await supabase
  .from('textbook_metadata')
  .select('book_id,grade_label,payload')
  .eq('grade_label', gradeLabel);
if (error) throw new Error(error.message);

for (const row of data ?? []) {
  console.log(
    `${row.book_id} · series=${row.payload?.series ?? '?'} · ` +
      `${row.payload?.book_name ?? row.payload?.name ?? ''}`,
  );
}
