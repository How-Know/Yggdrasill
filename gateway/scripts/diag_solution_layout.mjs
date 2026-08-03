// 해설 좌표를 "지면 구조"로 붙이는 앱 로직을 그대로 흉내 낸다 (읽기 전용).
//
// 모델에게는 소단원 머리 위치와 번호 위치만 묻고, 어느 문항인지는 여기서 정한다.
// 머리를 지날 때마다 지금 읽는 소단원을 바꾸고, 그 뒤 번호를 그 소단원의 같은
// 번호 크롭에 붙인다. 배지 없이 시작하는 지면 첫머리는 앞 지면에서 이어진 것이다.
//
// 사용:
//   node scripts/diag_solution_layout.mjs --book <id> --grade 공통수학2 \
//     --pdf "..._해설.pdf" --from 22 --to 37
import 'dotenv/config';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createClient } from '@supabase/supabase-js';

function arg(name, fallback = '') {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? String(process.argv[i + 1]).trim() : fallback;
}

const bookId = arg('book');
const grade = arg('grade');
const midOrder = Number.parseInt(arg('mid', '-1'), 10);
const pdfPath = arg('pdf');
const fromPage = Number.parseInt(arg('from', '1'), 10);
const toPage = Number.parseInt(arg('to', '0'), 10);
if (!bookId || !pdfPath || !toPage) throw new Error('--book --pdf --to 가 필요하다');

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

let query = supabase
  .from('textbook_problem_crops')
  .select('id,mid_order,sub_key,sub_index,display_page,raw_page,problem_number,section,is_set_header')
  .eq('book_id', bookId)
  .order('display_page')
  .order('problem_number');
if (grade) query = query.eq('grade_label', grade);
if (midOrder >= 0) query = query.eq('mid_order', midOrder);
const { data: crops, error } = await query;
if (error) throw new Error(error.message);

const CORNERS = { unit_review: '단원 마무리 평가' };
const targets = (crops ?? [])
  .filter((c) => c.is_set_header !== true && String(c.problem_number || '').trim())
  .map((c) => ({
    key: `${c.sub_key}#${c.sub_index} ${c.problem_number}@p${c.display_page ?? c.raw_page}`,
    number: String(c.problem_number).trim(),
    corner: CORNERS[c.section] ?? '',
    page: c.display_page ?? c.raw_page ?? 0,
  }));

// 소단원 블록 = 코너가 바뀌거나 번호가 앞으로 되돌아가는 지점에서 끊는다.
const blockIndexes = [];
{
  let block = -1;
  let lastCorner = '\u0000';
  let lastValue = 0;
  for (const t of targets) {
    const value = Number.parseInt(t.number.replace(/\D/g, ''), 10) || 0;
    const continuesUnitReview =
      lastCorner && !t.corner && value > lastValue;
    if (
      block < 0 ||
      (t.corner !== lastCorner && !continuesUnitReview) ||
      value <= lastValue
    ) block += 1;
    blockIndexes.push(block);
    lastCorner = t.corner;
    lastValue = value;
  }
}

const numberKey = (raw) => {
  const digits = String(raw || '').replace(/\D/g, '');
  return digits ? digits.replace(/^0+/, '') : String(raw || '').trim();
};

const lo = new Map();
const hi = new Map();
const cornerOf = new Map();
const byNumber = new Map();
targets.forEach((t, i) => {
  const b = blockIndexes[i];
  if (!cornerOf.get(b) && t.corner) cornerOf.set(b, t.corner);
  else if (!cornerOf.has(b)) cornerOf.set(b, t.corner);
  if (t.page > 0) {
    lo.set(b, Math.min(lo.get(b) ?? t.page, t.page));
    hi.set(b, Math.max(hi.get(b) ?? t.page, t.page));
  }
  if (!byNumber.has(b)) byNumber.set(b, new Map());
  const table = byNumber.get(b);
  if (!table.has(numberKey(t.number))) table.set(numberKey(t.number), i);
});

