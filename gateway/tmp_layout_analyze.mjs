// 임시 분석 스크립트: 읽은 머리글이 본문 블록과 맞는지 코드로 검사한다(DB 쓰기 없음).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const grade = process.argv[2];
const verbose = process.argv[3] === '-v';
const dir = path.join(os.tmpdir(), 'layout_probe');
const body = JSON.parse(fs.readFileSync(path.join(dir, `body_${grade}.json`), 'utf8')).rows;
const num = (s) => { const m = /\d+/.exec(String(s ?? '')); return m ? Number(m[0]) : NaN; };
const norm = (s) => String(s ?? '').replace(/\$|\s|\\left|\\right|\\,|\\!|\\displaystyle/g, '').replace(/\\dfrac/g, '\\frac');

// 본문 블록: 소단원 키가 바뀌거나 번호가 되돌아가는 곳에서 끊는다.
const bodyBlocks = [];
let cur = null;
for (const r of body) {
  if (r.sh) continue;
  const n = num(r.pn);
  if (!Number.isFinite(n)) continue;
  const key = `${r.b}/${r.m}/${r.sk}`;
  if (!cur || cur.key !== key || n <= cur.last) {
    cur = { key, ps: r.dp, pe: r.dp, items: [], last: 0 };
    bodyBlocks.push(cur);
  }
  cur.items.push(r);
  cur.pe = r.dp;
  cur.last = n;
}

// 정답 지면 블록: 읽는 차례(단 → 위에서 아래)로 머리글마다 끊는다.
const ansDir = path.join(dir, `${grade}_ans`);
const pages = fs.readdirSync(ansDir).filter((f) => /^p\d+\.json$/.test(f)).map((f) => Number(f.slice(1, -5))).sort((a, b) => a - b);
const ansBlocks = [];
let ab = null;
let orphan = 0;
for (const p of pages) {
  const j = JSON.parse(fs.readFileSync(path.join(ansDir, `p${p}.json`), 'utf8'));
  const es = (j.entries || []).slice().sort((a, b) => {
    const ca = (a.bbox?.[1] ?? 0) < 490 ? 0 : 1;
    const cb = (b.bbox?.[1] ?? 0) < 490 ? 0 : 1;
    return ca - cb || (a.bbox?.[0] ?? 0) - (b.bbox?.[0] ?? 0) || (a.bbox?.[1] ?? 0) - (b.bbox?.[1] ?? 0);
  });
  for (const e of es) {
    if (e.kind === 'header') {
      ab = { title: e.title, ps: e.page_start || 0, pe: e.page_end || 0, page: p, answers: [] };
      ansBlocks.push(ab);
    } else if (ab) {
      ab.answers.push({ ...e, page: p });
    } else orphan += 1;
  }
}

console.log(`본문 블록 ${bodyBlocks.length}개 (문항 ${bodyBlocks.reduce((s, b) => s + b.items.length, 0)}), 정답지 머리글 ${ansBlocks.length}개 (답 ${ansBlocks.reduce((s, b) => s + b.answers.length, 0)}, 머리글 없는 답 ${orphan})`);

// 머리글 자체 검사
const noPage = ansBlocks.filter((b) => !b.ps);
let backward = 0;
let prevEnd = 0;
for (const b of ansBlocks) {
  if (!b.ps) continue;
  if (b.ps < prevEnd) backward += 1;
  prevEnd = Math.max(prevEnd, b.pe || b.ps);
}
console.log(`머리글: 쪽 범위 못 읽음 ${noPage.length}, 쪽이 뒤로 감 ${backward}`);
if (verbose) for (const b of noPage) console.log(`  쪽 없음: p${b.page} "${b.title}" 답 ${b.answers.length}`);

