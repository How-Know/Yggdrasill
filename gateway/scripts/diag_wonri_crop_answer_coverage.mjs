// 개념원리 crop 에 정답 사이드카가 있는지 카테고리별로 센다 (읽기 전용).
//
// 교재 풀이 화면의 채점은 crop 정답(textbook_problem_answers)을 쓰고,
// pb_questions 의 정답은 문제은행 재사용(학습지 출제) 쪽에서 쓴다. 어느 쪽이
// 비어 있는지에 따라 영향 범위가 완전히 다르므로 나눠 본다.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

async function selectAll(table, columns, configure) {
  const rows = [];
  for (let from = 0; ; from += 1000) {
    let query = supabase.from(table).select(columns).range(from, from + 999);
    query = configure ? configure(query) : query;
    const { data, error } = await query;
    if (error) throw new Error(`${table}_select_failed:${error.message}`);
    rows.push(...(data ?? []));
    if ((data ?? []).length < 1000) return rows;
  }
}

const books = await selectAll(
  'textbook_metadata',
  'academy_id,book_id,grade_label',
  (query) => query.eq('payload->>series', 'wonri'),
);

const crops = [];
for (const book of books) {
  const rows = await selectAll(
    'textbook_problem_crops',
    'id,sub_key,grade_label',
    (query) =>
      query
        .eq('academy_id', book.academy_id)
        .eq('book_id', book.book_id)
        .eq('grade_label', book.grade_label)
        .eq('is_set_header', false),
  );
  crops.push(...rows);
}
console.log(`개념원리 crop ${crops.length}건`);

const withAnswer = new Set();
const cropIds = crops.map((crop) => crop.id);
for (let i = 0; i < cropIds.length; i += 120) {
  const { data, error } = await supabase
    .from('textbook_problem_answers')
    .select('crop_id,answer_text,answer_latex_2d')
    .in('crop_id', cropIds.slice(i, i + 120));
  if (error) throw new Error(`answers_select_failed:${error.message}`);
  for (const row of data ?? []) {
    const text = String(row.answer_text ?? '').trim();
    const latex = String(row.answer_latex_2d ?? '').trim();
    if (text || latex) withAnswer.add(row.crop_id);
  }
}

const tally = new Map();
for (const crop of crops) {
  const key = String(crop.sub_key ?? '?');
  const prev = tally.get(key) ?? { total: 0, missing: 0 };
  prev.total += 1;
  if (!withAnswer.has(crop.id)) prev.missing += 1;
  tally.set(key, prev);
}

console.log('\n카테고리   crop     정답없음   비율');
for (const [key, value] of [...tally.entries()].sort()) {
  const pct = value.total ? Math.round((value.missing / value.total) * 100) : 0;
  console.log(
    `${key.padEnd(9)} ${String(value.total).padStart(5)} ${String(value.missing).padStart(9)} ${String(pct).padStart(5)}%`,
  );
}
