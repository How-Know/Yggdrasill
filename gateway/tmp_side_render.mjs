// 표를 본문 옆에 두는 배치를 켜기 전에 실제 문항으로 찍어 보는 임시 도구. DB 는 읽기만 하고 아무것도 올리지 않는다.
//   node tmp_side_render.mjs --list                 대상 문항(본문이 "오른쪽 …표" 라고 적고 raw 표가 하나) 수와 목록 요약
//   node tmp_side_render.mjs --render [--only mock|bank] [--limit N] [--skip N] [--off]
//        build_side/<tag>.png 로 카드를 찍는다. --off 는 지금 배치(표가 본문 아래)로 찍는다.
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import sharp from 'sharp';

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const value = (name, fallback = '') => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};
if (!flag('--off')) process.env.PB_XELATEX_AUTO_TABLE_SIDE = '1';
if (flag('--top')) process.env.PB_XELATEX_AUTO_TABLE_SIDE_PREFER = 'top';
const { renderPdfWithXeLatex } = await import('./src/problem_bank/render_engine/xelatex_v2/renderer.js');

const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(here, 'build_side');
fs.mkdirSync(outDir, { recursive: true });

// --sheet <이름>: build_side 의 카드 그림들을 2열로 붙인 한 장을 만든다(여러 장을 한 번에 보려고).
if (flag('--sheet')) {
  const filter = value('--match');
  const wanted = value('--tags-file')
    ? fs.readFileSync(value('--tags-file'), 'utf8').split(/\r?\n/).map((s) => s.trim()).filter(Boolean)
    : null;
  const files = fs.readdirSync(outDir)
    .filter((f) => f.endsWith('.png') && !f.startsWith('sheet_') && (!filter || f.includes(filter)))
    .filter((f) => !wanted || wanted.includes(f.replace(/\.png$/, '')))
    .sort()
    .slice(Number(value('--skip', '0')), Number(value('--skip', '0')) + Number(value('--limit', '6')));
  const cols = Number(value('--cols', '2'));
  const cellW = cols > 2 ? 470 : 620;
  const tiles = [];
  for (const f of files) {
    const buf = await sharp(path.join(outDir, f)).resize({ width: cellW - 20 }).png().toBuffer();
    const meta = await sharp(buf).metadata();
    tiles.push({ buf, height: meta.height });
  }
  const rowsOf = [];
  for (let i = 0; i < tiles.length; i += cols) rowsOf.push(tiles.slice(i, i + cols));
  const heights = rowsOf.map((r) => Math.max(...r.map((t) => t.height)) + 20);
  const composite = [];
  let top = 0;
  rowsOf.forEach((r, ri) => {
    r.forEach((t, ci) => composite.push({ input: t.buf, left: ci * cellW + 10, top: top + 10 }));
    top += heights[ri];
  });
  const name = `sheet_${value('--sheet', 'a')}.png`;
  await sharp({ create: { width: cellW * cols, height: Math.max(top, 10), channels: 3, background: '#dddddd' } })
    .composite(composite)
    .png()
    .toFile(path.join(outDir, name));
  console.log(`${name}: ${files.join(' | ')}`);
  process.exit(0);
}
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const saysRight = (stem) => {
  const text = String(stem || '');
  if ((text.match(/\[표시작\]/g) || []).length !== 1) return false;
  if (/\[표행\]|\[표\]/.test(text)) return false;
  return /오른쪽\s*[가-힣]{0,10}(?<!좌)표(?=[를을은는의에와과로\s,.])/.test(text);
};

const rows = [];
for (let from = 0; ; from += 500) {
  const { data, error } = await supa
    .from('pb_questions')
    .select('id, document_id, question_number, stem, is_published, meta')
    .like('stem', '%[표시작]%')
    .like('stem', '%오른쪽%')
    .order('id')
    .range(from, from + 499);
  if (error) throw new Error(error.message);
  rows.push(...(data || []));
  if (!data || data.length < 500) break;
}
const targets = rows.filter((q) => saysRight(q.stem)).map((q) => ({
  ...q,
  mock: Boolean(q.meta?.mock_exam_item),
  stored: Array.isArray(q.meta?.table_layout?.items) && q.meta.table_layout.items.length > 0,
}));
const docIds = [...new Set(targets.map((q) => q.document_id).filter(Boolean))];
const titles = new Map();
for (let i = 0; i < docIds.length; i += 100) {
  const { data } = await supa.from('pb_documents').select('id, source_filename, meta').in('id', docIds.slice(i, i + 100));
  for (const d of data || []) titles.set(d.id, String(d.meta?.title || d.source_filename || '').slice(0, 40));
}
const count = (list) => `${list.length}문항(공개 ${list.filter((q) => q.is_published).length}, 표 위치 저장 ${list.filter((q) => q.stored).length})`;
console.log(`"오른쪽"과 표가 든 문항 ${rows.length} → 대상: 모의고사 ${count(targets.filter((q) => q.mock))}, 그 밖의 문제은행 ${count(targets.filter((q) => !q.mock))}`);
if (flag('--list')) {
  const byDoc = new Map();
  for (const q of targets) byDoc.set(q.document_id, [...(byDoc.get(q.document_id) || []), q.question_number]);
  for (const [doc, numbers] of [...byDoc].slice(0, 60)) console.log(`  ${titles.get(doc) || doc}: ${numbers.join(', ')}번`);
  process.exit(0);
}
if (!flag('--render') && !flag('--stems')) process.exit(0);

