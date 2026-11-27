// 실서비스에 실린 엔진 그림이 실제로 인쇄에 쓰이는지 본다 (읽기 전용).
//
// 문항을 DB 에서 읽고 그림을 저장소에서 받아, 인쇄 서버와 같은 렌더러로 양식 세 가지를 이 PC 에 찍어 본다.
// DB 와 저장소에는 아무것도 쓰지 않는다.
//
//   node --env-file=.env scripts/check_engine_figure_print.mjs <문항 id> [<문항 id> ...] [--out <폴더>]
//
// 양식마다 엔진 그림이 몇 장 쓰였는지(engine_figures)와 찍은 PDF·그림 파일의 자리를 알려 준다.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';

import { parseEngineFigures } from '../src/problem_bank/engine_figures.js';
import { renderPdfWithXeLatex } from '../src/problem_bank/render_engine/xelatex_v2/renderer.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const argv = process.argv.slice(2);
const outIndex = argv.indexOf('--out');
const out = path.resolve(outIndex >= 0 ? argv[outIndex + 1] : path.join(root, 'packages', 'ygg_figure', 'build', 'publish', 'check'));
const ids = argv.filter((one, i) => !one.startsWith('--') && (outIndex < 0 || i !== outIndex + 1));
if (ids.length === 0) {
  console.error('문항 id 를 적어 주세요.');
  process.exit(2);
}
const url = String(process.env.SUPABASE_URL || '').trim();
const key = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
if (!url || !key) {
  console.error('SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY 가 없습니다. node --env-file=.env 로 실행하세요.');
  process.exit(2);
}
const supabase = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

const { data: rows, error } = await supabase
  .from('pb_questions')
  .select('id,question_uid,question_number,question_type,stem,choices,allow_objective,allow_subjective,objective_choices,figure_refs,equations,meta')
  .in('id', ids);
if (error) {
  console.error(`문항을 읽지 못했습니다: ${error.message}`);
  process.exit(1);
}
const questions = ids.map((id) => rows.find((one) => one.id === id)).filter(Boolean);
if (questions.length !== ids.length) {
  console.error('찾지 못한 문항이 있습니다.');
  process.exit(1);
}
const expected = questions.reduce(
  (sum, q) => sum + parseEngineFigures(q.meta).filter((one) => one.status === 'approved').length,
  0,
);

// 학습앱이 인쇄를 맡길 때 보내는 값과 같게 둔다(과제형 A4, 내신형 B4, 모의고사형 8절. 모두 2단).
const FORMATS = {
  assignment: { profile: 'assignment', paper: 'A4', renderConfig: { questionNumberPlacement: 'above', questionNumberFormat: 'two_digit' } },
  naesin: { profile: 'gyeongsin', paper: 'B4', renderConfig: { hidePreviewHeader: true } },
  mock: { profile: 'csat', paper: '8절', renderConfig: { hidePreviewHeader: true } },
};
const bodyFont = path.join(root, 'apps/yggdrasill/assets/fonts/kopub/KoPubWorldBatangProLight.otf');
fs.mkdirSync(out, { recursive: true });
const log = console.log;
let failed = false;
for (const [format, { profile, paper, renderConfig }] of Object.entries(FORMATS)) {
  console.log = (...a) => console.error(...a);
  const rendered = await renderPdfWithXeLatex({
    questions: structuredClone(questions),
    renderConfig,
    profile,
    paper,
    layoutColumns: 2,
    maxQuestionsPerPage: 4,
    questionMode: 'objective',
    ...(fs.existsSync(bodyFont)
      ? { fontFamilyRequested: 'KoPubWorldBatangPro', fontFamilyResolved: 'KoPubWorldBatangPro', fontRegularPath: bodyFont, fontBoldPath: bodyFont }
      : {}),
    fontSize: 11,
    supabaseClient: supabase,
  });
  console.log = log;
  const pdf = path.join(out, `${format}.pdf`);
  fs.writeFileSync(pdf, rendered.bytes);
  execFileSync('pdftoppm', ['-png', '-r', '110', pdf, path.join(out, format)]);
  const used = rendered.figureHydration?.engineFigureCount ?? 0;
  if (used !== expected) failed = true;
  console.log(`${format}: 엔진 그림 ${used}/${expected}장 사용 → ${pdf}`);
}
process.exit(failed ? 1 : 0);
