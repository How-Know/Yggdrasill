// Line-stream dump: for each parsed section, print (a) answerHints map,
// (b) every line with its prefix markers so we can eyeball exactly where the
// parser would see score_only / endnote / [미주] anchors.
//
// Usage: node gateway/scripts/adhoc_hwpx_linestream_dump.mjs <path>

import fs from 'node:fs';
import path from 'node:path';
import { _parseHwpxBuffer as parseHwpxBuffer } from '../src/problem_bank_extract_worker.js';

const file = process.argv[2];
const buffer = fs.readFileSync(path.resolve(file));
const parsed = parseHwpxBuffer(buffer);

for (const s of parsed.sections || []) {
  const ah = s.answerHints || {};
  const keys = Object.keys(ah);
  console.log(`\n=== ${s.path}  lines=${(s.lines || []).length}  answerHints=${keys.length} ===`);
  console.log('answerHints keys (sorted):', keys.slice().sort((a, b) => Number(a) - Number(b)));
  // sample first 5 answerHints
  for (const k of keys.slice(0, 5)) {
    const v = ah[k];
    const txt = typeof v === 'string' ? v : JSON.stringify(v);
    console.log(`  [${k}] ${txt.length > 80 ? txt.slice(0, 77) + '…' : txt}`);
  }

  let idx = 0;
  for (const line of s.lines || []) {
    const text = String(line.text || '').replace(/\s+/g, ' ').trim();
    if (!text) { idx += 1; continue; }
    const flags = [];
    if (/\[미주\]/.test(text)) flags.push('ENDNOTE');
    if (/^\s*\[\s*\d+(?:\.\d+)?\s*점\s*\]\s*$/.test(text)) flags.push('SCORE_ONLY');
    if (/^\s*(\d{1,2})\s*[.)]\s*/.test(text)) flags.push('QNUM_TEXT');
    if (/\[\[PB_FIG_/.test(text)) flags.push('FIG');
    if (/^\s*\(\s*\d+\s*\)/.test(text)) flags.push('SUBQ');
    if (/\[정답\]/.test(text)) flags.push('ANSWER_HINT');
    const tag = flags.length ? `[${flags.join(',')}]` : '          ';
    const snippet = text.length > 130 ? text.slice(0, 127) + '…' : text;
    console.log(`${String(idx).padStart(4)} ${tag.padEnd(32)} ${snippet}`);
    idx += 1;
  }
}
