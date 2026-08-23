// 답지 한 지면을 앱과 같은 해상도로 줄여 판독해 보는 읽기 전용 진단.
//
// 매니저 앱은 장변 1500px 로 렌더해 보낸다. 진단이 200dpi(장변 2300px 남짓)로
// 보내면 모델이 다르게 읽을 수 있어, 앱에서만 나는 누락을 재현하지 못한다.
//
// 사용: node scripts/diag_answer_layout_scaled.mjs --pdf <답지.pdf> --page 10 [--long 1500]
import 'dotenv/config';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';

const arg = (name, fallback = '') => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const pdf = arg('pdf');
const page = Number.parseInt(arg('page', '1'), 10);
const longEdge = Number.parseInt(arg('long', '1500'), 10);
const out = arg('out', '');

const dir = mkdtempSync(join(tmpdir(), 'answer-scaled-'));
execFileSync('pdftoppm', [
  '-png', '-r', '200', '-f', String(page), '-l', String(page), pdf, join(dir, `p${page}`),
]);
const file = readdirSync(dir).find((n) => n.startsWith(`p${page}-`) && n.endsWith('.png'));
const source = sharp(join(dir, file));
const meta = await source.metadata();
const scaled = await source
  .resize(
    meta.width >= meta.height ? { width: longEdge } : { height: longEdge },
  )
  .png()
  .toBuffer();
const scaledMeta = await sharp(scaled).metadata();
console.log(
  `원본 ${meta.width}x${meta.height} → 전송 ${scaledMeta.width}x${scaledMeta.height}`,
);

const gateway = process.env.PB_GATEWAY_URL || 'http://localhost:8787';
const apiKey = process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '';
const res = await fetch(`${gateway}/textbook/vlm/extract-answer-layout`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    ...(apiKey ? { 'x-api-key': apiKey } : {}),
  },
  body: JSON.stringify({
    image_base64: scaled.toString('base64'),
    mime_type: 'image/png',
    raw_page: page,
  }),
});
const json = await res.json();
if (out) writeFileSync(out, JSON.stringify(json, null, 1));
console.log(`요소 ${(json.entries ?? []).length} · 앞머리이어짐=${json.leading_continuation}`);
for (const entry of json.entries ?? []) {
  if (entry.kind === 'header') {
    console.log(`  [머리] "${entry.title}" ${entry.page_start}~${entry.page_end}`);
    continue;
  }
  console.log(
    `   ${String(entry.problem_number).padEnd(6)} ${entry.kind} ` +
      `${String(entry.answer_text).slice(0, 28)}`,
  );
}
