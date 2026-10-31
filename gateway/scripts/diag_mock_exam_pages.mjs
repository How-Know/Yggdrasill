// 모의고사 문제지·해설 지면 판독 결과를 DB 없이 찍어 보는 읽기 전용 진단.
//
// 사용: node scripts/diag_mock_exam_pages.mjs --pdf <파일.pdf> --kind problem|solution
//         --pages 1,9 [--grade 3] [--elective probstats] [--out <dir>]
// --out 을 주면 지면 PNG 위에 영역을 그린 이미지를 저장한다.
import 'dotenv/config';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import { callGeminiImageJson } from '../src/mock_exam/gemini_image.js';
import {
  assignSolutionSections,
  buildProblemPagePrompt,
  buildSolutionPagePrompt,
  normalizeProblemPage,
  normalizeSolutionPage,
} from '../src/mock_exam/mock_pages.js';

const arg = (name, fallback = '') => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const pdf = arg('pdf');
const kind = arg('kind', 'problem');
const grade = Number(arg('grade', '3'));
const elective = arg('elective', '');
const pages = arg('pages', '1').split(',').map((v) => Number(v.trim())).filter(Boolean);
const outDir = arg('out');
if (!pdf) throw new Error('usage: --pdf <file> --kind problem|solution --pages 1,2');
const model =
  process.env.MOCK_EXAM_VLM_MODEL || process.env.TEXTBOOK_VLM_MODEL || process.env.PB_VLM_MODEL ||
  'gemini-3.1-pro-preview';
const apiKey = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '';
const dir = mkdtempSync(join(tmpdir(), 'mock-diag-'));
if (outDir) mkdirSync(outDir, { recursive: true });

async function overlay(png, boxes, file) {
  const meta = await sharp(png).metadata();
  const w = meta.width;
  const h = meta.height;
  const rects = boxes
    .map(({ region, label, color }) => {
      const [y1, x1, y2, x2] = region;
      const x = (x1 / 1000) * w;
      const y = (y1 / 1000) * h;
      return `<rect x="${x}" y="${y}" width="${((x2 - x1) / 1000) * w}" height="${((y2 - y1) / 1000) * h}" fill="none" stroke="${color}" stroke-width="3"/>` +
        `<text x="${x + 4}" y="${y + 22}" font-size="22" fill="${color}">${label}</text>`;
    })
    .join('');
  const svg = Buffer.from(`<svg width="${w}" height="${h}" xmlns="http://www.w3.org/2000/svg">${rects}</svg>`);
  await sharp(png).composite([{ input: svg }]).png().toFile(file);
}

const results = [];
for (const page of pages) {
  const base = join(dir, `p${page}`);
  execFileSync('pdftoppm', ['-png', '-r', '130', '-f', String(page), '-l', String(page), '-singlefile', pdf, base]);
  const png = readFileSync(`${base}.png`);
  const prompt = kind === 'problem'
    ? buildProblemPagePrompt({ grade, page })
    : buildSolutionPagePrompt({ grade, page });
  const res = await callGeminiImageJson({ imageBuffer: png, prompt, model, apiKey });
  const usage = res.usageMetadata || {};
  console.log(`=== p${page} ${res.elapsedMs}ms prompt=${usage.promptTokenCount} out=${usage.candidatesTokenCount} think=${usage.thoughtsTokenCount || 0}`);
  if (kind === 'problem') {
    const out = normalizeProblemPage(res.parsedJson);
    console.log(`  title="${out.pageTitle}" elective=${out.elective || '-'}`);
    for (const item of out.items) console.log(`  ${item.number}: ${JSON.stringify(item.region)}`);
    if (outDir) {
      await overlay(png, out.items.map((i) => ({ region: i.region, label: String(i.number), color: 'red' })), join(outDir, `problem_p${page}.png`));
    }
  } else {
    const out = normalizeSolutionPage(res.parsedJson);
    results.push({ page, result: out });
    for (const t of out.answerTables) {
      console.log(`  [정답상자] "${t.label}" ${t.entries.map((e) => `${e.number}:${e.text}`).join(' ')}`);
    }
    for (const h of out.headers) console.log(`  [머리] "${h.label}" ${JSON.stringify(h.region)}`);
    for (const b of out.blocks) console.log(`  [해설] ${b.number} num=${JSON.stringify(b.numberRegion)} body=${JSON.stringify(b.contentRegion)}`);
    if (outDir) {
      await overlay(
        png,
        [
          ...out.answerTables.filter((t) => t.region).map((t) => ({ region: t.region, label: 'ANS', color: 'blue' })),
          ...out.blocks.filter((b) => b.contentRegion).map((b) => ({ region: b.contentRegion, label: String(b.number), color: 'red' })),
        ],
        join(outDir, `solution_p${page}.png`),
      );
    }
  }
}
if (kind === 'solution') {
  const { answers, solutions } = assignSolutionSections({ grade, paperElective: elective, pages: results });
  console.log(`answers=${[...answers.keys()].join(' ')}`);
  console.log(`solutions=${[...solutions.keys()].join(' ')}`);
}
