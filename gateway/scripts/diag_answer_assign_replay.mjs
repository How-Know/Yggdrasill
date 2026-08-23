// 매니저 앱의 정답 배정(_assignAnswersByLayout)을 같은 규칙으로 다시 돌려
// 어느 항목이 왜 짝을 못 찾는지 항목별로 찍는 읽기 전용 진단.
//
// 답지 판독 결과는 파일에 캐시해 같은 지면을 다시 모델에 묻지 않는다.
//
// 사용:
//   node scripts/diag_answer_assign_replay.mjs --book <id> --grade 1-2 \
//     --pdf <답지.pdf> --pages 10-12 --body 176-203
import 'dotenv/config';
import { execFileSync } from 'node:child_process';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createClient } from '@supabase/supabase-js';

const arg = (name, fallback = '') => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const range = (value, fallback) => {
  const parts = String(value || fallback).split('-').map((v) => Number.parseInt(v, 10));
  return [parts[0], parts[1] ?? parts[0]];
};
const book = arg('book');
const grade = arg('grade');
const pdf = arg('pdf');
const [firstPage, lastPage] = range(arg('pages'), '10-12');
const [bodyFrom, bodyTo] = range(arg('body'), '1-999');

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
  .gte('display_page', bodyFrom)
  .lte('display_page', bodyTo);
if (error) throw error;

// 앱은 슬롯 순서로 크롭을 싣고, 슬롯 안에서는 raw_page → problem_number 순이다.
const targets = (data ?? [])
  .filter((row) => !row.is_set_header)
  .sort((a, b) => {
    const slot =
      a.sub_key.localeCompare(b.sub_key) || (a.sub_index ?? 0) - (b.sub_index ?? 0);
    if (slot !== 0) return slot;
    const page = (a.raw_page ?? 0) - (b.raw_page ?? 0);
    return page !== 0 ? page : String(a.problem_number).localeCompare(String(b.problem_number));
  })
  .map((row) => ({
    number: String(row.problem_number),
    corner: row.section === 'unit_review' ? '단원 마무리 평가' : '',
    bodyPage: row.display_page ?? 0,
    slot: `${row.sub_key}#${row.sub_index}`,
  }));

const numberKey = (raw) => {
  const input = String(raw ?? '').trim();
  if (!input) return '';
  const numbers = [...input.matchAll(/\d+/g)].map((m) => String(Number(m[0])));
  if (numbers.length === 0) return input.replace(/\s+/g, '');
  if (/(\d+)\s*[~\-–—〜]\s*(\d+)/.test(input) && numbers.length >= 2) {
    return `${numbers[0]}-${numbers[1]}`;
  }
  return numbers[0];
};
const numberRange = (raw) => {
  const m = /^0*(\d+)\s*[~\-–—〜]\s*0*(\d+)$/.exec(String(raw ?? '').trim());
  if (!m) return null;
  const from = Number(m[1]);
  const to = Number(m[2]);
  return from <= to ? [from, to] : null;
};

// _stageBlockIndexes (carryUnitReviewContinuation = true)
const order = targets.map((_, i) => i).sort((a, b) => {
  const page = targets[a].bodyPage - targets[b].bodyPage;
  return page !== 0 ? page : a - b;
});
const blockIndexes = new Array(targets.length).fill(-1);
{
  let block = -1;
  let lastCorner = '\u0000';
  let lastValue = 0;
  for (const position of order) {
    const target = targets[position];
    const value = Number.parseInt(target.number.replace(/\D/g, ''), 10) || 0;
    const continues = lastCorner !== '' && target.corner === '' && value > lastValue;
    if (block < 0 || (target.corner !== lastCorner && !continues) || value <= lastValue) {
      block += 1;
    }
    blockIndexes[position] = block;
    lastCorner = target.corner;
    lastValue = value;
  }
}

const lowPage = new Map();
const highPage = new Map();
const cornerOf = new Map();
const byNumber = new Map();
for (let i = 0; i < targets.length; i += 1) {
  const block = blockIndexes[i];
  if (!cornerOf.has(block) || (!cornerOf.get(block) && targets[i].corner)) {
    cornerOf.set(block, targets[i].corner);
  }
  const page = targets[i].bodyPage;
  if (page > 0) {
    lowPage.set(block, Math.min(lowPage.get(block) ?? page, page));
    highPage.set(block, Math.max(highPage.get(block) ?? page, page));
  }
  if (!byNumber.has(block)) byNumber.set(block, new Map());
  const key = numberKey(targets[i].number);
  if (!byNumber.get(block).has(key)) byNumber.get(block).set(key, i);
}
console.log('블록 구성:');
for (const block of [...byNumber.keys()].sort((a, b) => a - b)) {
  console.log(
    `  block${block} 쪽=${lowPage.get(block)}~${highPage.get(block)} ` +
      `문항=${byNumber.get(block).size}`,
  );
}

