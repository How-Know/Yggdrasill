// 임시 측정 스크립트: 수력충전 빠른 정답 지면에서 소단원 머리글만 읽어 본다(DB 쓰기 없음).
// 사용: node tmp_layout_probe.mjs <grade_label> <kind> <from> <to>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const env = Object.fromEntries(
  fs.readFileSync(new URL('./.env', import.meta.url), 'utf8').split(/\r?\n/)
    .map((l) => /^([A-Z0-9_]+)\s*=\s*(.*)$/.exec(l.trim())).filter(Boolean)
    .map((m) => [m[1], m[2].replace(/^["']|["']$/g, '')]),
);
const base = `http://127.0.0.1:${env.PB_API_PORT || '8787'}`;
const headers = { 'Content-Type': 'application/json', ...(env.PB_API_KEY ? { 'x-api-key': env.PB_API_KEY } : {}) };
const ACADEMY = '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677';
const BOOK = '09d8c890-a69f-4814-b57d-e16b0bf88432';
const [grade, kind, fromS, toS] = process.argv.slice(2);
const outDir = path.join(os.tmpdir(), 'layout_probe', `${grade}_${kind}`);
fs.mkdirSync(outDir, { recursive: true });
const pdfPath = path.join(os.tmpdir(), `probe_${BOOK}_${grade}_${kind}.pdf`);

if (!fs.existsSync(pdfPath)) {
  const qp = new URLSearchParams({ academy_id: ACADEMY, file_id: BOOK, grade_label: grade, kind });
  const r = await fetch(`${base}/textbook/pdf/download-url?${qp}`, { headers });
  const j = await r.json();
  if (!r.ok || !j.ok || !j.url) {
    console.log('download-url failed', r.status, j.error || '');
    process.exit(1);
  }
  console.log('downloading', kind, 'migration', j.migration_status, 'size', j.file_size_bytes ?? '?');
  const d = await fetch(j.url);
  if (!d.ok) { console.log('download failed', d.status); process.exit(1); }
  fs.writeFileSync(pdfPath, Buffer.from(await d.arrayBuffer()));
}
console.log('pdf', path.basename(pdfPath), fs.statSync(pdfPath).size);
if (!fromS) process.exit(0);

for (let p = Number(fromS); p <= Number(toS); p += 1) {
  const jsonPath = path.join(outDir, `p${p}.json`);
  if (fs.existsSync(jsonPath)) continue;
  const prefix = path.join(outDir, `p${p}`);
  execFileSync('pdftoppm', ['-png', '-singlefile', '-scale-to', '2400', '-f', String(p), '-l', String(p), pdfPath, prefix]);
  const png = fs.readFileSync(`${prefix}.png`);
  const t0 = Date.now();
  const r = await fetch(`${base}/textbook/vlm/${kind === 'sol' ? 'detect-solution-blocks' : 'extract-answer-layout'}`, {
    method: 'POST', headers,
    body: JSON.stringify({ image_base64: png.toString('base64'), mime_type: 'image/png', raw_page: p }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.ok) { console.log(`p${p} FAILED ${r.status} ${j.error || ''} ${j.message || ''}`); continue; }
  fs.writeFileSync(jsonPath, JSON.stringify(j));
  if (kind === 'sol') {
    console.log(`p${p} ${((Date.now() - t0) / 1000).toFixed(0)}s blocks=${(j.blocks || []).length} numbers=${(j.numbers || []).length} lead=${j.leading_continuation}`);
    continue;
  }
  const entries = j.entries || [];
  const heads = entries.filter((e) => e.kind === 'header');
  console.log(`p${p} ${((Date.now() - t0) / 1000).toFixed(0)}s entries=${entries.length} headers=${heads.length} lead=${j.leading_continuation}`);
}
