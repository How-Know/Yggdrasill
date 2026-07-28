// 런 범위의 crop 이 모두 문항으로 추출됐는지 본다 (읽기 전용).
//
// 사용: node scripts/diag_scope_coverage.mjs <grade_label> [big] [mid]
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const [gradeLabel = '1-1', bigArg, midArg] = process.argv.slice(2);

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

let runQuery = supabase
  .from('textbook_pb_extract_runs')
  .select(
    'book_id,academy_id,grade_label,big_order,mid_order,sub_key,sub_index,' +
      'status,raw_page_from,raw_page_to,pb_document_id',
  )
  .eq('grade_label', gradeLabel);
if (bigArg !== undefined) runQuery = runQuery.eq('big_order', Number(bigArg));
if (midArg !== undefined) runQuery = runQuery.eq('mid_order', Number(midArg));
const { data: runs, error } = await runQuery.order('sub_key');
if (error) throw new Error(error.message);

for (const run of runs ?? []) {
  const { data: crops } = await supabase
    .from('textbook_problem_crops')
    .select('problem_number,is_set_header')
    .eq('academy_id', run.academy_id)
    .eq('book_id', run.book_id)
    .eq('grade_label', run.grade_label)
    .eq('big_order', run.big_order)
    .eq('mid_order', run.mid_order)
    .eq('sub_key', run.sub_key)
    .gte('raw_page', run.raw_page_from)
    .lte('raw_page', run.raw_page_to);
  const expected = (crops ?? [])
    .filter((c) => c.is_set_header !== true)
    .map((c) => String(c.problem_number));
  const { data: questions } = await supabase
    .from('pb_questions')
    .select('question_number')
    .eq('document_id', run.pb_document_id);
  const found = new Set(
    (questions ?? []).map((q) => String(q.question_number).trim()),
  );
  const missing = expected.filter((n) => !found.has(n));
  console.log(
    `${run.sub_key}#${run.sub_index} p${run.raw_page_from}-${run.raw_page_to} ` +
      `[${run.status}] crop ${expected.length} → 문항 ${found.size}` +
      (missing.length > 0 ? ` · 누락 ${missing.join(',')}` : ' · 누락 없음'),
  );
}
