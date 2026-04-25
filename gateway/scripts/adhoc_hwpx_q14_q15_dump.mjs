// Ad-hoc: Dump Q14~Q15 paragraph-level structure from a HWPX file so we can
// confirm whether image2/image3 physically sit inside Q14's table, or after
// Q15's question-number paragraph.
// Usage: node gateway/scripts/adhoc_hwpx_q14_q15_dump.mjs <path>

import fs from 'node:fs';
import path from 'node:path';
import AdmZip from 'adm-zip';

const file = process.argv[2];
if (!file) {
  console.error('usage: adhoc_hwpx_q14_q15_dump.mjs <hwpx>');
  process.exit(1);
}
const abs = path.resolve(file);
const zip = new AdmZip(abs);
const entries = zip.getEntries();
const sections = entries
  .filter((e) => /^Contents\/section\d+\.xml$/i.test(e.entryName))
  .sort((a, b) => a.entryName.localeCompare(b.entryName));

// very lightweight XML walker: we only care about
//  - <hp:p> paragraph boundaries
//  - <hp:t>...</hp:t> text runs
//  - <hp:pic ... binaryItemIDRef="imageN"/>
//  - <hp:tbl ...> / </hp:tbl>   (table enter/exit)
// We print a flat stream so we can eyeball the actual order.

function walkSection(xml, sectionName, out) {
  // Tokenize by tag boundaries without a full DOM (HWPX XML is well-formed but
  // huge; a regex scanner is enough for a diagnostic dump).
  const tagRe = /<([\/!?]?)([a-zA-Z0-9:_-]+)([^>]*)>|([^<]+)/g;
  let paraIdx = 0;
  let tblDepth = 0;
  let pending = { text: '', images: [] };
  const flushPara = () => {
    const text = pending.text.replace(/\s+/g, ' ').trim();
    if (text || pending.images.length > 0) {
      out.push({
        section: sectionName,
        paraIdx,
        inTable: tblDepth > 0,
        tblDepth,
        text,
        images: pending.images.slice(),
      });
    }
    pending = { text: '', images: [] };
    paraIdx += 1;
  };
  let m;
  while ((m = tagRe.exec(xml))) {
    const [whole, slash, name, attrs, textChunk] = m;
    if (textChunk !== undefined) {
      // Raw text between tags — only meaningful inside <hp:t>, but for a
      // diagnostic dump we just accumulate; XML whitespace between tags is
      // harmless because we trim at flush time.
      continue;
    }
    const tag = name;
    const lower = tag.toLowerCase();
    if (slash === '') {
      if (lower === 'hp:tbl' || lower === 'hp:tbl/'.replace('/', '')) {
        if (/\/\s*$/.test(attrs)) {
          // self-closed, ignore depth change
        } else {
          tblDepth += 1;
        }
      }
      if (lower === 'hp:p') {
        // start of new paragraph — flush previous
        flushPara();
      }
      if (lower === 'hp:t') {
        // grab text until </hp:t>
        const endIdx = xml.indexOf('</hp:t>', tagRe.lastIndex);
        if (endIdx > 0) {
          const raw = xml.slice(tagRe.lastIndex, endIdx);
          // strip any nested tags just in case
          const plain = raw.replace(/<[^>]+>/g, '');
          pending.text += plain;
          tagRe.lastIndex = endIdx + '</hp:t>'.length;
        }
      }
      if (lower === 'hp:pic') {
        const refMatch = attrs.match(/binaryItemIDRef\s*=\s*"([^"]+)"/);
        if (refMatch) pending.images.push(refMatch[1]);
      }
    } else if (slash === '/') {
      if (lower === 'hp:tbl') {
        tblDepth = Math.max(0, tblDepth - 1);
      }
      if (lower === 'hp:p') {
        // paragraph end without explicit next-start: flush lazily on next <hp:p>
      }
    }
  }
  flushPara();
}

const stream = [];
for (const e of sections) {
  const xml = e.getData().toString('utf8');
  walkSection(xml, e.entryName, stream);
}

// Locate paragraphs around Q14/Q15 (and Q13/Q16 for context).
function isQNumber(text, n) {
  const pats = [
    new RegExp(`^\\s*${n}\\s*[.)\\]]`),
    new RegExp(`^\\s*${n}\\s*\\.`),
    new RegExp(`^${n}번`),
  ];
  return pats.some((r) => r.test(text));
}

const q13 = stream.findIndex((p) => isQNumber(p.text, 13));
const q14 = stream.findIndex((p) => isQNumber(p.text, 14));
const q15 = stream.findIndex((p) => isQNumber(p.text, 15));
const q16 = stream.findIndex((p) => isQNumber(p.text, 16));

console.log('[anchors]', { q13, q14, q15, q16, total: stream.length });
const start = q14 >= 0 ? Math.max(0, q14 - 2) : 0;
const end = q16 >= 0 ? Math.min(stream.length, q16 + 3) : stream.length;
console.log(`\n--- paragraphs [${start}..${end}) ---`);
for (let i = start; i < end; i += 1) {
  const p = stream[i];
  const mark =
    i === q13 ? 'Q13' :
    i === q14 ? 'Q14' :
    i === q15 ? 'Q15' :
    i === q16 ? 'Q16' : '   ';
  const imgs = p.images.length > 0 ? ` IMG=${p.images.join(',')}` : '';
  const tbl = p.inTable ? ` [TBL d=${p.tblDepth}]` : '';
  const text = p.text.length > 120 ? p.text.slice(0, 117) + '...' : p.text;
  console.log(`${String(i).padStart(4)} ${mark}${tbl}${imgs}  ${text}`);
}
