// 로컬 PDF 의 목차 지면을 게이트웨이 목차 파서로 돌려 트리를 찍는다 (읽기 전용).
//
// 교재를 등록하기 전에 시리즈별 목차 프롬프트가 실제 지면에서 통하는지 확인하는
// 용도다. DB 를 건드리지 않는다.
//
// 사용:
//   node scripts/diag_parse_toc_pdf.mjs --pdf "C:\\...\\대수 (수력충전).pdf" \
//     --pages 4-5 --series suryeok [--json out.json]
import 'dotenv/config';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function arg(name, fallback = '') {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? String(process.argv[i + 1]).trim() : fallback;
}
const pdfPath = arg('pdf');
const series = arg('series', '');
const jsonOut = arg('json');
const [pageFrom, pageTo] = arg('pages', '1-1')
  .split('-')
  .map((v) => Number.parseInt(v, 10));
if (!pdfPath) throw new Error('--pdf 는 필수입니다');

const gateway = String(process.env.PB_GATEWAY_URL || 'http://localhost:8787').trim();
const gatewayApiKey = String(
  process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '',
).trim();

const workDir = mkdtempSync(join(tmpdir(), 'toc-'));
execFileSync('pdftoppm', [
  '-png', '-r', '150', '-f', String(pageFrom), '-l', String(pageTo), pdfPath,
  join(workDir, 'toc'),
]);
const images = readdirSync(workDir)
  .filter((f) => f.endsWith('.png'))
  .sort()
  .map((f) => ({
    image_base64: readFileSync(join(workDir, f)).toString('base64'),
    mime_type: 'image/png',
  }));
console.log(`목차 ${images.length}장 전송 (p${pageFrom}~${pageTo}, series=${series || '-'})`);

const res = await fetch(`${gateway}/textbook/vlm/parse-toc`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/json',
    ...(gatewayApiKey ? { 'x-api-key': gatewayApiKey } : {}),
  },
  body: JSON.stringify({ images, series }),
});
const json = await res.json().catch(() => ({}));
if (!res.ok || json?.ok === false) {
  throw new Error(`parse-toc 실패(${res.status}): ${json?.error || 'unknown'}`);
}
const result = json.result ?? json;
if (jsonOut) writeFileSync(jsonOut, JSON.stringify(result, null, 2), 'utf8');

let subCount = 0;
for (const big of result.big_units ?? []) {
  console.log(`\n■ ${big.name}`);
  for (const mid of big.mid_units ?? []) {
    console.log(`  ▶ ${mid.name}${mid.page == null ? '' : ` (p${mid.page})`}`);
    for (const sub of mid.sub_units ?? []) {
      subCount += 1;
      console.log(
        `      - ${sub.name} p${sub.page ?? '?'}${sub.is_exercise ? ' [마무리]' : ''}`,
      );
    }
  }
}
console.log(
  `\n소단원 ${subCount}개 · appendix=${result.appendix_boundary_page ?? '-'} · notes=${result.notes || '-'}`,
);
process.exit(0);