const fontPath = path.resolve(here, '..', 'apps', 'yggdrasill', 'assets', 'fonts', 'kopub', 'KoPubWorldBatangProLight.otf');
const only = value('--only');
const picked = targets
  .filter((q) => (only === 'mock' ? q.mock : only === 'bank' ? !q.mock : true))
  .slice(Number(value('--skip', '0')), Number(value('--skip', '0')) + Number(value('--limit', '100')));
if (flag('--stems')) {
  for (const t of picked) console.log(`${titles.get(t.document_id)} ${t.question_number}: ${JSON.stringify(String(t.stem).slice(-Number(value('--tail', '420'))))}`);
  process.exit(0);
}
if (flag('--together')) {
  // 여러 문항을 한 시험지(A4 2단, 번호 보임)로 찍어 첫 쪽을 본다.
  const { data: list } = await supa.from('pb_questions').select('*').in('id', picked.map((t) => t.id));
  const questions = (list || []).map((q, i) => {
    const mode = q.allow_objective !== false && Array.isArray(q.choices) && q.choices.length > 0 ? 'objective' : 'subjective';
    return { ...q, question_number: String(i + 1), mode, questionMode: mode };
  });
  const rendered = await renderPdfWithXeLatex({
    questions,
    renderConfig: {
      hidePreviewHeader: true,
      mathEngine: 'xelatex',
      includeCoverPage: false,
      includeAcademyLogo: false,
      includeAnswerSheet: false,
      includeExplanation: false,
      includeQuestionScore: true,
      layoutColumns: 2,
      maxQuestionsPerPage: 8,
    },
    profile: 'naesin',
    paper: 'A4',
    modeByQuestionId: Object.fromEntries(questions.map((q) => [String(q.question_uid || q.id), q.mode])),
    questionMode: 'objective',
    layoutColumns: 2,
    maxQuestionsPerPage: 8,
    renderConfigVersion: 'pb_render_v5_ind_set_split_1',
    fontFamilyRequested: 'KoPubWorldBatangPro',
    fontFamilyResolved: 'KoPubWorldBatangPro',
    fontRegularPath: fontPath,
    fontBoldPath: '',
    fontSize: 11,
    supabaseClient: supa,
  });
  const pdf = path.join(outDir, 'together.pdf');
  fs.writeFileSync(pdf, rendered.bytes);
  execFileSync('pdftoppm', ['-r', '75', '-png', '-f', '1', '-l', '1', '-singlefile', pdf, path.join(outDir, 'sheet_together')]);
  fs.rmSync(pdf);
  console.log(`찍음 sheet_together.png (${questions.length}문항)`);
  process.exit(0);
}
let done = 0;
let failed = 0;
// --tags-file <파일>: 한 줄에 태그 하나. 그 문항만 찍는다.
const tagFilter = value('--tags-file')
  ? fs.readFileSync(value('--tags-file'), 'utf8').split(/\r?\n/).map((s) => s.trim()).filter(Boolean)
  : null;
