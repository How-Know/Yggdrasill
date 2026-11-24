// 임시: 오성중 1번을 보기 2단으로 찍어 본다(DB 쓰기 없음). 사용: node tmp_bogi_test.mjs <이름> <columns> <widthEm|0=저장값>
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const [name, cols, wEm] = process.argv.slice(2);
const dir = path.join(os.tmpdir(), 'layout_probe');
const rows = JSON.parse(fs.readFileSync(path.join(dir, 'oseong.json'), 'utf8')).rows;
const r = rows.find((x) => Number(x.pn) === 1);
const staged = r.an.staged_changes || {};
const layout = JSON.parse(JSON.stringify(staged.figure_layout || r.pb.layout));
if (Number(wEm) > 0) for (const it of layout.items) it.widthEm = Number(wEm);
const meta = { figure_assets: staged.figure_assets || r.pb.figs, figure_layout: layout };
if (Number(cols) === 2) layout.bogiColumns = 2;
const env = Object.fromEntries(
  fs.readFileSync(new URL('./.env', import.meta.url), 'utf8').split(/\r?\n/)
    .map((l) => /^([A-Z0-9_]+)\s*=\s*(.*)$/.exec(l.trim())).filter(Boolean)
    .map((m) => [m[1], m[2].replace(/^["']|["']$/g, '')]),
);
const base = `http://127.0.0.1:${env.PB_API_PORT || '8787'}`;
const headers = { 'Content-Type': 'application/json', ...(env.PB_API_KEY ? { 'x-api-key': env.PB_API_KEY } : {}) };
const res = await fetch(`${base}/pb/preview/custom-thumbnail`, {
  method: 'POST', headers,
  body: JSON.stringify({ academyId: '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677', question: { id: `bogi-test-${name}`, document_id: '0dcf14ec-23b0-4fb0-ab32-7a9721ab57e6', question_type: '객관식', stem: r.pb.stem, choices: r.pb.choices, question_number: '1', meta } }),
});
const j = await res.json().catch(() => ({}));
if (!res.ok || !j.ok) { console.log('FAILED', res.status, JSON.stringify(j).slice(0, 400)); process.exit(1); }
const img = await fetch(j.thumbnail.url);
const out = path.join(dir, `bogi_${name}.png`);
fs.writeFileSync(out, Buffer.from(await img.arrayBuffer()));
console.log('saved', out);
