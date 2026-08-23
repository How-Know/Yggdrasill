// 매니저 앱의 _stageBlockIndexes 를 같은 규칙으로 다시 계산해 보는 읽기 전용 진단.
//
// 정답·해설 단계는 기대 문항을 "블록"(답지에서 번호가 01부터 다시 시작하는
// 묶음)으로 끊고, 답지 머리의 본문 페이지 배지로 블록을 고른다. 블록이 잘못
// 끊기면 그 블록의 뒤쪽 번호가 통째로 짝을 못 찾는다.
//
// 사용: node scripts/diag_stage_blocks.mjs --book <id> --grade 1-2 --mid 1
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const arg = (name, fallback = '') => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const book = arg('book');
const grade = arg('grade');
const mid = Number.parseInt(arg('mid', '1'), 10);

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } },
);
const { data, error } = await supabase
  .from('textbook_problem_crops')
  .select('sub_key,sub_index,raw_page,display_page,problem_number,section,is_set_header')
  .eq('book_id', book)
  .eq('grade_label', grade)
  .eq('mid_order', mid);
if (error) throw error;

// 앱은 슬롯(sub_key,sub_index) 순서로 크롭을 싣고, 슬롯 안에서는
// raw_page → problem_number(문자열) 순으로 받는다.
const rows = (data ?? [])
  .filter((row) => !row.is_set_header)
  .sort((a, b) => {
    const slot =
      a.sub_key.localeCompare(b.sub_key) || (a.sub_index ?? 0) - (b.sub_index ?? 0);
    if (slot !== 0) return slot;
    const page = (a.raw_page ?? 0) - (b.raw_page ?? 0);
    if (page !== 0) return page;
    return String(a.problem_number).localeCompare(String(b.problem_number));
  });

// carryUnitReviewContinuation=true (수력충전): 본문 페이지 순으로 다시 세운다.
const order = rows.map((_, index) => index).sort((a, b) => {
  const page = (rows[a].display_page ?? 0) - (rows[b].display_page ?? 0);
  return page !== 0 ? page : a - b;
});

const blocks = new Array(rows.length).fill(-1);
let block = -1;
let lastCorner = '\u0000';
let lastValue = 0;
for (const position of order) {
  const row = rows[position];
  const corner = row.section === 'unit_review' ? '단원 마무리 평가' : '';
  const value = Number.parseInt(String(row.problem_number).replace(/\D/g, ''), 10) || 0;
  const continues = lastCorner !== '' && corner === '' && value > lastValue;
  if (block < 0 || (corner !== lastCorner && !continues) || value <= lastValue) {
    block += 1;
  }
  blocks[position] = block;
  lastCorner = corner;
  lastValue = value;
}

const summary = new Map();
for (let i = 0; i < rows.length; i += 1) {
  const b = blocks[i];
  const entry = summary.get(b) ?? {
    slots: new Set(),
    pages: new Set(),
    numbers: [],
  };
  entry.slots.add(`${rows[i].sub_key}#${rows[i].sub_index}`);
  entry.pages.add(rows[i].display_page);
  entry.numbers.push(String(rows[i].problem_number));
  summary.set(b, entry);
}
for (const [b, entry] of [...summary.entries()].sort((x, y) => x[0] - y[0])) {
  const pages = [...entry.pages].sort((x, y) => x - y);
  console.log(
    `block${b} 슬롯=${[...entry.slots].join(',')} ` +
      `본문쪽=${pages[0]}~${pages[pages.length - 1]} ` +
      `문항=${entry.numbers.length} (${entry.numbers.join(' ')})`,
  );
}
