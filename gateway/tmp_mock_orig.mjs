// 임시: 모의고사 시험지 PDF 에서 문항 자리만 잘라 build_side/<이름>.png 로 둔다(읽기 전용).
//   node tmp_mock_orig.mjs <회차 id> <구간> <번호> <이름> [--papers]
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import sharp from 'sharp';
import { createClient } from '@supabase/supabase-js';

const [examId, section, number, name] = process.argv.slice(2);
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const tmpDir = path.join(process.env.LOCALAPPDATA, 'Yggdrasill', 'tmp_books');
fs.mkdirSync(tmpDir, { recursive: true });
const { data: papers } = await supa.from('mock_exam_papers').select('*').eq('exam_id', examId);
if (process.argv.includes('--papers')) {
  for (const p of papers || []) {
    console.log(Object.entries(p).filter(([k]) => !/sha|hash|token|key/i.test(k)).map(([k, v]) => `${k}=${String(v).slice(0, 50)}`).join(' | '));
  }
  process.exit(0);
}
const { data: item } = await supa.from('mock_exam_items').select('raw_page, item_region_1k, section, problem_number')
  .eq('exam_id', examId).eq('section', section).eq('problem_number', Number(number)).maybeSingle();
if (!item) {
  console.log('자리 없음');
  process.exit(1);
}
const paper = (papers || []).find((p) => p.kind === 'problem' && (String(p.elective || '') === section || !p.elective));
if (!paper) {
  console.log('시험지 없음');
  process.exit(1);
}
const pdf = path.join(tmpDir, `mock_${paper.id}.pdf`);
if (!fs.existsSync(pdf)) {
  const { data, error } = await supa.storage.from(paper.storage_bucket || 'problem-documents').download(paper.storage_path);
  if (error || !data) {
    console.log('내려받기 실패');
    process.exit(1);
  }
  fs.writeFileSync(pdf, Buffer.from(await data.arrayBuffer()));
}
const prefix = path.join(tmpDir, `mock_page_${paper.id}_${item.raw_page}`);
execFileSync('pdftoppm', ['-r', '120', '-png', '-f', String(item.raw_page), '-l', String(item.raw_page), '-singlefile', pdf, prefix], { stdio: 'ignore' });
const meta = await sharp(`${prefix}.png`).metadata();
const [y0, x0, y1, x1] = item.item_region_1k;
const pad = 10;
const left = Math.max(0, Math.round((x0 / 1000) * meta.width) - pad);
const top = Math.max(0, Math.round((y0 / 1000) * meta.height) - pad);
const width = Math.min(meta.width - left, Math.round(((x1 - x0) / 1000) * meta.width) + pad * 2);
const height = Math.min(meta.height - top, Math.round(((y1 - y0) / 1000) * meta.height) + pad * 2);
await sharp(`${prefix}.png`).extract({ left, top, width, height }).png().toFile(path.resolve('build_side', `${name}.png`));
fs.rmSync(`${prefix}.png`);
console.log(`원본 ${name}.png ${width}x${height} (쪽 ${item.raw_page})`);
