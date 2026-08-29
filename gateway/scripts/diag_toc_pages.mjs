// 목차 VLM 판독을 매니저 앱과 같은 조건으로 재현한다.
//
// 앱은 고른 쪽을 긴 변 1600px PNG 로 래스터해 parseTocPages 에 넘긴다. 실패가
// 지면 탓인지 해상도·출력한도 탓인지 가리려면 같은 입력으로 한 번 불러
// finishReason·토큰·단원 수를 봐야 한다.
//
// 사용:
//   node scripts/diag_toc_pages.mjs --pdf "<경로>" --from 4 --to 5 \
//     [--series suryeok] [--long-edge 1600]

import 'dotenv/config';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';
import {
  parseTocPages,
  normalizeTocResult,
} from '../src/textbook/vlm_toc_client.js';

const execFileAsync = promisify(execFile);

function arg(name, fallback = '') {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 ? process.argv[at + 1] ?? fallback : fallback;
}

const pdfPath = arg('pdf');
const from = Number(arg('from'));
const to = Number(arg('to'));
const series = arg('series', 'suryeok');
const longEdge = Number(arg('long-edge', '1600'));
if (!pdfPath || !Number.isFinite(from) || !Number.isFinite(to)) {
  console.error('usage: --pdf <경로> --from <쪽> --to <쪽> [--series s] [--long-edge n]');
  process.exit(1);
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'toc-diag-'));
const base = path.join(dir, 'p');
await execFileAsync(
  'pdftoppm',
  ['-png', '-f', String(from), '-l', String(to), '-scale-to', String(longEdge), pdfPath, base],
  { timeout: 180000, windowsHide: true },
);
const files = fs
  .readdirSync(dir)
  .filter((name) => name.endsWith('.png'))
  .sort();
if (files.length === 0) throw new Error('render_produced_no_pages');

const images = files.map((name) => ({
  imageBase64: fs.readFileSync(path.join(dir, name)).toString('base64'),
  mimeType: 'image/png',
}));
for (const name of files) {
  const bytes = fs.statSync(path.join(dir, name)).size;
  console.log(`page ${name}: ${Math.round(bytes / 1024)}KB`);
}

const result = await parseTocPages({
  images,
  series,
  model: process.env.PB_GEMINI_MODEL || 'gemini-3.1-pro-preview',
  apiKey: process.env.GEMINI_API_KEY,
  timeoutMs: 300000,
  maxRetries: 1,
});
const normalized = normalizeTocResult(result.parsedJson);

const outDir = path.join(process.cwd(), '.tmp_toc_dump');
fs.mkdirSync(outDir, { recursive: true });
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const outPath = path.join(outDir, `toc_p${from}-${to}_${longEdge}px_${stamp}.json`);
fs.writeFileSync(
  outPath,
  JSON.stringify({ raw: result.parsedJson, normalized }, null, 2),
);

console.log('finishReason:', result.finishReason);
console.log('elapsedMs   :', result.elapsedMs);
console.log('usage       :', JSON.stringify(result.usageMetadata));
console.log('big_units   :', normalized.big_units.length);
for (const big of normalized.big_units) {
  const subs = big.mid_units.reduce((acc, m) => acc + m.sub_units.length, 0);
  console.log(
    `  ${big.name}: mid=${big.mid_units.length} sub=${subs}` +
      ` [${big.mid_units.map((m) => m.name).join(' / ')}]`,
  );
}
console.log('appendix    :', normalized.appendix_boundary_page);
console.log('notes       :', normalized.notes);
console.log('dump        :', outPath);
fs.rmSync(dir, { recursive: true, force: true });
