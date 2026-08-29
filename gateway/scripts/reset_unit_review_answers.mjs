// 단원 마무리 평가 블록의 정답·해설 좌표만 지워 다시 뽑을 수 있게 한다.
//
// 앞 중단원의 마무리 머리가 이번 마무리 블록을 가로채던 버그(이름만 보고
// 코너 블록을 집던 blockForHeader) 때문에, 마무리 24문항이 통째로 다른
// 중단원의 답으로 채워진 블록들이 있다. 정답 단계는 이미 채워진 크롭을
// 건너뛰므로 지우지 않으면 다시 뽑아도 그 값이 그대로 남는다.
//
// 사용(먼저 지워질 목록만 본다):
//   node scripts/reset_unit_review_answers.mjs --book <id> --grade 2-1 --body 32-34
// 실제로 지울 때:
//   node scripts/reset_unit_review_answers.mjs --book <id> --grade 2-1 --body 32-34 --apply
//
// --solutions 를 붙이면 해설 좌표(textbook_problem_solution_refs)까지 지운다.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const arg = (name, fallback = '') => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const has = (name) => process.argv.includes(`--${name}`);

const bookId = arg('book');
const gradeLabel = arg('grade');
const body = arg('body');
if (!bookId || !gradeLabel || !body) {
  throw new Error('--book, --grade, --body <시작-끝> 을 모두 넘겨주세요');
}
const [from, to] = body.split('-').map((v) => Number.parseInt(v, 10));
if (!Number.isFinite(from) || !Number.isFinite(to)) {
  throw new Error('--body 는 "32-34" 처럼 본문 쪽 범위로 넘겨주세요');
}
const apply = has('apply');

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: crops, error } = await supabase
  .from('textbook_problem_crops')
  .select('id,sub_key,sub_index,display_page,problem_number,section')
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .eq('section', 'unit_review')
  .gte('display_page', from)
  .lte('display_page', to)
  .order('display_page')
  .order('problem_number');
if (error) throw new Error(error.message);
const ids = (crops ?? []).map((c) => c.id);
if (ids.length === 0) {
  console.log('해당 범위에 단원 마무리 평가 크롭이 없습니다.');
  process.exit(0);
}

const answers = new Map();
for (let i = 0; i < ids.length; i += 100) {
  const { data, error: e } = await supabase
    .from('textbook_problem_answers')
    .select('crop_id,answer_text,raw_page')
    .in('crop_id', ids.slice(i, i + 100));
  if (e) throw new Error(e.message);
  for (const row of data ?? []) answers.set(row.crop_id, row);
}

console.log(
  `${gradeLabel} 본문 p${from}~${to} 단원 마무리 평가 크롭 ${ids.length}건 · ` +
    `정답 있는 것 ${answers.size}건${apply ? '' : ' (미리보기 — 지우지 않음)'}`,
);
for (const crop of crops ?? []) {
  const row = answers.get(crop.id);
  console.log(
    `  ${crop.sub_key}#${crop.sub_index} 본문p${crop.display_page} ` +
      `${String(crop.problem_number).padEnd(4)} 답지p${row?.raw_page ?? '-'} ` +
      `${String(row?.answer_text ?? '').slice(0, 40)}`,
  );
}
if (!apply) {
  console.log('\n지우려면 --apply 를 붙여 다시 실행하세요.');
  process.exit(0);
}

for (let i = 0; i < ids.length; i += 100) {
  const chunk = ids.slice(i, i + 100);
  const { error: e } = await supabase
    .from('textbook_problem_answers')
    .delete()
    .in('crop_id', chunk);
  if (e) throw new Error(`answers_delete_failed:${e.message}`);
  if (!has('solutions')) continue;
  const { error: se } = await supabase
    .from('textbook_problem_solution_refs')
    .delete()
    .in('crop_id', chunk);
  if (se) throw new Error(`solution_refs_delete_failed:${se.message}`);
}
console.log(
  `\n정답 ${answers.size}건 삭제 완료` +
    `${has('solutions') ? ' (해설 좌표까지)' : ''}. 단원 다이얼로그에서 정답 단계를 다시 실행하세요.`,
);