const blockForHeader = (header) => {
  if (String(header.title || '').replace(/\s/g, '').includes('단원마무리')) {
    for (const [block, corner] of cornerOf) if (corner) return block;
  }
  if (!(header.page_start > 0)) return -1;
  const end = header.page_end >= header.page_start ? header.page_end : header.page_start;
  for (const block of lowPage.keys()) {
    if (header.page_start <= highPage.get(block) && end >= lowPage.get(block)) {
      return block;
    }
  }
  return -1;
};

const gateway = process.env.PB_GATEWAY_URL || 'http://localhost:8787';
const apiKey = process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '';
const cacheDir = join(process.cwd(), '.tmp_answer_layout_cache');
if (!existsSync(cacheDir)) mkdirSync(cacheDir);
const renderDir = mkdtempSync(join(tmpdir(), 'assign-replay-'));

const pending = new Set(targets.map((_, i) => i));
let currentBlock = -1;
for (let page = firstPage; page <= lastPage; page += 1) {
  const cache = join(cacheDir, `${grade}_p${page}.json`);
  let layout;
  if (existsSync(cache)) {
    layout = JSON.parse(readFileSync(cache, 'utf8'));
  } else {
    execFileSync('pdftoppm', [
      '-png', '-r', '200', '-f', String(page), '-l', String(page), pdf,
      join(renderDir, `p${page}`),
    ]);
    const file = readdirSync(renderDir).find(
      (name) => name.startsWith(`p${page}-`) && name.endsWith('.png'),
    );
    const res = await fetch(`${gateway}/textbook/vlm/extract-answer-layout`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(apiKey ? { 'x-api-key': apiKey } : {}),
      },
      body: JSON.stringify({
        image_base64: readFileSync(join(renderDir, file)).toString('base64'),
        mime_type: 'image/png',
        raw_page: page,
      }),
    });
    layout = await res.json();
    writeFileSync(cache, JSON.stringify(layout, null, 1));
  }

  if (!layout.leading_continuation) currentBlock = -1;
  let matched = 0;
  const skipped = [];
  // 지면 읽기 순서(왼쪽 단 위→아래, 다음 단 위→아래)로 다시 세운다.
  const raw = layout.entries ?? [];
  const sortable = raw.every((e) => Array.isArray(e.bbox) && e.bbox.length === 4);
  const entries = !sortable
    ? raw
    : raw
        .map((entry, index) => ({ entry, index }))
        .sort((a, b) => {
          const column = (e) => (e.entry.bbox[1] >= 500 ? 2 : 1);
          const byColumn = column(a) - column(b);
          if (byColumn !== 0) return byColumn;
          const byTop = a.entry.bbox[0] - b.entry.bbox[0];
          return byTop !== 0 ? byTop : a.index - b.index;
        })
        .map(({ entry }) => entry);
  if (sortable) {
    const moved = entries.filter((entry, i) => entry !== raw[i]).length;
    console.log(`  (읽기 순서 재정렬: 자리 바뀐 요소 ${moved}개)`);
  }
  for (const entry of entries) {
    if (entry.kind === 'header') {
      currentBlock = blockForHeader(entry);
      console.log(
        `  [머리] "${entry.title}" ${entry.page_start}~${entry.page_end} ` +
          `→ block${currentBlock}`,
      );
      continue;
    }
    if (currentBlock < 0) {
      skipped.push(`${entry.problem_number}(블록없음)`);
      continue;
    }
    const map = byNumber.get(currentBlock);
    const positions = [];
    const single = map?.get(numberKey(entry.problem_number));
    if (single != null) {
      if (pending.has(single)) positions.push(single);
    } else {
      const span = numberRange(entry.problem_number);
      if (span) {
        for (let n = span[0]; n <= span[1]; n += 1) {
          const position = map?.get(String(n));
          if (position != null && pending.has(position)) positions.push(position);
        }
      }
    }
    if (positions.length === 0) {
      skipped.push(
        `${entry.problem_number}(${single == null ? '번호없음' : '이미채움'})`,
      );
      continue;
    }
    for (const position of positions) {
      pending.delete(position);
      matched += 1;
    }
  }
  console.log(
    `p${page}: 요소 ${(layout.entries ?? []).length} · 매칭 ${matched} · ` +
      `건너뜀 ${skipped.length} · 남은 ${pending.size}`,
  );
  if (skipped.length > 0) console.log(`   건너뜀 목록: ${skipped.join(' ')}`);
}
console.log(`최종 매칭 ${targets.length - pending.size}/${targets.length}`);
for (const position of [...pending].sort((a, b) => a - b)) {
  const target = targets[position];
  console.log(
    `  누락 block${blockIndexes[position]} ${target.number}@p${target.bodyPage} ${target.slot}`,
  );
}
