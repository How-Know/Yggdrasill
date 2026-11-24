// 임시: 교재 본문 PDF 에서 문항 자리만 잘라 build_side/<태그>_orig.png 로 둔다(읽기 전용).
// 교재 PDF 는 저장소 밖(%LOCALAPPDATA%\Yggdrasill\tmp_books)에만 내려받는다.
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import sharp from 'sharp';
import { createClient } from '@supabase/supabase-js';

const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const bookDir = path.join(process.env.LOCALAPPDATA, 'Yggdrasill', 'tmp_books');
const outDir = path.resolve('build_side');
fs.mkdirSync(bookDir, { recursive: true });
const base = 'academies/3ff51b8d-3cfb-4a36-a1a1-b63aebbde677/files';
// [태그, 책, 쪽, [y0, x0, y1, x1] (1000 기준)]
const items = [
  ['bank_개념원리_확률과_통계_확률분포_연습문제_289', 'c3f55a9c-4c87-4c89-8f08-abe9cd35ea72', 132, [123, 150, 230, 695]],
  ['bank_개념원리_확률과_통계_확률분포_연습문제_349', 'c3f55a9c-4c87-4c89-8f08-abe9cd35ea72', 158, [702, 158, 877, 689]],
  ['bank_개념원리_확률과_통계_확률분포_연습문제_355', 'c3f55a9c-4c87-4c89-8f08-abe9cd35ea72', 160, [200, 159, 369, 697]],
  ['bank_쎈_0566', 'c3ae29ad-4d99-4078-8381-00357074d151', 93, [394, 510, 544, 905]],
  ['bank_RPM_0453', '4e51e8cb-f22d-4a0c-bf9d-751a4da69581', 75, [271, 509, 363, 903]],
];
for (const [tag, book, page, [y0, x0, y1, x1]] of items) {
  const pdf = path.join(bookDir, `${book}.pdf`);
  if (!fs.existsSync(pdf)) {
    const { data, error } = await supa.storage.from('textbooks').download(`${base}/${book}/H-probstats/body.pdf`);
    if (error || !data) {
      console.log(`내려받기 실패 ${tag}`);
      continue;
    }
    fs.writeFileSync(pdf, Buffer.from(await data.arrayBuffer()));
  }
  const prefix = path.join(bookDir, `p_${book.slice(0, 8)}_${page}`);
  execFileSync('pdftoppm', ['-r', '130', '-png', '-f', String(page), '-l', String(page), '-singlefile', pdf, prefix], { stdio: 'ignore' });
  const meta = await sharp(`${prefix}.png`).metadata();
  const pad = 12;
  const left = Math.max(0, Math.round((x0 / 1000) * meta.width) - pad - 40);
  const top = Math.max(0, Math.round((y0 / 1000) * meta.height) - pad);
  const width = Math.min(meta.width - left, Math.round(((x1 - x0) / 1000) * meta.width) + pad * 2 + 40);
  const height = Math.min(meta.height - top, Math.round(((y1 - y0) / 1000) * meta.height) + pad * 2);
  await sharp(`${prefix}.png`).extract({ left, top, width, height }).png().toFile(path.join(outDir, `${tag}_orig.png`));
  fs.rmSync(`${prefix}.png`);
  console.log(`원본 ${tag}_orig.png ${width}x${height}`);
}
