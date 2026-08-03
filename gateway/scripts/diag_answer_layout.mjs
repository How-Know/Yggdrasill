// 수력충전 빠른 정답을 구조 기반으로 본문 크롭에 대응하는 읽기 전용 진단.
import 'dotenv/config';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createClient } from '@supabase/supabase-js';

const arg = (name, fallback = '') => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const book = arg('book');
const grade = arg('grade');
const mid = Number.parseInt(arg('mid', '1'), 10);
const pdf = arg('pdf');
const from = Number.parseInt(arg('from', '1'), 10);
const to = Number.parseInt(arg('to', '1'), 10);
const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } },
);
const { data, error } = await supabase
  .from('textbook_problem_crops')
  .select('id,sub_key,sub_index,display_page,problem_number,section,is_set_header')
  .eq('book_id', book)
  .eq('grade_label', grade)
  .eq('mid_order', mid)
  .order('display_page')
  .order('problem_number');
if (error) throw error;
const targets = data
  .filter((r) => !r.is_set_header)
  .map((r) => ({
    ...r,
    number: String(r.problem_number),
    page: r.display_page || 0,
    corner: r.section === 'unit_review' ? '단원 마무리 평가' : '',
  }));

// 본문 페이지 순서에서 번호가 되감기면 새 블록. B→A라도 번호가 계속되면
// 기존 오분류된 단원 마무리 연속 지면이므로 같은 블록이다.
let block = -1;
let lastCorner = '\0';
let lastValue = 0;
for (const target of targets) {
  const value = Number.parseInt(target.number.replace(/\D/g, ''), 10) || 0;
  const continuation =
    lastCorner && !target.corner && value > lastValue;
  if (
    block < 0 ||
    (target.corner !== lastCorner && !continuation) ||
    value <= lastValue
  ) block += 1;
  target.block = block;
  lastCorner = target.corner;
  lastValue = value;
}
const key = (v) => {
  const digits = String(v || '').replace(/\D/g, '');
  return digits ? String(Number.parseInt(digits, 10)) : String(v || '').trim();
};
const lo = new Map(), hi = new Map(), corner = new Map(), byNumber = new Map();
for (let i = 0; i < targets.length; i += 1) {
  const t = targets[i], b = t.block;
  lo.set(b, Math.min(lo.get(b) ?? t.page, t.page));
  hi.set(b, Math.max(hi.get(b) ?? t.page, t.page));
  if (!corner.get(b) && t.corner) corner.set(b, t.corner);
  if (!byNumber.has(b)) byNumber.set(b, new Map());
  if (!byNumber.get(b).has(key(t.number))) byNumber.get(b).set(key(t.number), i);
}
const blockFor = (head) => {
  if (String(head.title || '').replace(/\s/g, '').includes('단원마무리')) {
    for (const [b, c] of corner) if (c) return b;
  }
  if (!head.page_start) return -1;
  const end = Math.max(head.page_start, head.page_end || 0);
  for (const b of lo.keys()) {
    if (head.page_start <= hi.get(b) && end >= lo.get(b)) return b;
  }
  return -1;
};

const gateway = process.env.PB_GATEWAY_URL || 'http://localhost:8787';
const apiKey = process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '';
const dir = mkdtempSync(join(tmpdir(), 'answer-layout-'));
const pending = new Set(targets.map((_, i) => i));
let current = -1;
for (let page = from; page <= to; page += 1) {
  const prefix = join(dir, `p${page}`);
  execFileSync('pdftoppm', [
    '-png', '-r', '200', '-f', String(page), '-l', String(page), pdf, prefix,
  ]);
  const file = readdirSync(dir).find(
    (f) => f.startsWith(`p${page}-`) && f.endsWith('.png'),
  );
  const png = readFileSync(join(dir, file));
  const res = await fetch(`${gateway}/textbook/vlm/extract-answer-layout`, {
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
  const json = await res.json();
  if (!json.leading_continuation) current = -1;
  let matched = 0, skipped = 0;
  for (const entry of json.entries || []) {
    if (entry.kind === 'header') {
      current = blockFor(entry);
      continue;
    }
    const position = current < 0 ? null : byNumber.get(current)?.get(key(entry.problem_number));
    if (position == null || !pending.delete(position)) skipped += 1;
    else matched += 1;
  }
  console.log(
    `p${page}: 요소 ${(json.entries || []).length} · 매칭 ${matched} · 건너뜀 ${skipped} · 남은 ${pending.size}`,
  );
}
console.log(`최종 매칭 ${targets.length - pending.size}/${targets.length}`);
for (const i of pending) {
  const t = targets[i];
  console.log(`  누락 block${t.block} ${t.number}@p${t.page} ${t.sub_key}#${t.sub_index}`);
}
