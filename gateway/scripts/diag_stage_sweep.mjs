// 저장된 크롭으로 앱의 정답/해설 단계를 그대로 흉내 내어 어떤 번호가
// 끝까지 안 잡히는지 찾는다 (읽기 전용).
//
// 앱은 남은 기대 문항 전체를 매 지면에 함께 보내고, 돌아온 expected_index 로
// 짝을 지운다. 여기서도 같은 순서로 돌려 "끝까지 남은 번호" 를 찍는다.
//
// 사용:
//   node scripts/diag_stage_sweep.mjs --book <id> --grade 공통수학2 \
//     --mode solution --pdf "..._해설.pdf" --from 28 --to 40
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
const pdfPath = arg('pdf');
const mode = arg('mode', 'solution');
const fromPage = Number.parseInt(arg('from', '1'), 10);
const toPage = Number.parseInt(arg('to', '0'), 10);
const series = arg('series', 'suryeok');
if (!bookId || !pdfPath || !toPage) throw new Error('--book --pdf --to 가 필요하다');

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

let query = supabase
  .from('textbook_problem_crops')
  .select('id,sub_key,sub_index,display_page,raw_page,problem_number,section,is_set_header')
  .eq('book_id', bookId)
  .order('sub_index')
  .order('raw_page')
  .order('problem_number');
if (grade) query = query.eq('grade_label', grade);
const { data: crops, error } = await query;
if (error) throw new Error(error.message);

const CORNERS = { unit_review: '단원 마무리 평가' };
const targets = (crops ?? [])
  .filter((c) => c.is_set_header !== true && String(c.problem_number || '').trim())
  .map((c) => ({
    key: `${c.sub_key}#${c.sub_index} ${c.problem_number}@p${c.display_page ?? c.raw_page}`,
    problem_number: String(c.problem_number).trim(),
    corner: CORNERS[c.section] ?? '',
    page: c.display_page ?? c.raw_page ?? 0,
  }));
console.log(`기대 문항 ${targets.length}건, ${mode} p${fromPage}~${toPage} 훑는다`);

const gateway = String(process.env.PB_GATEWAY_URL || 'http://localhost:8787').trim();
const apiKey = String(process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '').trim();
const endpoint =
  mode === 'solution'
    ? '/textbook/vlm/detect-solution-refs'
    : '/textbook/vlm/extract-answers';
const workDir = mkdtempSync(join(tmpdir(), 'sweep-'));

// 앱과 같은 블록 창(아직 못 찾은 블록부터 blockSpan 개)을 쓴다.
const blockSpan = Number.parseInt(arg('span', '4'), 10);
const blockIndexes = [];
{
  let block = -1;
  let lastCorner = '\u0000';
  let lastValue = 0;
  for (const t of targets) {
    const value = Number.parseInt(t.problem_number.replace(/\D/g, ''), 10) || 0;
    if (block < 0 || t.corner !== lastCorner || value <= lastValue) block += 1;
    blockIndexes.push(block);
    lastCorner = t.corner;
    lastValue = value;
  }
}
function skipBadgesFor(order) {
  if (!order.length) return [];
  const windowStart = blockIndexes[order[0]];
  if (windowStart <= 0) return [];
  const pagesByBlock = new Map();
  const cornerByBlock = new Map();
  for (let i = 0; i < targets.length; i += 1) {
    const block = blockIndexes[i];
    if (block >= windowStart) break;
    const page = targets[i].page;
    if (page > 0) {
      const bucket = pagesByBlock.get(block) ?? [];
      bucket.push(page);
      pagesByBlock.set(block, bucket);
    }
    if (!cornerByBlock.has(block)) cornerByBlock.set(block, targets[i].corner);
  }
  const out = [];
  for (const block of [...pagesByBlock.keys()].sort((a, b) => a - b)) {
    const pages = pagesByBlock.get(block).sort((a, b) => a - b);
    const badge =
      pages[0] === pages[pages.length - 1]
        ? `p.${pages[0]}`
        : `p.${pages[0]}~${pages[pages.length - 1]}`;
    const corner = cornerByBlock.get(block) || '';
    out.push(corner ? `${corner} ${badge}` : badge);
  }
  return out.length <= 8 ? out : out.slice(out.length - 8);
}

// 앱과 같이 **블록 하나**만 보낸다. 목록 안에서 번호가 겹치지 않으므로
// 모델이 블록 머리 배지를 안 적어도 번호만으로 짝이 정해진다.
function windowOf(pending, skipBlocks) {
  const order = [...pending].sort((a, b) => a - b);
  if (!blockSpan || !order.length) return order;
  let block = -1;
  for (const p of order) {
    if (skipBlocks.has(blockIndexes[p])) continue;
    block = blockIndexes[p];
    break;
  }
  if (block < 0) block = blockIndexes[order[0]];
  return order.filter((p) => blockIndexes[p] === block);
}

const numberKey = (s) => String(s || '').replace(/\D/g, '').replace(/^0+/, '');

async function askPage(page, png, order) {
  const json = await postJson(endpoint, {
    image_base64: png.toString('base64'),
    mime_type: 'image/png',
    raw_page: page,
    series,
    expected_numbers: order.map((i) => targets[i]),
    skip_badges: skipBadgesFor(order),
  });
  return (json.result ?? json)?.items ?? [];
}

const maxSweeps = Number.parseInt(arg('sweeps', '10'), 10);
const maxPasses = Number.parseInt(arg('passes', '3'), 10);
const pending = new Set(targets.map((_, i) => i));
const skipBlocks = new Set();
const pngCache = new Map();

