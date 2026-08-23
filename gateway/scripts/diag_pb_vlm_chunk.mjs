// 본문 추출 청크 하나만 다시 불러 원문 응답을 그대로 떠 본다.
//
// vlm_missing_expected_questions 로 죽은 청크는 워커 로그에 번호만 남아,
// 모델이 무엇을 뱉었는지(절단인지 반복 루프인지) 알 수 없다. 같은 입력으로
// 한 번만 호출해 finishReason·토큰·원문을 파일로 남긴다.
//
// 사용:
//   node scripts/diag_pb_vlm_chunk.mjs --pdf-cache <sha256> --from 180 --to 181 \
//     --expected 01,02,03,04,05,06,07,08 --set "2~5@180,6~8@181"

import 'dotenv/config';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { PDFDocument } from 'pdf-lib';
import { callGeminiWithPdf } from '../src/problem_bank/extract_engines/vlm/client.js';

async function slicePages(buffer, start, end) {
  const src = await PDFDocument.load(buffer);
  const out = await PDFDocument.create();
  const indices = [];
  for (let p = start; p <= end; p += 1) indices.push(p - 1);
  const pages = await out.copyPages(src, indices);
  for (const page of pages) out.addPage(page);
  return Buffer.from(await out.save());
}

function arg(name, fallback = '') {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] || fallback : fallback;
}

const from = Number(arg('from'));
const to = Number(arg('to'));
const expected = arg('expected')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const setRanges = arg('set')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean)
  .map((token) => {
    const [range, page] = token.split('@');
    const [a, b] = range.split(/[~-]/);
    return {
      label: `${a}~${b}`,
      from: Number(a),
      to: Number(b),
      rawPage: Number(page),
      displayPage: null,
    };
  });

const pdfPath =
  arg('pdf') ||
  path.join(os.tmpdir(), 'yggdrasill-vlm-pdf-cache', `${arg('pdf-cache')}.pdf`);
const source = await fs.promises.readFile(pdfPath);
const sliced = await slicePages(source, from, to);

const scopeFile = arg('scope-file');
const scope = scopeFile
  ? JSON.parse(await fs.promises.readFile(scopeFile, 'utf8'))
  : {};
const res = await callGeminiWithPdf({
  pdfBuffer: sliced,
  model: process.env.PB_GEMINI_MODEL || 'gemini-3.1-pro-preview',
  apiKey: process.env.GEMINI_API_KEY,
  timeoutMs: 300000,
  textbookScope: Object.keys(scope).length > 0 ? scope : null,
  expectedQuestionNumbers: expected,
  expectedIndependentSetRanges: setRanges,
});

const outDir = path.join(process.cwd(), '.tmp_pb_chunk_dump');
await fs.promises.mkdir(outDir, { recursive: true });
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const base = path.join(outDir, `chunk_p${from}-${to}_${stamp}`);
await fs.promises.writeFile(`${base}.txt`, res.modelText);
await fs.promises.writeFile(
  `${base}.json`,
  JSON.stringify(res.parsedJson, null, 2),
);

const numbers = (res.parsedJson?.questions || []).map((q) => q?.question_number);
console.log('finishReason:', res.finishReason);
console.log('elapsedMs   :', res.elapsedMs);
console.log('usage       :', JSON.stringify(res.usageMetadata));
console.log('textLength  :', res.modelText.length);
console.log('questions   :', numbers.length, numbers.join(','));
console.log('dump        :', `${base}.txt`);