// 본문 블록 ↔ 머리글 (시작 쪽·끝 쪽이 같은 것끼리, 같은 쪽 범위가 여럿이면 차례대로)
const used = new Set();
let exact = 0, countOk = 0, numsOk = 0, noHeader = 0;
let cmpTotal = 0, cmpSame = 0, storedMissing = 0;
const bad = [];
for (const bb of bodyBlocks) {
  let idx = ansBlocks.findIndex((a, i) => !used.has(i) && a.ps === bb.ps && a.pe === bb.pe);
  if (idx < 0) idx = ansBlocks.findIndex((a, i) => !used.has(i) && a.ps && a.ps <= bb.ps && a.pe >= bb.pe);
  if (idx < 0) { noHeader += 1; bad.push(`머리글 없음: 본문 p${bb.ps}~${bb.pe} ${bb.key} ${bb.items.length}문항`); continue; }
  used.add(idx);
  const a = ansBlocks[idx];
  exact += 1;
  const an = new Map();
  for (const x of a.answers) {
    const m = /^(\d+)\s*[~\-]\s*(\d+)$/.exec(String(x.problem_number ?? '').trim());
    if (m) for (let k = Number(m[1]); k <= Number(m[2]); k += 1) an.set(k, x);
    else if (Number.isFinite(num(x.problem_number)) && !an.has(num(x.problem_number))) an.set(num(x.problem_number), x);
  }
  const bn = bb.items.map((r) => num(r.pn));
  const sameCount = an.size === bn.length;
  const sameNums = sameCount && bn.every((n) => an.has(n));
  if (sameCount) countOk += 1;
  if (sameNums) numsOk += 1;
  else bad.push(`번호 불일치: 본문 p${bb.ps}~${bb.pe} ${bb.key} 본문 ${bn.length}개(${bn[0]}~${bn[bn.length - 1]}) / 정답지 ${an.size}개 "${a.title}" (정답지 p${a.page})`);
  // 저장된 정답과 이번에 읽은 정답 비교
  for (const r of bb.items) {
    const x = an.get(num(r.pn));
    if (!x || x.kind === 'image') continue;
    if (r.ans == null) { storedMissing += 1; continue; }
    cmpTotal += 1;
    if (norm(r.ans) === norm(x.answer_text)) cmpSame += 1;
    else if (verbose) r._diff = x.answer_text;
  }
  bb._a = a;
}
const unusedHeaders = ansBlocks.filter((_, i) => !used.has(i));
console.log(`본문 블록 중 머리글과 쪽 범위가 맞은 것 ${exact}/${bodyBlocks.length}, 그중 문항 수 같음 ${countOk}, 번호까지 같음 ${numsOk}`);
console.log(`본문 블록에 안 쓰인 머리글 ${unusedHeaders.length}개`);
console.log(`저장된 정답 vs 이번에 읽은 정답: 비교 ${cmpTotal}건 중 같음 ${cmpSame} (${(100 * cmpSame / Math.max(1, cmpTotal)).toFixed(1)}%), 저장된 정답 없음 ${storedMissing}`);
// 소단원 종류별 일치율
const byKind = new Map();
for (const bb of bodyBlocks) {
  if (!bb._a) continue;
  const an = new Map();
  for (const x of bb._a.answers) if (Number.isFinite(num(x.problem_number)) && !an.has(num(x.problem_number))) an.set(num(x.problem_number), x);
  const k = bb.key.split('/')[2];
  const s = byKind.get(k) ?? { total: 0, same: 0, blocks: 0, badBlocks: 0 };
  let t = 0, sm = 0;
  for (const r of bb.items) {
    const x = an.get(num(r.pn));
    if (!x || x.kind === 'image' || r.ans == null) continue;
    t += 1;
    if (norm(r.ans) === norm(x.answer_text)) sm += 1;
  }
  s.total += t; s.same += sm; s.blocks += 1;
  if (t > 0 && sm / t < 0.5) s.badBlocks += 1;
  byKind.set(k, s);
}
for (const [k, s] of byKind) console.log(`  소단원 키 ${k}: 블록 ${s.blocks}개, 정답 일치 ${s.same}/${s.total}, 절반도 안 맞는 블록 ${s.badBlocks}개`);
console.log(`--- 문제 목록 (${bad.length})`);
for (const b of bad.slice(0, verbose ? 200 : 25)) console.log('  ' + b);
if (verbose) for (const h of unusedHeaders) console.log(`  안 쓰인 머리글: 정답지 p${h.page} "${h.title}" p.${h.ps}~${h.pe} 답 ${h.answers.length}`);
