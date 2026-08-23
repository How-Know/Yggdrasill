// 탐지 덤프(입력 이미지 + 정규화 결과)에 크롭 영역을 그려 눈으로 확인한다.
//
// 좌표 숫자만 보면 "덮였다/잘렸다"를 가릴 수 없다. 앱이 실제로 보낸 이미지에
// 그대로 겹쳐 그려야 판단이 선다. 읽기 전용이며 PNG 하나를 새로 만든다.
//
// 사용:
//   node scripts/diag_overlay_dump.mjs .tmp_vlm_dump/detect_1-2_p179_....json
//   [--out <경로>]  기본값은 입력 옆에 _overlay.png
import { readFileSync } from 'node:fs';
import sharp from 'sharp';

const input = process.argv[2];
if (!input) throw new Error('usage: diag_overlay_dump.mjs <dump.json> [--out out.png]');
const outIndex = process.argv.indexOf('--out');
const outPath =
  outIndex > 0 && process.argv[outIndex + 1]
    ? process.argv[outIndex + 1]
    : input.replace(/\.json$/, '_overlay.png');

const dump = JSON.parse(readFileSync(input, 'utf8'));
const image = sharp(input.replace(/\.json$/, '.png'));
const { width, height } = await image.metadata();

const shapes = [];
for (const item of dump.normalized?.items ?? []) {
  const number = String(item.number ?? '');
  if (Array.isArray(item.item_region)) {
    shapes.push({ box: item.item_region, color: '#0066ff', text: `region ${number}` });
  }
  if (Array.isArray(item.bbox)) {
    shapes.push({ box: item.bbox, color: '#ff0000', text: number });
  }
}
for (const header of dump.normalized?.type_headers ?? []) {
  if (!Array.isArray(header.bbox)) continue;
  shapes.push({
    box: header.bbox,
    color: '#00aa00',
    text: `header ${header.label || header.title || ''}`,
  });
}

const rects = shapes
  .map(({ box, color, text }) => {
    const x = Math.round((box[1] / 1000) * width);
    const y = Math.round((box[0] / 1000) * height);
    const w = Math.round(((box[3] - box[1]) / 1000) * width);
    const h = Math.round(((box[2] - box[0]) / 1000) * height);
    return (
      `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="none" ` +
      `stroke="${color}" stroke-width="3"/>` +
      `<text x="${x + 5}" y="${y + 24}" font-size="22" fill="${color}">${text}</text>`
    );
  })
  .join('');

await image
  .composite([
    { input: Buffer.from(`<svg width="${width}" height="${height}">${rects}</svg>`), top: 0, left: 0 },
  ])
  .png()
  .toFile(outPath);

console.log(`${outPath} (${width}x${height}, shapes=${shapes.length})`);
