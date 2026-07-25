// (대단원, 중단원, 카테고리) 하나에 런 행이 몇 개인지 본다 (읽기 전용).
// 스테이지 다이얼로그가 단일 행을 기대해 깨졌던 지점 확인용.
//
// 사용: node scripts/diag_run_rows_per_scope.mjs [--grade 미적분2]
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const at = process.argv.indexOf('--grade');
const onlyGrade = at >= 0 && at + 1 < process.argv.length ? process.argv[at + 1] : '';

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

let query = supabase
  .from('textbook_pb_extract_runs')
  .select('grade_label,big_order,mid_order,sub_key,sub_index,status,mid_name');
if (onlyGrade) query = query.eq('grade_label', onlyGrade);
const { data: runs, error } = await query;
if (error) throw new Error(`runs_select_failed:${error.message}`);

const byScope = new Map();
for (const run of runs ?? []) {
  const key = `${run.grade_label}|${run.big_order}|${run.mid_order}|${run.sub_key}`;
  if (!byScope.has(key)) byScope.set(key, []);
  byScope.get(key).push(run);
}

const multi = [...byScope.entries()].filter(([, rows]) => rows.length > 1);
console.log(
  `스코프 ${byScope.size}개 중 런 행이 2개 이상인 스코프 ${multi.length}개` +
    ' (이 스코프에서 단일 행 조회가 실패한다)',
);
for (const [key, rows] of multi.sort((a, b) => b[1].length - a[1].length).slice(0, 25)) {
  const [grade, big, mid, subKey] = key.split('|');
  const detail = rows
    .sort((a, b) => a.sub_index - b.sub_index)
    .map((row) => `#${row.sub_index}:${row.status}`)
    .join(' ');
  console.log(
    `  ${grade.padEnd(10)} 대${big}-중${mid}-${subKey.padEnd(2)} ${String(rows.length).padStart(2)}행  ${detail}  ${rows[0].mid_name ?? ''}`,
  );
}
