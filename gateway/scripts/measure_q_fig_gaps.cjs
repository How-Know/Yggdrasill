// Measure top/bottom gaps around figures in a LaTeX-rendered PDF.
//
// Strategy:
// - Parse the first page content stream with pdf-lib + zlib.
// - Extract all "Td" (text positioning) y-coordinates paired with the text run,
//   and all image ("Do") and path ("re") y-coordinates we can identify.
// - Heuristic: find the text baseline of the line ending the Q4/Q10 stem (ending
//   with "?"), the top of the first image in the corresponding question, the
//   bottom of the last image, and the baseline of the first choice ("①") that
//   follows.
// - Report: topGap = stemBaseline - imageTopY, bottomGap = imageBottomY - choiceBaselineY.
//
// This gives an objective value for how much vertical space LaTeX produced
// above vs below the figure.

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { PDFDocument, PDFName, PDFRawStream } = require('pdf-lib');

async function main() {
  const pdfPath = process.argv[2];
  if (!pdfPath) {
    console.error('usage: node measure_q_fig_gaps.js <pdf>');
    process.exit(1);
  }
  const bytes = fs.readFileSync(pdfPath);
  const doc = await PDFDocument.load(bytes);
  const pages = doc.getPages();
  for (let pi = 0; pi < pages.length; pi += 1) {
    const page = pages[pi];
    const contents = page.node.Contents();
    if (!contents) continue;
    let streams = [];
    if (contents.constructor.name === 'PDFArray') {
      streams = contents.asArray();
    } else {
      streams = [contents];
    }
    const chunks = [];
    for (const ref of streams) {
      const obj = ref.constructor.name === 'PDFRef' ? doc.context.lookup(ref) : ref;
      if (!(obj instanceof PDFRawStream)) continue;
      const filter = obj.dict.get(PDFName.of('Filter'));
      const raw = obj.contents;
      if (filter && String(filter) === '/FlateDecode') {
        chunks.push(zlib.inflateSync(Buffer.from(raw)).toString('latin1'));
      } else {
        chunks.push(Buffer.from(raw).toString('latin1'));
      }
    }
    const src = chunks.join('\n');
    analyzePage(pi + 1, src);
  }
}

function analyzePage(pageNum, src) {
  const lines = src.split(/\n/);
  let curX = 0;
  let curY = 0;
  const events = [];
  let cmMatrix = [1, 0, 0, 1, 0, 0];
  const stack = [];
  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (!line) continue;
    // track graphics state stack for cm transforms
    if (line === 'q') stack.push(cmMatrix.slice());
    else if (line === 'Q') cmMatrix = stack.pop() || [1, 0, 0, 1, 0, 0];
    // cm: a b c d e f cm
    const cmM = line.match(/^([-0-9.]+) ([-0-9.]+) ([-0-9.]+) ([-0-9.]+) ([-0-9.]+) ([-0-9.]+) cm$/);
    if (cmM) {
      const m = cmM.slice(1, 7).map(Number);
      cmMatrix = [
        cmMatrix[0] * m[0] + cmMatrix[2] * m[1],
        cmMatrix[1] * m[0] + cmMatrix[3] * m[1],
        cmMatrix[0] * m[2] + cmMatrix[2] * m[3],
        cmMatrix[1] * m[2] + cmMatrix[3] * m[3],
        cmMatrix[0] * m[4] + cmMatrix[2] * m[5] + cmMatrix[4],
        cmMatrix[1] * m[4] + cmMatrix[3] * m[5] + cmMatrix[5],
      ];
    }
    // Td / TD: tx ty
    const tdM = line.match(/^([-0-9.]+) ([-0-9.]+) (Td|TD)$/);
    if (tdM) {
      curX += Number(tdM[1]);
      curY += Number(tdM[2]);
    }
    // Tm: a b c d e f Tm
    const tmM = line.match(/^([-0-9.]+) ([-0-9.]+) ([-0-9.]+) ([-0-9.]+) ([-0-9.]+) ([-0-9.]+) Tm$/);
    if (tmM) {
      curX = Number(tmM[5]);
      curY = Number(tmM[6]);
    }
    // Tj / TJ : we just record a marker at current (curX, curY) + any visible text
    if (/\) Tj$/.test(line) || /\] TJ$/.test(line)) {
      const text = line.replace(/.*?\((.*)\)\s+Tj$/, '$1').slice(0, 40);
      events.push({ kind: 'text', y: curY, x: curX, text });
    }
    // Image: Do
    if (/\/Im\S+\s+Do$/.test(line)) {
      // The image's top-left y is cmMatrix[5]+cmMatrix[3] (height).
      const bottomY = cmMatrix[5];
      const topY = cmMatrix[5] + cmMatrix[3];
      events.push({ kind: 'image', topY, bottomY });
    }
  }
  // Report events for inspection.
  console.log(`\n=== page ${pageNum} ===`);
  const recent = [];
  for (const ev of events) {
    if (ev.kind === 'text') {
      recent.push({ y: ev.y, text: ev.text });
    } else {
      console.log(`image top=${ev.topY.toFixed(2)} bottom=${ev.bottomY.toFixed(2)}`);
    }
  }
  // Print events in order with image markers inlined
  let ti = 0;
  for (const ev of events) {
    if (ev.kind === 'text') {
      console.log(`  text y=${ev.y.toFixed(2)} "${ev.text}"`);
    } else {
      console.log(`  IMG  topY=${ev.topY.toFixed(2)} botY=${ev.bottomY.toFixed(2)}`);
    }
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
