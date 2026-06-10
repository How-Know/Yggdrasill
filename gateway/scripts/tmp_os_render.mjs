import 'dotenv/config';
import fs from 'node:fs';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { renderPdfWithXeLatex as renderV2 } from '../src/problem_bank/render_engine/xelatex_v2/renderer.js';
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const DOC = '6940ec38-3342-498d-85ab-dd34c171b9c8';
const { data: allRows } = await supa.from('pb_questions').select('*').eq('document_id', DOC).order('source_order');
const want = ['1', '11'];
const rows = (allRows || []).filter((q) => want.includes(String(q.question_number).trim()))
  .sort((a, b) => want.indexOf(String(a.question_number)) - want.indexOf(String(b.question_number)));
console.log('rendering', rows.map((r) => r.question_number));
function latestWork() {
  const tmp = process.env.TEMP || 'C:/Users/harry/AppData/Local/Temp';
  const dirs = fs.readdirSync(tmp).filter((n) => n.startsWith('pb-xelatex-doc-'))
    .map((n) => ({ n, t: fs.statSync(path.join(tmp, n)).mtimeMs })).sort((a, b) => b.t - a.t);
  return path.join(tmp, dirs[0].n);
}
await renderV2({
  questions: rows.map((q) => ({ ...q })),
  renderConfig: { hidePreviewHeader: true, questionNumberPlacement: 'above' },
  profile: 'assignment', paper: 'B4', questionMode: 'objective',
  layoutColumns: 2, maxQuestionsPerPage: 4, renderConfigVersion: 1,
  fontFamilyRequested: 'Malgun Gothic', fontFamilyResolved: 'Malgun Gothic',
  fontRegularPath: '', fontBoldPath: '', fontSize: 11, supabaseClient: supa,
});
const wd = latestWork();
const pdf = fs.readdirSync(wd).find((f) => f.endsWith('.pdf'));
console.log('WORKDIR', wd, 'PDF', pdf);
if (pdf) fs.copyFileSync(path.join(wd, pdf), 'scripts/tmp_os.pdf');
