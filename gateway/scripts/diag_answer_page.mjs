// 답지 PDF 한 지면을 게이트웨이 extract-answers 로 돌려 결과를 그대로 찍는다.
//
// 앱을 켜지 않고 "모델이 블록을 제대로 골랐는지" 만 확인하는 용도다. 기대 문항은
// "번호[@코너][:본문쪽]" 형식으로 넘긴다. 코너·본문쪽을 함께 주면 답지 블록이
// 번호를 재사용하는 교재(개념+유형·수력충전)의 대조 규칙까지 그대로 탄다.
//
// 사용:
//   node scripts/diag_answer_page.mjs --pdf "...정답.pdf" --page 3 \
//     --series suryeok --expect "01:25,02:25,01@단원 마무리 평가:29"
import 'dotenv/config';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function arg(name, fallback = '') {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1]
    ? String(process.argv[i + 1]).trim()
    : fallback;
}

const pdfPath = arg('pdf');
if (!pdfPath) throw new Error('--pdf 경로가 필요하다');
const pages = arg('page', '1')
  .split(',')
  .map((v) => Number.parseInt(v, 10))
  .filter(Number.isFinite);
const series = arg('series', '');
// answer = 정답 PDF(extract-answers), solution = 해설 PDF(detect-solution-refs).
const mode = arg('mode', 'answer');
const endpoint =
  mode === 'solution'
    ? '/textbook/vlm/detect-solution-refs'
    : '/textbook/vlm/extract-answers';
const expected = arg('expect', '')
  .split(',')
  .map((chunk) => chunk.trim())
  .filter(Boolean)
  .map((chunk) => {
    const [head, pageText] = chunk.split(':');
    const [number, corner = ''] = head.split('@');
    const page = Number.parseInt(String(pageText ?? ''), 10);
    return {
      problem_number: number.trim(),
      corner: corner.trim(),
      page: Number.isFinite(page) ? page : 0,
    };
  });

const gateway = String(
  process.env.PB_GATEWAY_URL || 'http://localhost:8787',
).trim();
const gatewayApiKey = String(
  process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '',
).trim();
const workDir = mkdtempSync(join(tmpdir(), 'answers-'));

for (const page of pages) {
  const prefix = join(workDir, `p${page}`);
  execFileSync('pdftoppm', [
    '-png', '-r', '200', '-f', String(page), '-l', String(page), pdfPath, prefix,
  ]);
  const name = readdirSync(workDir).find(
    (f) => f.startsWith(`p${page}-`) && f.endsWith('.png'),
  );
  const png = readFileSync(join(workDir, name));
  const res = await fetch(`${gateway}${endpoint}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(gatewayApiKey ? { 'x-api-key': gatewayApiKey } : {}),
    },
    body: JSON.stringify({
      image_base64: png.toString('base64'),
      mime_type: 'image/png',
      raw_page: page,
      series,
      expected_numbers: expected,
    }),
  });
  const json = await res.json().catch(() => ({}));
  const result = json.result ?? json;
  const items = result?.items ?? [];
  console.log(
    `\n=== p${page} items=${items.length}/${expected.length} notes=${result?.notes || '-'}`,
  );
  for (const item of items) {
    const at = item.expected_index != null ? `#${item.expected_index}` : '#-';
    const detail =
      mode === 'solution'
        ? `number_region=${JSON.stringify(item.number_region)}`
        : `${item.kind} ${JSON.stringify(item.answer_text)}`;
    console.log(`  ${at} ${JSON.stringify(item.problem_number)} ${detail}`);
  }
  if (!items.length) console.log(`  (raw) ${JSON.stringify(json).slice(0, 600)}`);
}
process.exit(0);
