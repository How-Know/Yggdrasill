// 빠른 정답 한 지면의 판독 결과를 순서대로 찍어 보는 읽기 전용 진단.
//
// 소단원 머리(header)와 번호/정답(answer)이 어떤 순서·단으로 왔는지 봐야
// "어느 지점부터 짝짓기가 끊겼는지" 가려낼 수 있다.
//
// 사용: node scripts/diag_answer_layout_page.mjs --pdf <답지.pdf> --page 11
import 'dotenv/config';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const arg = (name, fallback = '') => {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const pdf = arg('pdf');
const from = Number.parseInt(arg('page', arg('from', '1')), 10);
const to = Number.parseInt(arg('to', String(from)), 10);
if (!pdf) throw new Error('usage: --pdf <답지.pdf> --page <쪽>');

const gateway = process.env.PB_GATEWAY_URL || 'http://localhost:8787';
const apiKey = process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '';
const dir = mkdtempSync(join(tmpdir(), 'answer-page-'));

for (let page = from; page <= to; page += 1) {
  execFileSync('pdftoppm', [
    '-png', '-r', '200', '-f', String(page), '-l', String(page), pdf,
    join(dir, `p${page}`),
  ]);
  const file = readdirSync(dir).find(
    (name) => name.startsWith(`p${page}-`) && name.endsWith('.png'),
  );
  const png = readFileSync(join(dir, file));
  const res = await fetch(`${gateway}/textbook/vlm/extract-answer-layout`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(apiKey ? { 'x-api-key': apiKey } : {}),
    },
    body: JSON.stringify({
      image_base64: png.toString('base64'),
      mime_type: 'image/png',
      raw_page: page,
    }),
  });
  const json = await res.json();
  if (!json.ok) {
    console.log(`p${page}: 실패 ${JSON.stringify(json)}`);
    continue;
  }
  console.log(
    `=== p${page} · 요소 ${json.entries.length} · ` +
      `앞머리이어짐=${json.leading_continuation}`,
  );
  const box = (entry) =>
    Array.isArray(entry.bbox) ? `[${entry.bbox.join(',')}]` : '(좌표없음)';
  for (const entry of json.entries) {
    if (entry.kind === 'header') {
      console.log(
        `  [머리] "${entry.title}" 본문쪽=${entry.page_start}~${entry.page_end} ` +
          `${box(entry)}`,
      );
      continue;
    }
    console.log(
      `   ${String(entry.problem_number).padEnd(6)} ${box(entry)} ` +
        `${entry.kind === 'image' ? '[그림]' : entry.answer_text}`,
    );
  }
}
