// 소단원 페이지 범위의 crop 중 정답/해설 좌표가 없는 것을 찾는다 (읽기 전용).
//
// 단원 다이얼로그의 "n/3 완료" 칩과 같은 기준으로 센다. 즉 세트 헤더를 뺀
// 모든 crop 이 정답 1건·해설 좌표 1건씩 가져야 3/3 이 된다.
//
// 사용: node scripts/diag_stage_gap.mjs <book_id> <grade> <big> <mid> <from> <to>
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const [bookId, gradeLabel, big, mid, from, to] = process.argv.slice(2);
if (!bookId || !gradeLabel || from === undefined || to === undefined) {
  throw new Error('book_id, grade, big, mid, from, to 를 모두 넘겨주세요');
}

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: crops, error } = await supabase
  .from('textbook_problem_crops')
  .select('id,sub_key,sub_index,raw_page,problem_number,item_name,is_set_header')
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .eq('big_order', Number(big))
  .eq('mid_order', Number(mid))
  .gte('raw_page', Number(from))
  .lte('raw_page', Number(to))
  .order('sub_key')
  .order('raw_page');
if (error) throw new Error(error.message);

const targets = (crops ?? []).filter((c) => c.is_set_header !== true);
const ids = targets.map((c) => c.id);

async function idsWithRow(table) {
  const found = new Set();
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    const { data, error: e } = await supabase
      .from(table)
      .select('crop_id')
      .in('crop_id', chunk);
    if (e) throw new Error(`${table}: ${e.message}`);
    for (const row of data ?? []) found.add(row.crop_id);
  }
  return found;
}

const withAnswer = await idsWithRow('textbook_problem_answers');
const withSolution = await idsWithRow('textbook_problem_solution_refs');

console.log(
  `crop ${(crops ?? []).length}건 (세트헤더 제외 ${targets.length}건) · ` +
    `정답 ${withAnswer.size} · 해설좌표 ${withSolution.size}`,
);
for (const c of targets) {
  const miss = [];
  if (!withAnswer.has(c.id)) miss.push('정답없음');
  if (!withSolution.has(c.id)) miss.push('해설좌표없음');
  if (miss.length === 0) continue;
  console.log(
    `  ${c.sub_key}#${c.sub_index} p${c.raw_page} ` +
      `${String(c.problem_number).padEnd(10)} ${String(c.item_name || '').padEnd(14)} ${miss.join(' ')}`,
  );
}
