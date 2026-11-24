// 임시: 대단원 하나의 "저장된 정답 → 머리글로 다시 읽은 정답" 변경 목록(DB 쓰기 없음).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const grade = process.argv[2];
const big = Number(process.argv[3]);
const dir = path.join(os.tmpdir(), 'layout_probe');
const body = JSON.parse(fs.readFileSync(path.join(dir, `body_${grade}.json`), 'utf8')).rows;
const num = (s) => { const m = /\d+/.exec(String(s ?? '')); return m ? Number(m[0]) : NaN; };
const norm = (s) => String(s ?? '').replace(/\$|\s|\\left|\\right|\\,|\\!|\\displaystyle/g, '').replace(/\\dfrac/g, '\\frac');

const bodyBlocks = [];
let cur = null;
for (const r of body) {
  if (r.sh) continue;
  const n = num(r.pn);
  if (!Number.isFinite(n)) continue;
  const key = `${r.b}/${r.m}/${r.sk}`;
  if (!cur || cur.key !== key || n <= cur.last) { cur = { key, b: r.b, ps: r.dp, pe: r.dp, items: [], last: 0 }; bodyBlocks.push(cur); }
  cur.items.push(r); cur.pe = r.dp; cur.last = n;
}
const ansDir = path.join(dir, `${grade}_ans`);
const pages = fs.readdirSync(ansDir).filter((f) => /^p\d+\.json$/.test(f)).map((f) => Number(f.slice(1, -5))).sort((a, b) => a - b);
const ansBlocks = [];
let ab = null;
for (const p of pages) {
  const j = JSON.parse(fs.readFileSync(path.join(ansDir, `p${p}.json`), 'utf8'));
  const es = (j.entries || []).slice().sort((a, b) => {
    const ca = (a.bbox?.[1] ?? 0) < 490 ? 0 : 1;
    const cb = (b.bbox?.[1] ?? 0) < 490 ? 0 : 1;
    return ca - cb || (a.bbox?.[0] ?? 0) - (b.bbox?.[0] ?? 0) || (a.bbox?.[1] ?? 0) - (b.bbox?.[1] ?? 0);
  });
  for (const e of es) {
    if (e.kind === 'header') { ab = { title: e.title, ps: e.page_start || 0, pe: e.page_end || 0, page: p, answers: [] }; ansBlocks.push(ab); }
    else if (ab) ab.answers.push({ ...e, page: p });
  }
}
const used = new Set();
const out = [];
const sum = { blocks: 0, items: 0, same: 0, posOnly: 0, textDiff: 0, noNew: 0, noStored: 0, newImage: 0 };
const boxOf = (v) => (Array.isArray(v) ? v : typeof v === 'string' ? JSON.parse(v.replace(/^\{/, '[').replace(/\}$/, ']')) : null);
const near = (a, b) => a && b && a.length === 4 && b.length === 4 && a.every((v, i) => Math.abs(v - b[i]) <= 25);
for (const bb of bodyBlocks) {
  let idx = ansBlocks.findIndex((a, i) => !used.has(i) && a.ps === bb.ps && a.pe === bb.pe);
  if (idx < 0) idx = ansBlocks.findIndex((a, i) => !used.has(i) && a.ps && a.ps <= bb.ps && a.pe >= bb.pe);
  if (idx < 0) { if (bb.b === big) out.push({ block: bb.key, ps: bb.ps, error: '머리글 없음' }); continue; }
  used.add(idx);
  if (bb.b !== big) continue;
  const a = ansBlocks[idx];
  const an = new Map();
  for (const x of a.answers) if (Number.isFinite(num(x.problem_number)) && !an.has(num(x.problem_number))) an.set(num(x.problem_number), x);
  sum.blocks += 1;
  const blk = { block: bb.key, title: a.title, body: `p${bb.ps}~${bb.pe}`, ansPage: a.page, n: bb.items.length, same: 0, posOnly: 0, textDiff: 0, rows: [] };
  for (const r of bb.items) {
    sum.items += 1;
    const x = an.get(num(r.pn));
    if (!x) { sum.noNew += 1; blk.rows.push({ dp: r.dp, pn: r.pn, kind: '새로 못 읽음', old: r.ans }); continue; }
    if (x.kind === 'image') sum.newImage += 1;
    if (r.ans == null) { sum.noStored += 1; blk.rows.push({ dp: r.dp, pn: r.pn, kind: '저장 없음', neu: x.answer_text }); continue; }
    const sameText = x.kind === 'image' ? true : norm(r.ans) === norm(x.answer_text);
    const samePos = Number(r.ap) === x.page && near(boxOf(r.abox), boxOf(x.bbox));
    if (sameText && samePos) { sum.same += 1; blk.same += 1; }
    else if (sameText) { sum.posOnly += 1; blk.posOnly += 1; blk.rows.push({ dp: r.dp, pn: r.pn, kind: '좌표만 다름', old: `p${r.ap} ${JSON.stringify(boxOf(r.abox))}`, neu: `p${x.page} ${JSON.stringify(x.bbox)}`, ans: r.ans }); }
    else { sum.textDiff += 1; blk.textDiff += 1; blk.rows.push({ dp: r.dp, pn: r.pn, kind: '값 다름', old: `${r.ans} (p${r.ap})`, neu: `${x.answer_text} (p${x.page})` }); }
  }
  out.push(blk);
}
fs.writeFileSync(path.join(dir, `diff_${grade}_${big}.json`), JSON.stringify(out, null, 1));
console.log(JSON.stringify(sum));
for (const b of out) console.log(b.error ? `${b.block} p${b.ps} ${b.error}` : `${b.block} "${b.title}" ${b.body} 정답지p${b.ansPage}: ${b.n}문항 같음 ${b.same} 좌표만 ${b.posOnly} 값다름 ${b.textDiff}`);
