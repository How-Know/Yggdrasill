// 임시: 대단원 하나의 해설 좌표를 머리글 기준으로 다시 맞춰 저장값과 비교(DB 쓰기 없음).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const grade = process.argv[2];
const dir = path.join(os.tmpdir(), 'layout_probe');
const rows = JSON.parse(fs.readFileSync(path.join(dir, `big0_${grade}.json`), 'utf8')).rows;
const num = (s) => { const m = /\d+/.exec(String(s ?? '')); return m ? Number(m[0]) : NaN; };
const arr = (v) => (Array.isArray(v) ? v.map(Number) : typeof v === 'string' ? JSON.parse(v.replace(/^\{/, '[').replace(/\}$/, ']')) : null);

const bodyBlocks = [];
let cur = null;
for (const r of rows) {
  if (r.sh) continue;
  const n = num(r.pn);
  if (!Number.isFinite(n)) continue;
  const key = `${r.m}/${r.sk}`;
  if (!cur || cur.key !== key || n <= cur.last) { cur = { key, ps: r.dp, pe: r.dp, items: [], last: 0 }; bodyBlocks.push(cur); }
  cur.items.push(r); cur.pe = r.dp; cur.last = n;
}

const solDir = path.join(dir, `${grade}_sol`);
const pages = fs.readdirSync(solDir).filter((f) => /^p\d+\.json$/.test(f)).map((f) => Number(f.slice(1, -5))).sort((a, b) => a - b);
const solBlocks = [];
let sb = null;
let orphan = 0;
for (const p of pages) {
  const j = JSON.parse(fs.readFileSync(path.join(solDir, `p${p}.json`), 'utf8'));
  for (const e of j.sequence || []) {
    if (e.kind === 'header') { sb = { title: e.title, ps: e.page_start || 0, pe: e.page_end || 0, page: p, nums: [] }; solBlocks.push(sb); }
    else if (e.kind === 'number') { if (sb) sb.nums.push({ ...e, page: p }); else orphan += 1; }
  }
}
const noPage = solBlocks.filter((b) => !b.ps).length;
let backward = 0, prevEnd = 0;
for (const b of solBlocks) { if (!b.ps) continue; if (b.ps < prevEnd) backward += 1; prevEnd = Math.max(prevEnd, b.pe || b.ps); }
console.log(`해설 머리글 ${solBlocks.length}개 (쪽 범위 못 읽음 ${noPage}, 뒤로 감 ${backward}), 번호 ${solBlocks.reduce((s, b) => s + b.nums.length, 0)}, 머리글 없는 번호 ${orphan}`);

const near = (a, b, t) => a && b && a.every((v, i) => Math.abs(v - b[i]) <= t);
const used = new Set();
const sum = { blocks: 0, matched: 0, numsOk: 0, items: 0, same: 0, numMoved: 0, pageDiff: 0, contentDiff: 0, noNew: 0, thinOld: 0, thinNew: 0 };
const out = [];
for (const bb of bodyBlocks) {
  sum.blocks += 1;
  const idx = solBlocks.findIndex((a, i) => !used.has(i) && a.ps === bb.ps && a.pe === bb.pe);
  if (idx < 0) { console.log(`  머리글 못 찾음: 본문 p${bb.ps}~${bb.pe} ${bb.key} ${bb.items.length}문항`); continue; }
  used.add(idx);
  sum.matched += 1;
  const a = solBlocks[idx];
  const an = new Map();
  for (const x of a.nums) if (Number.isFinite(num(x.text)) && !an.has(num(x.text))) an.set(num(x.text), x);
  const bn = bb.items.map((r) => num(r.pn));
  const ok = an.size === bn.length && bn.every((n) => an.has(n));
  if (ok) sum.numsOk += 1;
  else console.log(`  번호 불일치: 본문 p${bb.ps}~${bb.pe} ${bb.key} 본문 ${bn.length}개 / 해설 ${an.size}개 "${a.title}" (해설 p${a.page}) 본문에만: ${bn.filter((n) => !an.has(n)).join(',')} 해설에만: ${[...an.keys()].filter((n) => !bn.includes(n)).join(',')}`);
  const blk = { key: bb.key, title: a.title, body: `p${bb.ps}~${bb.pe}`, same: 0, changed: [] };
  for (const r of bb.items) {
    sum.items += 1;
    const x = an.get(num(r.pn));
    if (!x) { sum.noNew += 1; continue; }
    const on = arr(r.snum), oc = arr(r.scon), nn = arr(x.number_region), nc = arr(x.content_region);
    const thinOld = oc && oc[2] - oc[0] <= 25;
    const thinNew = nc && nc[2] - nc[0] <= 25;
    if (thinOld) sum.thinOld += 1;
    if (thinNew) sum.thinNew += 1;
    let kind = '';
    if (Number(r.sp) !== x.page) { kind = '쪽 다름'; sum.pageDiff += 1; }
    else if (!near(on, nn, 30)) { kind = '번호 위치 다름'; sum.numMoved += 1; }
    else if (!near(oc, nc, 40)) { kind = '해설 영역 다름'; sum.contentDiff += 1; }
    else { sum.same += 1; blk.same += 1; continue; }
    blk.changed.push({ id: r.id, dp: r.dp, pn: r.pn, kind, old: `p${r.sp} n${JSON.stringify(on)} c${JSON.stringify(oc)}`, neu: `p${x.page} n${JSON.stringify(nn)} c${JSON.stringify(nc)}` });
  }
  out.push(blk);
}
fs.writeFileSync(path.join(dir, `soldiff_${grade}_0.json`), JSON.stringify(out, null, 1));
console.log(JSON.stringify(sum));
for (const b of out) if (b.changed.length) {
  const k = {};
  for (const c of b.changed) k[c.kind] = (k[c.kind] || 0) + 1;
  console.log(`${b.key} "${b.title}" ${b.body}: 같음 ${b.same}, ${Object.entries(k).map(([a, n]) => `${a} ${n}`).join(', ')}`);
}
