// 단원 마무리 평가 이어지는 쪽이 소단원 슬롯(A)으로 새어 들어간 크롭을
// 마무리 평가 슬롯(B)으로 옮긴다.
//
// 마무리 평가는 첫 쪽에만 머리말이 인쇄돼서, 이어지는 쪽의 문항을 모델이
// 유형 문제로 돌려주던 시절에 저장된 크롭이 대상이다. 정답·해설은 크롭 id 로
// 매달리므로 슬롯만 바로잡으면 되고, 다시 추출할 필요는 없다.
//
// 사용:
//   node scripts/fix_suryeok_unit_review_slot.mjs --book <id> --grade 공통수학2 \
//     --pages 31 [--apply]
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

function arg(name, fallback = '') {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? String(process.argv[i + 1]).trim() : fallback;
}

const bookId = arg('book');
const grade = arg('grade');
const pages = arg('pages', '')
  .split(',')
  .map((v) => Number.parseInt(v, 10))
  .filter(Number.isFinite);
const apply = process.argv.includes('--apply');
if (!bookId || !pages.length) throw new Error('--book 과 --pages 가 필요하다');

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

let query = supabase
  .from('textbook_problem_crops')
  .select('id,sub_key,sub_index,raw_page,display_page,problem_number,section,item_name')
  .eq('book_id', bookId)
  .eq('sub_key', 'A')
  .in('raw_page', pages)
  .order('problem_number');
if (grade) query = query.eq('grade_label', grade);
const { data, error } = await query;
if (error) throw new Error(error.message);
const rows = data ?? [];
if (!rows.length) {
  console.log('옮길 크롭이 없다');
  process.exit(0);
}
for (const row of rows) {
  console.log(
    `${row.problem_number}@p${row.display_page ?? row.raw_page} ` +
      `${row.sub_key}#${row.sub_index} section=${row.section} name=${row.item_name || '-'}`,
  );
}
if (!apply) {
  console.log(`\n미리보기 ${rows.length}건. 실제로 옮기려면 --apply 를 붙여라.`);
  process.exit(0);
}

const { error: updateError } = await supabase
  .from('textbook_problem_crops')
  .update({
    sub_key: 'B',
    section: 'unit_review',
    item_name: '단원 마무리 평가',
    content_group_kind: 'none',
    content_group_label: '',
    content_group_title: '',
    content_group_order: null,
  })
  .in('id', rows.map((r) => r.id));
if (updateError) throw new Error(updateError.message);
console.log(`\n${rows.length}건을 단원 마무리 평가(B) 슬롯으로 옮겼다.`);
process.exit(0);
