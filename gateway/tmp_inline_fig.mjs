// 임시(읽기만): 2019 수능 나형 18 의 본문 속 작은 그림 두 개가 원본 쪽에서 어디를 잘랐는지 본다.
//   빨강 = AI 가 잰 그림 영역(문항 영역 기준 → 쪽 기준으로 바꿈), 파랑 = 실제로 잘라 저장한 영역.
//   build_side/inline_ctx_<n>.png (주변 포함), build_side/inline_asset_<n>.png (저장된 그림, 4배 확대)
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import sharp from 'sharp';
import { createClient } from '@supabase/supabase-js';

const [examId = '6a767ec4-6a2f-4366-8552-0181580aa2f0', cropId = '962f8b02-a46b-4464-8988-4012033feabe', tag = ''] = process.argv.slice(2);
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const { data: an } = await supa.from('textbook_problem_analyses').select('staged_changes, fix_proposal').eq('crop_id', cropId).maybeSingle();
const measure = an.fix_proposal.figure_measure;
const [ry0, rx0, ry1, rx1] = measure.region_1k;
const toPage = ([y0, x0, y1, x1]) => [
  ry0 + (y0 / 1000) * (ry1 - ry0), rx0 + (x0 / 1000) * (rx1 - rx0),
  ry0 + (y1 / 1000) * (ry1 - ry0), rx0 + (x1 / 1000) * (rx1 - rx0),
];
const { data: papers } = await supa.from('mock_exam_papers').select('*').eq('exam_id', examId);
const paper = (papers || []).find((p) => p.kind === 'problem' && (String(p.elective || '') === 'na' || !p.elective));
const tmpDir = path.join(process.env.LOCALAPPDATA, 'Yggdrasill', 'tmp_books');
fs.mkdirSync(tmpDir, { recursive: true });
const pdf = path.join(tmpDir, `mock_${paper.id}.pdf`);
if (!fs.existsSync(pdf)) {
  const { data } = await supa.storage.from(paper.storage_bucket || 'problem-documents').download(paper.storage_path);
  fs.writeFileSync(pdf, Buffer.from(await data.arrayBuffer()));
}
const prefix = path.join(tmpDir, `inline_page_${measure.raw_page}`);
execFileSync('pdftoppm', ['-r', '300', '-png', '-f', String(measure.raw_page), '-l', String(measure.raw_page), '-singlefile', pdf, prefix], { stdio: 'ignore' });
const page = sharp(`${prefix}.png`);
const meta = await page.metadata();
const px = ([y0, x0, y1, x1]) => ({
  left: Math.round((x0 / 1000) * meta.width), top: Math.round((y0 / 1000) * meta.height),
  width: Math.round(((x1 - x0) / 1000) * meta.width), height: Math.round(((y1 - y0) / 1000) * meta.height),
});
const assets = ((an.staged_changes || {}).figure_assets || []).filter((a) => Array.isArray(a.crop_region_1k));
console.log(`그림 ${(measure.figures || []).map((f, i) => `${i + 1}:${f.placement}/${f.v2_state}`).join(' ')} · 자른 그림 ${assets.length}개`);
for (const asset of assets) {
  const n = `${tag}${asset.figure_index}`;
  if (!measure.figures[asset.figure_index - 1]) continue;
  const ai = toPage(measure.figures[asset.figure_index - 1].bbox_1k);
  const stored = asset.crop_region_1k;
  console.log(`그림 ${n}: AI 영역(쪽) ${ai.map((v) => v.toFixed(1)).join(',')} · 저장 영역 ${stored.join(',')} · 저장 그림 ${asset.width_px}x${asset.height_px}`);
  const ctx = px([stored[0] - 25, stored[1] - 60, stored[2] + 25, stored[3] + 60]);
  const rect = (r, color) => {
    const b = px(r);
    return `<rect x="${b.left - ctx.left}" y="${b.top - ctx.top}" width="${b.width}" height="${b.height}" fill="none" stroke="${color}" stroke-width="2"/>`;
  };
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${ctx.width}" height="${ctx.height}">${rect(ai, 'red')}${rect(stored, 'blue')}</svg>`;
  await sharp(`${prefix}.png`).extract(ctx).composite([{ input: Buffer.from(svg) }]).png().toFile(path.resolve('build_side', `inline_ctx_${n}.png`));
  const { data: img, error } = await supa.storage.from(asset.bucket).download(asset.path);
  if (error || !img) {
    console.log(`그림 ${n} 내려받기 실패`);
    continue;
  }
  await sharp(Buffer.from(await img.arrayBuffer())).resize({ width: asset.width_px * 4, kernel: 'nearest' }).flatten({ background: '#ffffff' }).png()
    .toFile(path.resolve('build_side', `inline_asset_${n}.png`));
}
fs.rmSync(`${prefix}.png`);
