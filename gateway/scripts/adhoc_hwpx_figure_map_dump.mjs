// Ad-hoc: call the production buildHwpxFigureMapByQuestionNumber path against
// a local .hwpx file and print per-question PB_FIG token allocation.
// Also print the raw parsed `questions[*].figure_refs` / stem snippets around
// Q13~Q16 so we can see how the streaming parser segmented them.
//
// Usage: node gateway/scripts/adhoc_hwpx_figure_map_dump.mjs <path>

import fs from 'node:fs';
import path from 'node:path';
import {
  _parseHwpxBuffer as parseHwpxBuffer,
  _buildHwpxFigureMapByQuestionNumber as buildHwpxFigureMapByQuestionNumber,
} from '../src/problem_bank_extract_worker.js';

// buildQuestionRows is not exported directly — but buildHwpxFigureMap uses it
// internally and returns a map. We still want to see the full questions list
// (stem/figure_refs) so we re-run the parser path manually.

const file = process.argv[2];
const buffer = fs.readFileSync(path.resolve(file));

// 1) Run the exact map builder the production pipeline uses.
const logs = [];
const figureMap = buildHwpxFigureMapByQuestionNumber(buffer, {
  threshold: 0.6,
  log: (event, data) => logs.push({ event, data }),
});
console.log('=== build logs ===');
for (const l of logs) console.log(l);

console.log('\n=== figure map (question_number -> pbTokens / plainFigureMarkers) ===');
const entries = [...figureMap.entries()];
entries.sort((a, b) => {
  const an = Number(a[0].replace(/\D/g, '')) || 0;
  const bn = Number(b[0].replace(/\D/g, '')) || 0;
  return an - bn;
});
for (const [qno, v] of entries) {
  console.log(
    `Q${qno.padStart(3)}  pb=${JSON.stringify(v.pbTokens)}  plain=${v.plainFigureMarkers}  refs=${v.figureRefs.length}`,
  );
}

// 2) Dump raw parsed line stream to see how image* tokens actually land.
const parsed = parseHwpxBuffer(buffer);
let globalIdx = 0;
console.log('\n=== raw line stream (image / question-number / misc) ===');
for (const s of parsed.sections || []) {
  for (const line of s.lines || []) {
    const text = String(line.text || '').trim();
    if (!text) { globalIdx += 1; continue; }
    const hasPB = /\[\[PB_FIG_[^\]]+\]\]/.test(text);
    const hasQNum = /^\s*(\d{1,2})\s*[.)]/.test(text);
    const hasFigLabel = /\[(그림|도형|표)\]/.test(text);
    if (hasPB || hasQNum || hasFigLabel) {
      const snippet = text.length > 160 ? text.slice(0, 157) + '…' : text;
      console.log(`${String(globalIdx).padStart(5)}  ${snippet}`);
    }
    globalIdx += 1;
  }
}
