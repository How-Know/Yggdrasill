// Reproduce the /pb/preview/batch-render XeLaTeX failure for a given document.
// First attempts to compile ALL questions as one doc (the real endpoint does this).
// If that fails, re-runs each question in isolation to identify the offender(s)
// and dumps the captured XeLaTeX log for the failing question.
//
// Usage: node gateway/scripts/adhoc_pb_render_smoke.mjs <document_id>

import 'dotenv/config';
import path from 'node:path';
import fs from 'node:fs';
import os from 'node:os';
import { createClient } from '@supabase/supabase-js';
import { renderPdfWithXeLatex } from '../src/problem_bank/render_engine/xelatex/renderer.js';

const docId = process.argv[2] || 'c2e37ceb-164f-4d0f-96f6-f63e2112ea74';
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

function inferMode(row) {
  const t = String(row?.question_type || '');
  if (/주관식|서술형/.test(t)) return 'subjective';
  return 'objective';
}

function asBatchInput(questions) {
  return {
    questions: questions.map((q) => ({ ...q, mode: inferMode(q), questionMode: inferMode(q) })),
    renderConfig: {
      hidePreviewHeader: true,
      hideQuestionNumber: true,
      mathEngine: 'xelatex',
      geometryOverride:
        'paperwidth=115mm,paperheight=800mm,left=5mm,right=5mm,top=5mm,bottom=5mm',
    },
    profile: 'naesin',
    paper: 'A4',
    modeByQuestionId: Object.fromEntries(
      questions.map((q) => [String(q.question_uid || q.id), inferMode(q)]),
    ),
    questionMode: 'objective',
    layoutColumns: 1,
    maxQuestionsPerPage: 1,
    renderConfigVersion: 1,
    fontFamilyRequested: 'Malgun Gothic',
    fontFamilyResolved: 'Malgun Gothic',
    fontRegularPath: '',
    fontBoldPath: '',
    fontSize: 11,
    supabaseClient: supa,
  };
}

const { data: rows, error } = await supa
  .from('pb_questions')
  .select('*')
  .eq('document_id', docId);
if (error) throw error;
rows.sort((a, b) => Number(a.source_order || 0) - Number(b.source_order || 0));
console.log(`fetched ${rows.length} questions`);

let allOk = true;
try {
  const rendered = await renderPdfWithXeLatex(asBatchInput(rows));
  console.log(`[batch] OK, pdfBytes=${rendered.bytes?.length}, pageCount=${rendered.pageCount}`);
} catch (err) {
  allOk = false;
  console.log(`[batch] FAIL: ${String(err?.message || err).slice(0, 400)}`);
}

if (allOk) process.exit(0);

console.log('\n--- isolating per-question renders ---');
const failed = [];
for (const row of rows) {
  const qno = row.question_number;
  try {
    await renderPdfWithXeLatex(asBatchInput([row]));
    console.log(`Q${qno}: ok`);
  } catch (err) {
    const msg = String(err?.message || err);
    console.log(`Q${qno}: FAIL  ${msg.slice(0, 200)}`);
    failed.push({ qno, id: row.id, message: msg });
  }
}

console.log(`\nfailed questions: ${failed.length}`);
for (const f of failed) {
  console.log(`\n=== Q${f.qno} (${f.id}) ===`);
  console.log(f.message.slice(0, 2000));
}
