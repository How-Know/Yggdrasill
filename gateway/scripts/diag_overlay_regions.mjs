// 감지 결과의 item_region / bbox 를 페이지 이미지 위에 그려 크롭 위치를 눈으로 확인한다.
// 사용: node scripts/diag_overlay_regions.mjs --pdf <경로> --page 22 --series suryeok [--sub A] [--out tmp_overlay]
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';

const run = promisify(execFile);
const args = process.argv.slice(2);
const arg = (name, fallback = '') => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : fallback;
};

const pdf = arg('pdf');
const page = Number(arg('page'));
const series = arg('series', 'suryeok');
const sub = arg('sub', 'A');
const outDir = arg('out', 'tmp_overlay');
const base = arg('base', process.env.PB_API_BASE || 'http://127.0.0.1:8787');

if (!pdf || !Number.isFinite(page)) {
  console.error('--pdf 와 --page 는 필수입니다.');
  process.exit(1);
}

await mkdir(outDir, { recursive: true });
const prefix = path.join(outDir, `p${page}`);
await run('pdftoppm', ['-png', '-r', '150', '-f', String(page), '-l', String(page), pdf, prefix]);
const pngPath = `${prefix}-${String(page).padStart(3, '0')}.png`;
const buf = await readFile(pngPath);
const meta = await sharp(buf).metadata();

const hint = series === 'suryeok' ? (sub === 'B' ? 'unit_review' : 'type_problem') : '';
const res = await fetch(`${base}/textbook/vlm/detect-problems`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify({
    image_base64: buf.toString('base64'),
    raw_page: page,
    display_page: page,
    series,
    ...(hint ? { section_hint: hint } : {}),
  }),
});
const json = await res.json().catch(() => ({}));
const result = json.result ?? json;
const items = result?.items ?? [];
console.log(`p${page} items=${items.length} notes=${result?.notes || '-'}`);

const rects = [];
for (const item of items) {
  const label = `${item.number}`;
  if (Array.isArray(item.item_region)) {
    const [y0, x0, y1, x1] = item.item_region;
    rects.push(
      `<rect x="${(x0 / 1000) * meta.width}" y="${(y0 / 1000) * meta.height}" width="${((x1 - x0) / 1000) * meta.width}" height="${((y1 - y0) / 1000) * meta.height}" fill="none" stroke="#1e88e5" stroke-width="3"/>`,
      `<text x="${(x0 / 1000) * meta.width + 4}" y="${(y0 / 1000) * meta.height + 22}" font-size="20" fill="#1e88e5">${label}</text>`,
    );
  }
  if (Array.isArray(item.bbox)) {
    const [y0, x0, y1, x1] = item.bbox;
    rects.push(
      `<rect x="${(x0 / 1000) * meta.width}" y="${(y0 / 1000) * meta.height}" width="${((x1 - x0) / 1000) * meta.width}" height="${((y1 - y0) / 1000) * meta.height}" fill="none" stroke="#e53935" stroke-width="2"/>`,
    );
  }
}
const svg = `<svg width="${meta.width}" height="${meta.height}" xmlns="http://www.w3.org/2000/svg">${rects.join('')}</svg>`;
const outPath = path.join(outDir, `p${page}_overlay.png`);
await sharp(buf).composite([{ input: Buffer.from(svg), top: 0, left: 0 }]).toFile(outPath);
console.log(`saved ${outPath}`);
