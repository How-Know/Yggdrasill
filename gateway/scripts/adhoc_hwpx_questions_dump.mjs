// Dump every question buildQuestionRows produces, so we can pinpoint the
// spurious extra question that pushes the count from 20 (endnote cap) to 21.
//
// Usage: node gateway/scripts/adhoc_hwpx_questions_dump.mjs <path>

import fs from 'node:fs';
import path from 'node:path';
import {
  _parseHwpxBuffer as parseHwpxBuffer,
  _buildQuestionRows as buildQuestionRows,
} from '../src/problem_bank_extract_worker.js';

const file = process.argv[2];
const buffer = fs.readFileSync(path.resolve(file));
const parsed = parseHwpxBuffer(buffer);

// Pull endnote count from parsed section answerHints (union across sections).
const endnoteKeys = new Set();
for (const s of parsed.sections || []) {
  for (const k of Object.keys(s.answerHints || {})) endnoteKeys.add(k);
}

const built = buildQuestionRows({
  academyId: '',
  documentId: '',
  extractJobId: '',
  parsed: { sections: parsed.sections || [] },
  threshold: 0.6,
});

console.log(
  `\n=== summary ===  endnoteCount=${endnoteKeys.size}  questionCount=${(built.questions || []).length}`,
);

const MERGE_SAFE = new Set([
  'score_only',
  'score_annotation',
  'set_question_sub_score',
  'set_question_sub_item',
  'implicit_after_score_terminal',
  'implicit_after_block',
  'merged_score_tail',
]);

for (const [i, q] of (built.questions || []).entries()) {
  const patterns = q.sourcePatterns || q.meta?.source_patterns || [];
  const choicesN = Array.isArray(q.choices) ? q.choices.length : 0;
  const equationsN = Array.isArray(q.equations) ? q.equations.length : 0;
  const figuresN = Array.isArray(q.figure_refs) ? q.figure_refs.length : 0;
  const stemLines = Array.isArray(q.stemLines) ? q.stemLines : [];
  const meaningfulStem = stemLines
    .map((l) => String(l || '').trim())
    .filter(
      (l) =>
        l &&
        !/^(?:\[(?:문단|박스시작|박스끝|그림|도형|표행|표셀)\]|\[\[PB_FIG_[^\]]+\]\])$/.test(l),
    )
    .join(' ');
  const meaningfulLen = meaningfulStem.length;
  const patternsSafe = patterns.every((p) => MERGE_SAFE.has(String(p)));
  const mergeSafe =
    patterns.length > 0 &&
    patternsSafe &&
    choicesN === 0 &&
    equationsN === 0 &&
    figuresN === 0 &&
    meaningfulLen < 30;

  // Which specific condition blocks merge when patternsSafe is OK otherwise?
  const blockers = [];
  if (!patternsSafe) blockers.push(`patterns(${patterns.join('|')})`);
  if (choicesN > 0) blockers.push(`choices=${choicesN}`);
  if (equationsN > 0) blockers.push(`equations=${equationsN}`);
  if (figuresN > 0) blockers.push(`figures=${figuresN}`);
  if (meaningfulLen >= 30) blockers.push(`stemLen=${meaningfulLen}`);

  const stemPreview = meaningfulStem.length > 100
    ? meaningfulStem.slice(0, 97) + '…'
    : meaningfulStem;
  console.log(
    `#${String(i).padStart(2)}  q_no=${String(q.question_number || '?').padStart(3)}  ` +
    `stem=${meaningfulLen.toString().padStart(4)}c  ch=${choicesN}  eq=${equationsN}  fig=${figuresN}  ` +
    `mergeSafe=${mergeSafe ? 'YES' : 'no '}` +
    (mergeSafe ? '' : `  blockers=[${blockers.join(',')}]`),
  );
  console.log(`     patterns=${JSON.stringify(patterns)}`);
  console.log(`     stem=${JSON.stringify(stemPreview)}`);
}
