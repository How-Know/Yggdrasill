// 임시: 문항 id 목록을 카드와 같은 설정으로 찍어 build_side/<태그>.png 로 둔다(읽기 전용).
//   node tmp_q_render.mjs --ids-file <파일: "id 태그" 줄들> [--stem-file <{id: 본문} JSON>] [--suffix _x] [--dpi 100]
//   node tmp_q_render.mjs --like multirow   → 본문에 \multirow 가 든 문항을 찾아 "id 태그" 줄을 적는다.
import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { createClient } from '@supabase/supabase-js';
import { renderPdfWithXeLatex } from './src/problem_bank/render_engine/xelatex_v2/renderer.js';

const args = process.argv.slice(2);
const value = (name, fallback = '') => (args.includes(name) ? args[args.indexOf(name) + 1] : fallback);
const here = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(here, 'build_side');
const fontPath = path.resolve(here, '../apps/yggdrasill/assets/fonts/kopub/KoPubWorldBatangProLight.otf');
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });

if (args.includes('--like')) {
  const { data, error } = await supa.from('pb_questions').select('id, question_number, is_published, document_id')
    .like('stem', `%\\\\${value('--like')}%`).limit(60);
  if (error) console.log(`조회 실패: ${error.message}`);
  for (const q of data || []) console.log(`${q.id} ${value('--like')}_${q.question_number}_${String(q.document_id).slice(0, 4)}`);
  process.exit(0);
}
if (args.includes('--boxtable')) {
  // 상자([박스시작]…[박스끝]) 안에서 표([표시작])가 시작하는 문항의 "id 태그" 줄을 적는다.
  const { data, error } = await supa.from('pb_questions').select('id, question_number, is_published, document_id, stem')
    .like('stem', '%[박스시작]%[표시작]%[박스끝]%').limit(400);
  if (error) console.log(`조회 실패: ${error.message}`);
  for (const q of data || []) {
    let open = false;
    let inside = false;
    for (const m of String(q.stem).matchAll(/\[박스시작\]|\[박스끝\]|\[표시작\]/g)) {
      if (m[0] === '[박스시작]') open = true;
      else if (m[0] === '[박스끝]') open = false;
      else if (open) inside = true;
    }
    if (inside) console.log(`${q.id} boxtable_${q.is_published ? 'pub' : 'new'}_${q.question_number}_${String(q.document_id).slice(0, 4)}`);
  }
  process.exit(0);
}
const rows = fs.readFileSync(value('--ids-file'), 'utf8').split(/\r?\n/).map((s) => s.trim()).filter(Boolean).map((s) => s.split(/\s+/));
const stems = value('--stem-file') ? JSON.parse(fs.readFileSync(value('--stem-file'), 'utf8')) : {};
let done = 0;
let failed = 0;
for (const [id, name] of rows) {
  const tag = `${name}${value('--suffix')}`;
  let question = null;
  for (let attempt = 0; attempt < 4 && !question; attempt += 1) {
    if (attempt > 0) await new Promise((resolve) => setTimeout(resolve, 3000 * attempt));
    ({ data: question } = await supa.from('pb_questions').select('*').eq('id', id).maybeSingle());
  }
  if (!question) {
    console.log(`읽지 못함 ${tag}`);
    continue;
  }
  if (stems[id]) question = { ...question, stem: stems[id] };
  const choices = Array.isArray(question.choices) ? question.choices : [];
  const mode = question.allow_objective !== false && choices.length > 0 ? 'objective' : 'subjective';
  try {
    const rendered = await renderPdfWithXeLatex({
      questions: [{ ...question, mode, questionMode: mode }],
      renderConfig: {
        hidePreviewHeader: true,
        hideQuestionNumber: true,
        mathEngine: 'xelatex',
        disableIndependentSetGrouping: true,
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
      layoutColumns: 1,
      maxQuestionsPerPage: 1,
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
    await sharp(path.join(outDir, `${tag}_page.png`))
      .trim()
      .extend({ top: 10, bottom: 10, left: 10, right: 10, background: '#ffffff' })
      .toFile(path.join(outDir, `${tag}.png`));
    fs.rmSync(path.join(outDir, `${tag}_page.png`));
    fs.rmSync(pdf);
    console.log(`찍음 ${tag}.png`);
    done += 1;
  } catch (e) {
    console.log(`실패 ${tag}: ${String(e?.message || e).replace(/\s+/g, ' ').slice(0, 220)}`);
    failed += 1;
  }
}
console.log(`끝: 찍음 ${done}, 실패 ${failed}`);
