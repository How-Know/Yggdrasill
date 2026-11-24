// 임시: 자리 점검 그림(원본 | 자리 카드)을 한 장으로 붙인다.
//   node tmp_slot_sheet.mjs <이름> <칸 폭> <키1> <키2> ...   (키 예: 6a767ec4_ga_28)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const here = path.dirname(fileURLToPath(import.meta.url));
const dir = path.resolve(here, '..', 'apps', 'yggdrasill_manager', 'build', 'textbook_batch', 'slot');
const [name, widthArg, ...keys] = process.argv.slice(2);
const cellW = Number(widthArg) || 480;
const rows = [];
for (const key of keys) {
  const pair = [];
  for (const kind of ['original', 'slot_card']) {
    const file = path.join(dir, `${key}_${kind}.png`);
    if (!fs.existsSync(file)) {
      pair.push(null);
      continue;
    }
    const buf = await sharp(file).resize({ width: cellW - 16 }).flatten({ background: '#ffffff' }).png().toBuffer();
    pair.push({ buf, height: (await sharp(buf).metadata()).height });
  }
  rows.push(pair);
}
const heights = rows.map((pair) => Math.max(...pair.map((t) => t?.height || 20)) + 16);
const composite = [];
let top = 0;
rows.forEach((pair, r) => {
  pair.forEach((t, c) => {
    if (t) composite.push({ input: t.buf, left: c * cellW + 8, top: top + 8 });
  });
  top += heights[r];
});
const out = path.join(dir, `sheet_${name}.png`);
await sharp({ create: { width: cellW * 2, height: top, channels: 3, background: '#cccccc' } }).composite(composite).png().toFile(out);
console.log(out);