// 로컬 소켓이 가끔 끊긴다(ECONNRESET). 진단 스크립트가 통째로 죽지 않게 재시도.
async function postJson(path, payload, attempts = 3) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    try {
      const res = await fetch(`${gateway}${path}`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          ...(apiKey ? { 'x-api-key': apiKey } : {}),
        },
        body: JSON.stringify(payload),
      });
      return await res.json().catch(() => ({}));
    } catch (err) {
      lastErr = err;
      await new Promise((r) => setTimeout(r, 1000 * (i + 1)));
    }
  }
  console.log(`   (요청 실패: ${String(lastErr?.message || lastErr)})`);
  return {};
}

function renderPage(page) {
  if (pngCache.has(page)) return pngCache.get(page);
  const prefix = join(workDir, `p${page}`);
  execFileSync('pdftoppm', [
    '-png', '-r', '200', '-f', String(page), '-l', String(page), pdfPath, prefix,
  ]);
  const name = readdirSync(workDir).find(
    (f) => f.startsWith(`p${page}-`) && f.endsWith('.png'),
  );
  const png = readFileSync(join(workDir, name));
  pngCache.set(page, png);
  return png;
}

// 해설은 이어지는 지면에 블록 머리가 안 찍혀 있어, 문항부터 물으면 모델이 그
// 지면에 실제로 있는 다른 소단원 풀이를 번호만 맞춰 돌려준다. 지면마다 블록
// 목록을 먼저 확정한다 (앱의 `_solutionBlocksByPage` 와 같은 짜임새).
async function buildBlockMap() {
  const lo = new Map();
  const hi = new Map();
  const cornerOf = new Map();
  targets.forEach((t, i) => {
    const b = blockIndexes[i];
    if (!cornerOf.has(b)) cornerOf.set(b, t.corner);
    if (t.page > 0) {
      lo.set(b, Math.min(lo.get(b) ?? t.page, t.page));
      hi.set(b, Math.max(hi.get(b) ?? t.page, t.page));
    }
  });
  const blockFor = (head) => {
    if (String(head.title || '').replace(/\s/g, '').includes('단원마무리')) {
      for (const [block, corner] of cornerOf) if (corner) return block;
    }
    if (!head.page_start) return -1;
    const end = head.page_end >= head.page_start ? head.page_end : head.page_start;
    for (const block of lo.keys()) {
      if (head.page_start <= hi.get(block) && end >= lo.get(block)) return block;
    }
    return -1;
  };
  const map = new Map();
  let carry = -1;
  for (let page = fromPage; page <= toPage; page += 1) {
    const png = renderPage(page);
    const j = await postJson('/textbook/vlm/detect-solution-blocks', {
      image_base64: png.toString('base64'),
      mime_type: 'image/png',
      raw_page: page,
    });
    const heads = j.blocks ?? [];
    const here = [];
    if (j.leading_continuation && carry >= 0) here.push(carry);
    let trailing = -1;
    for (const head of heads) {
      trailing = blockFor(head);
      if (trailing >= 0 && !here.includes(trailing)) here.push(trailing);
    }
    carry = heads.length ? trailing : carry;
    map.set(page, here);
    console.log(`p${page} 지면 블록: ${here.join(', ') || '(없음)'}`);
  }
  return map;
}

const blockMap = arg('index', '1') === '1' ? await buildBlockMap() : null;
for (let pass = 0; pass < maxPasses && pending.size; pass += 1) {
  const pendingAtPassStart = pending.size;
  const tried = new Set();
  const matched = new Set();
  for (let page = fromPage; page <= toPage && pending.size; page += 1) {
    const png = renderPage(page);
    const blocksHere = blockMap
      ? (blockMap.get(page) ?? []).filter((b) => !skipBlocks.has(b))
      : [];
    const askLimit = blockMap ? blocksHere.length : maxSweeps;
    for (let sweep = 0; sweep < askLimit && pending.size; sweep += 1) {
      const order = blockMap
        ? [...pending].sort((a, b) => a - b).filter(
            (p) => blockIndexes[p] === blocksHere[sweep],
          )
        : windowOf(pending, skipBlocks);
      if (!order.length) continue;
      const block = blockIndexes[order[0]];
      tried.add(block);
      const items = await askPage(page, png, order);
      const hit = [];
      for (const item of items) {
        if (mode === 'answer' && !String(item.answer_text || '').trim()) continue;
        let position = -1;
        const at = item.expected_index;
        if (Number.isInteger(at) && at >= 0 && at < order.length) {
          position = order[at];
        } else {
          const key = numberKey(item.problem_number);
          position =
            order.find((p) => numberKey(targets[p].problem_number) === key) ?? -1;
        }
        if (position < 0 || !pending.delete(position)) continue;
        hit.push(targets[position].key);
      }
      console.log(
        `p${page} 블록${block}: 보낸 ${order.length} · 반환 ${items.length} · 매칭 ${hit.length} · 남은 ${pending.size}`,
      );
      if (hit.length) {
        matched.add(block);
        console.log(`   ${hit.join(' | ')}`);
      } else if (!blockMap) {
        break;
      }
    }
  }
  const stuck = [...tried].filter((b) => !matched.has(b));
  for (const b of stuck) skipBlocks.add(b);
  console.log(
    `[pass ${pass}] 매칭 ${pendingAtPassStart - pending.size} · 남은 ${pending.size} · 건너뛸 블록 ${stuck.length}`,
  );
  if (pending.size === pendingAtPassStart && !stuck.length) break;
}

console.log(`\n끝까지 못 찾은 ${pending.size}건:`);
for (const i of [...pending].sort((a, b) => a - b)) console.log(`  ${targets[i].key}`);
process.exit(0);