function blockForHeader(head) {
  if (String(head.title || '').replace(/\s/g, '').includes('단원마무리')) {
    for (const [block, corner] of cornerOf) if (corner) return block;
  }
  if (!head.page_start) return -1;
  const end = head.page_end >= head.page_start ? head.page_end : head.page_start;
  for (const block of lo.keys()) {
    if (head.page_start <= hi.get(block) && end >= lo.get(block)) return block;
  }
  return -1;
}

const gateway = String(process.env.PB_GATEWAY_URL || 'http://localhost:8787').trim();
const apiKey = String(process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '').trim();
const workDir = mkdtempSync(join(tmpdir(), 'layout-'));

async function readPage(page) {
  const prefix = join(workDir, `p${page}`);
  execFileSync('pdftoppm', [
    '-png', '-r', '200', '-f', String(page), '-l', String(page), pdfPath, prefix,
  ]);
  const name = readdirSync(workDir).find(
    (f) => f.startsWith(`p${page}-`) && f.endsWith('.png'),
  );
  const png = readFileSync(join(workDir, name));
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const res = await fetch(`${gateway}/textbook/vlm/detect-solution-blocks`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(apiKey ? { 'x-api-key': apiKey } : {}),
        },
        body: JSON.stringify({
          image_base64: png.toString('base64'),
          mime_type: 'image/png',
          raw_page: page,
        }),
      });
      return await res.json();
    } catch (err) {
      await new Promise((r) => setTimeout(r, 1000 * (attempt + 1)));
    }
  }
  return null;
}

console.log(`기대 문항 ${targets.length}건, 해설 p${fromPage}~${toPage} 를 구조로 붙인다`);
const pending = new Set(targets.map((_, i) => i));
const assigned = new Map();
let current = -1;
for (let page = fromPage; page <= toPage; page += 1) {
  const res = await readPage(page);
  if (!res || res.ok !== true) {
    console.log(`p${page}: 지면 읽기 실패`);
    current = -1;
    continue;
  }
  if (!res.leading_continuation) current = -1;
  let matched = 0;
  const skippedNumbers = [];
  for (const entry of res.sequence ?? []) {
    if (entry.kind === 'header') {
      current = blockForHeader(entry);
      continue;
    }
    if (current < 0) {
      skippedNumbers.push(`${entry.text}(블록미상)`);
      continue;
    }
    const position = byNumber.get(current)?.get(numberKey(entry.text));
    if (position == null || !pending.delete(position)) {
      skippedNumbers.push(`${entry.text}(블록${current})`);
      continue;
    }
    assigned.set(position, page);
    matched += 1;
  }
  const numbers = (res.sequence ?? []).filter((e) => e.kind !== 'header').length;
  console.log(
    `p${page}: 머리 ${(res.blocks ?? []).length} · 번호 ${numbers} · 붙임 ${matched} · 건너뜀 ${skippedNumbers.length} · 남은 ${pending.size}`,
  );
  if (skippedNumbers.length) console.log(`   건너뜀: ${skippedNumbers.join(', ')}`);
}

console.log(`\n붙인 ${assigned.size} / ${targets.length}`);
if (pending.size) {
  console.log(`끝까지 못 붙인 ${pending.size}건:`);
  for (const i of [...pending].sort((a, b) => a - b)) console.log(`  ${targets[i].key}`);
}

// 같은 소단원 안에서 해설 쪽 번호가 뒤로 가는지(잘못 붙었는지) 확인한다.
let backwards = 0;
let lastBlock = -1;
let lastPage = 0;
for (let i = 0; i < targets.length; i += 1) {
  const page = assigned.get(i);
  if (page == null) continue;
  if (blockIndexes[i] !== lastBlock) {
    lastBlock = blockIndexes[i];
    lastPage = page;
    continue;
  }
  if (page < lastPage) {
    backwards += 1;
    console.log(`  차례 역행: ${targets[i].key} → 해설 p${page} (앞 문항 p${lastPage})`);
  }
  lastPage = page;
}
console.log(`차례 역행 ${backwards}건`);
process.exit(0);
