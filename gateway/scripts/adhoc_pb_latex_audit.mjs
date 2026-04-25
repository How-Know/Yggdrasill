// Scan every pb_questions row for the target document and report any
// control-character bytes that will blow up XeLaTeX (\x08 \x09 \x0a \x0b \x0c \x0d)
// as well as common LaTeX escape mistakes so we can see exactly which field
// is corrupted.
//
// Usage: node gateway/scripts/adhoc_pb_latex_audit.mjs <document_id>
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const docId = process.argv[2] || 'c2e37ceb-164f-4d0f-96f6-f63e2112ea74';
const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const { data: questions, error } = await supa
  .from('pb_questions')
  .select('id, question_number, stem, choices, equations, meta, flags')
  .eq('document_id', docId);
if (error) { console.log('query error:', error); process.exit(1); }
(questions || []).sort((a, b) => Number(a.question_number || 0) - Number(b.question_number || 0));

const CONTROL_RE = /[\x00-\x08\x0b\x0c\x0e-\x1f]/g; // exclude \t \n \r which are legal
const CRLF_NEAR_LATEX = /[\r\n]([a-zA-Z@\\{}=~:,;+\-*/|()<>[\]])/g;

function describeControl(s) {
  if (s == null) return null;
  const str = String(s);
  const hits = [];
  str.replace(CONTROL_RE, (m, idx) => {
    const byte = m.charCodeAt(0).toString(16).padStart(2, '0');
    const ctx = str.slice(Math.max(0, idx - 15), Math.min(str.length, idx + 15))
      .replace(/[\x00-\x1f]/g, (c) => `\\x${c.charCodeAt(0).toString(16).padStart(2, '0')}`);
    hits.push(`0x${byte}@${idx} "${ctx}"`);
    return m;
  });
  return hits;
}

function describeCrlfNearLatex(s) {
  if (s == null) return null;
  const str = String(s);
  const hits = [];
  let m;
  CRLF_NEAR_LATEX.lastIndex = 0;
  while ((m = CRLF_NEAR_LATEX.exec(str))) {
    const idx = m.index;
    const ctx = str.slice(Math.max(0, idx - 10), Math.min(str.length, idx + 20))
      .replace(/[\x00-\x1f]/g, (c) => `\\x${c.charCodeAt(0).toString(16).padStart(2, '0')}`);
    hits.push(`@${idx} "${ctx}"`);
  }
  return hits;
}

const FIELDS = ['stem', 'choices', 'equations'];

let bad = 0;
for (const q of questions || []) {
  const report = [];
  for (const f of FIELDS) {
    const v = q[f];
    if (v == null) continue;
    const serialized = typeof v === 'string' ? v : JSON.stringify(v);
    const ctlHits = describeControl(serialized) || [];
    if (ctlHits.length) report.push(`[${f}] control: ${ctlHits.slice(0, 3).join(' | ')}${ctlHits.length > 3 ? ' ...' : ''}`);
    const crlfHits = describeCrlfNearLatex(serialized) || [];
    if (crlfHits.length) report.push(`[${f}] crlf-next-to-latex(${crlfHits.length}): ${crlfHits.slice(0, 2).join(' | ')}`);
  }
  const metaSerialized = JSON.stringify(q.meta || {});
  const metaCtl = describeControl(metaSerialized) || [];
  if (metaCtl.length) report.push(`[meta] control: ${metaCtl.slice(0, 3).join(' | ')}`);
  if (report.length) {
    bad++;
    console.log(`--- Q${q.question_number} (${q.id}) ---`);
    for (const line of report) console.log('  ' + line);
  }
}
console.log(`\nTotal questions scanned: ${(questions || []).length}, flagged: ${bad}`);
