// Diagnose the most recent pb_document that matches a title keyword and dump:
//   - latest pb_extract_jobs row (status, result_summary, error)
//   - latest pb_figure_jobs rows (status counts)
//   - pb_questions rows (question_number / figure_refs / meta.figure_count / meta.figure_assets length)
// so we can see exactly where the current "서버 미리보기 응답에서 누락" comes from.
//
// Usage: node gateway/scripts/adhoc_pb_document_status.mjs "경신중"

import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const keyword = process.argv[2] || '경신';
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error('missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY');
  process.exit(1);
}
const supa = createClient(url, key, { auth: { persistSession: false } });

const { data: docs, error: docErr } = await supa
  .from('pb_documents')
  .select('id, source_filename, source_pdf_filename, status, created_at, updated_at, source_storage_path, source_pdf_storage_path')
  .or(`source_filename.ilike.%${keyword}%,source_pdf_filename.ilike.%${keyword}%`)
  .order('updated_at', { ascending: false })
  .limit(5);
if (docErr) throw docErr;
console.log('=== matching documents ===');
for (const d of docs || []) {
  console.log(`${d.id}  status=${d.status}  updated=${d.updated_at}  hwpx="${d.source_filename}"  pdf="${d.source_pdf_filename || ''}"`);
}
const doc = (docs || [])[0];
if (!doc) {
  console.log('no matching document');
  process.exit(0);
}
console.log(`\n>>> using document ${doc.id}  "${doc.source_filename}"`);
console.log(`    hwpx_path=${doc.source_storage_path}`);
console.log(`    pdf_path =${doc.source_pdf_storage_path}`);

const { data: extractJobs, error: ejErr } = await supa
  .from('pb_extract_jobs')
  .select('*')
  .eq('document_id', doc.id)
  .order('created_at', { ascending: false })
  .limit(5);
if (ejErr) console.log('extract_jobs query error:', ejErr);
console.log('\n=== latest extract jobs ===');
for (const j of extractJobs || []) {
  const rs = j.result_summary || {};
  console.log(
    `${j.id}  status=${j.status}  created=${j.created_at}  updated=${j.updated_at}\n` +
    `  result_summary keys: ${Object.keys(rs).join(', ')}\n` +
    `  questionCount=${rs.questionCount}  lowConfidenceCount=${rs.lowConfidenceCount}  ` +
    `figureOverlay=${JSON.stringify(rs.vlmHwpxFigureOverlay || rs.figureOverlay || rs.overlayApplied || null)}`,
  );
  if (j.error_detail) {
    console.log(`  ERROR_DETAIL: ${JSON.stringify(j.error_detail).slice(0, 400)}`);
  }
}

const { data: figureJobs, error: fjErr } = await supa
  .from('pb_figure_jobs')
  .select('*')
  .eq('document_id', doc.id)
  .order('created_at', { ascending: false })
  .limit(10);
if (fjErr) console.log('figure_jobs query error:', fjErr);
console.log(`\n=== latest figure jobs (count=${figureJobs?.length || 0}) ===`);
const statusTally = {};
for (const j of figureJobs || []) {
  statusTally[j.status] = (statusTally[j.status] || 0) + 1;
}
console.log('status tally:', statusTally);
for (const j of (figureJobs || []).slice(0, 5)) {
  console.log(`${j.id}  status=${j.status}  q=${j.question_id}  updated=${j.updated_at}`);
  if (j.error_detail) console.log(`  ERR: ${JSON.stringify(j.error_detail).slice(0, 300)}`);
}

const { data: questions, error: qErr } = await supa
  .from('pb_questions')
  .select('id, question_number, figure_refs, meta, stem, source_order')
  .eq('document_id', doc.id)
  .order('source_order', { ascending: true })
  .limit(40);
if (qErr) console.log('pb_questions query error:', qErr);
console.log(`\n=== pb_questions rows (count=${questions?.length || 0}) ===`);
for (const q of questions || []) {
  const refs = Array.isArray(q.figure_refs) ? q.figure_refs : [];
  const pbTokenRefs = refs
    .flatMap((r) => String(r || '').match(/\[\[PB_FIG_([^\]]+)\]\]/g) || [])
    .map((m) => m.replace(/^\[\[PB_FIG_|\]\]$/g, ''));
  const assets = Array.isArray(q.meta?.figure_assets) ? q.meta.figure_assets : [];
  const figCount = q.meta?.figure_count;
  const stemHasFigToken = /\[\[PB_FIG_/.test(String(q.stem || ''));
  console.log(
    `Q${String(q.question_number || '?').padStart(3)}  ` +
    `refs=${refs.length}  pbTokens=${JSON.stringify(pbTokenRefs)}  ` +
    `meta.figure_count=${figCount}  assets=${assets.length}  stemHasPBFIG=${stemHasFigToken}`,
  );
}