for (const target of picked) {
  let question = null;
  let error = null;
  for (let attempt = 0; attempt < 4 && !question; attempt += 1) {
    if (attempt > 0) await new Promise((resolve) => setTimeout(resolve, 3000 * attempt));
    ({ data: question, error } = await supa.from('pb_questions').select('*').eq('id', target.id).maybeSingle());
  }
  if (error || !question) {
    console.log(`읽지 못함 ${target.id}: ${String(error?.message || '없음').slice(0, 80)}`);
    continue;
  }
  const choices = Array.isArray(question.choices) ? question.choices : [];
  const mode = question.allow_objective !== false && choices.length > 0 ? 'objective' : 'subjective';
  const baseTag = `${target.mock ? 'mock' : 'bank'}_${String(titles.get(target.document_id) || '').replace(/[^0-9A-Za-z가-힣]+/g, '_').slice(0, 24)}_${target.question_number}`;
  if (tagFilter && !tagFilter.includes(baseTag)) continue;
  if (flag('--originals')) {
    // 교재 원본 조각 그림을 내려받아 <태그>_orig.png 로 둔다(읽기 전용).
    const { data: links } = await supa.from('textbook_crop_question_links').select('crop_id').eq('pb_question_id', target.id).limit(1);
    const cropId = links?.[0]?.crop_id;
    const { data: crop } = cropId
      ? await supa.from('textbook_problem_crops').select('storage_bucket, storage_key').eq('id', cropId).maybeSingle()
      : { data: null };
    if (!crop?.storage_key) {
      console.log(`원본 없음 ${baseTag}`);
      continue;
    }
    const { data: blob, error: dlError } = await supa.storage.from(crop.storage_bucket).download(crop.storage_key);
    if (dlError || !blob) {
      console.log(`원본 내려받기 실패 ${baseTag} | ${crop.storage_bucket} | ${String(crop.storage_key).slice(-40)} | ${String(dlError?.message || dlError?.name || '').slice(0, 80)}`);
      continue;
    }
    await sharp(Buffer.from(await blob.arrayBuffer())).flatten({ background: '#ffffff' }).png().toFile(path.join(outDir, `${baseTag}_orig.png`));
    console.log(`원본 ${baseTag}_orig.png`);
    continue;
  }
  const tag = `${target.mock ? 'mock' : 'bank'}_${String(titles.get(target.document_id) || '').replace(/[^0-9A-Za-z가-힣]+/g, '_').slice(0, 24)}_${target.question_number}${flag('--off') ? '_off' : ''}${flag('--top') ? '_top' : ''}${flag('--paper') ? '_paper' : ''}`;
  try {
    const rendered = await renderPdfWithXeLatex({
      questions: [{ ...question, mode, questionMode: mode }],
      renderConfig: flag('--paper') ? {
        // 시험지처럼: A4 2단, 문항 번호 보임.
        hidePreviewHeader: true,
        mathEngine: 'xelatex',
        includeCoverPage: false,
        includeAcademyLogo: false,
        includeAnswerSheet: false,
        includeExplanation: false,
        includeQuestionScore: true,
        layoutColumns: 2,
        maxQuestionsPerPage: 4,
      } : {
        hidePreviewHeader: true,
        hideQuestionNumber: true,
        mathEngine: 'xelatex',
        disableIndependentSetGrouping: true,
        // 운영의 카드 찍기(batchRenderThumbnails)와 같게: 세트 문항은 공통 발문을 문항마다 붙인다.
        previewIndependentSetCommonStem: true,
        includeCoverPage: false,
        includeAcademyLogo: false,
        includeAnswerSheet: false,
        includeExplanation: false,
        includeQuestionScore: true,
        layoutColumns: 1,
        maxQuestionsPerPage: 1,
        geometryOverride: 'paperwidth=115mm,paperheight=800mm,left=5mm,right=5mm,top=5mm,bottom=5mm',
      },
      profile: 'naesin',
      paper: 'A4',
      modeByQuestionId: { [String(question.question_uid || question.id)]: mode },
      questionMode: 'objective',
      layoutColumns: flag('--paper') ? 2 : 1,
      maxQuestionsPerPage: flag('--paper') ? 4 : 1,
      renderConfigVersion: 'pb_render_v5_ind_set_split_1',
      fontFamilyRequested: 'KoPubWorldBatangPro',
      fontFamilyResolved: 'KoPubWorldBatangPro',
      fontRegularPath: fontPath,
      fontBoldPath: '',
      fontSize: 11,
      supabaseClient: supa,
    });
    const pdf = path.join(outDir, `${tag}.pdf`);
    fs.writeFileSync(pdf, rendered.bytes);
    execFileSync('pdftoppm', ['-r', value('--dpi', '100'), '-png', '-f', '1', '-l', '1', '-singlefile', pdf, path.join(outDir, `${tag}_page`)]);
    // 카드처럼 내용만 남긴다(800mm 높이 쪽의 흰 여백을 자른다).
    await sharp(path.join(outDir, `${tag}_page.png`))
      .trim()
      .extend({ top: 10, bottom: 10, left: 10, right: 10, background: '#ffffff' })
      .toFile(path.join(outDir, `${tag}.png`));
    fs.rmSync(path.join(outDir, `${tag}_page.png`));
    fs.rmSync(pdf);
    console.log(`찍음 ${tag}.png`);
    done += 1;
  } catch (e) {
    console.log(`실패 ${tag}: ${String(e?.message || e).slice(0, 200)}`);
    failed += 1;
  }
}
console.log(`끝: 찍음 ${done}, 실패 ${failed}`);
