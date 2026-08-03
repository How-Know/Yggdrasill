// 저장된 크롭 중 정답·해설 좌표가 비어 있는 것을 스코프별로 모아 찍는다.
//
// "해설에서 자꾸 번호가 빠진다" 같은 신고를 받았을 때, 어떤 블록의 어떤
// 번호가 비었는지 눈으로 확인하는 읽기 전용 점검 도구다.
//
// 사용: node scripts/diag_sidecar_gaps.mjs <book_id>
//       node scripts/diag_sidecar_gaps.mjs --books suryeok
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const argv = process.argv.slice(2);
// 크롭이 한 건이라도 저장된 교재 목록. 책 이름은 resource_files 에 있다.
if (argv[0] === '--books') {
  const { data, error } = await supabase
    .from('textbook_problem_crops')
    .select('book_id,grade_label')
    .limit(20000);
  if (error) throw new Error(error.message);
  const byBook = new Map();
  for (const row of data ?? []) {
    const bucket = byBook.get(row.book_id) ?? { count: 0, grades: new Set() };
    bucket.count += 1;
    bucket.grades.add(row.grade_label);
    byBook.set(row.book_id, bucket);
  }
  const { data: files } = await supabase
    .from('resource_files')
    .select('id,name')
    .in('id', [...byBook.keys()]);
  const nameById = new Map((files ?? []).map((f) => [f.id, f.name]));
  for (const [id, info] of byBook) {
    console.log(
      `${id}  ${info.count}건  [${[...info.grades].join(',')}]  ${nameById.get(id) ?? '?'}`,
    );
  }
  process.exit(0);
}

const bookId = String(argv[0] || '').trim();
if (!bookId) throw new Error('book_id 가 필요하다');

if (bookId === '--counts') {
  for (const table of [
    'textbook_problem_answers',
    'textbook_problem_solution_refs',
  ]) {
    const { count, error: e } = await supabase
      .from(table)
      .select('crop_id', { count: 'exact', head: true });
    console.log(`${table}: ${e ? e.message : count}`);
  }
  process.exit(0);
}

const { data: crops, error } = await supabase
  .from('textbook_problem_crops')
  .select(
    'id,grade_label,big_order,mid_order,sub_key,sub_index,raw_page,display_page,' +
      'problem_number,section,is_set_header',
  )
  .eq('book_id', bookId)
  .order('big_order')
  .order('mid_order')
  .order('sub_index')
  .order('raw_page');
if (error) throw new Error(error.message);

const targets = (crops ?? []).filter((c) => c.is_set_header !== true);
const ids = targets.map((c) => c.id);

async function loadIds(table, column) {
  const found = new Set();
  for (let i = 0; i < ids.length; i += 500) {
    const chunk = ids.slice(i, i + 500);
    const { data, error: e } = await supabase
      .from(table)
      .select(`crop_id,${column}`)
      .in('crop_id', chunk);
    if (e) throw new Error(`${table}: ${e.message}`);
    for (const row of data ?? []) {
      const value = row[column];
      if (value == null || String(value).trim() === '') continue;
      found.add(row.crop_id);
    }
  }
  return found;
}

const withAnswer = await loadIds('textbook_problem_answers', 'answer_text');
const withSolution = await loadIds('textbook_problem_solution_refs', 'raw_page');
console.log(
  `크롭 ${targets.length}건 · 정답행 ${withAnswer.size} · 해설행 ${withSolution.size}`,
);

const groups = new Map();
for (const c of targets) {
  const key = `${c.grade_label} B${c.big_order}/M${c.mid_order} ${c.sub_key}#${c.sub_index}`;
  const bucket = groups.get(key) ?? [];
  bucket.push(c);
  groups.set(key, bucket);
}

let missingAnswer = 0;
let missingSolution = 0;
for (const [key, rows] of groups) {
  const noAnswer = rows.filter((r) => !withAnswer.has(r.id));
  const noSolution = rows.filter((r) => !withSolution.has(r.id));
  missingAnswer += noAnswer.length;
  missingSolution += noSolution.length;
  if (!noAnswer.length && !noSolution.length) continue;
  const fmt = (list) =>
    list
      .map((r) => `${r.problem_number}@p${r.display_page ?? r.raw_page}`)
      .join(' ');
  console.log(`\n${key} · 전체 ${rows.length}건`);
  if (noAnswer.length) console.log(`  정답없음 ${noAnswer.length}: ${fmt(noAnswer)}`);
  if (noSolution.length) console.log(`  해설없음 ${noSolution.length}: ${fmt(noSolution)}`);
}
console.log(
  `\n총 ${targets.length}건 · 정답없음 ${missingAnswer} · 해설없음 ${missingSolution}`,
);
process.exit(0);
