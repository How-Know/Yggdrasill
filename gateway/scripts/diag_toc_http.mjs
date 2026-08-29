// 매니저 앱이 부르는 그대로 /textbook/vlm/parse-toc 를 HTTP 로 한 번 태운다.
// parseTocPages 직접 호출과 달리 본문 크기·라우팅·응답 정규화까지 함께 본다.
//
// 사용: node scripts/diag_toc_http.mjs --dir <png 디렉터리> [--series suryeok]
//       [--base http://127.0.0.1:8787]

import fs from 'fs';
import path from 'path';

function arg(name, fallback = '') {
  const at = process.argv.indexOf(`--${name}`);
  return at >= 0 ? process.argv[at + 1] ?? fallback : fallback;
}

const dir = arg('dir');
const series = arg('series', 'suryeok');
const base = arg('base', 'http://127.0.0.1:8787');
if (!dir) {
  console.error('usage: --dir <png 디렉터리> [--series s] [--base url]');
  process.exit(1);
}

const images = fs
  .readdirSync(dir)
  .filter((name) => name.endsWith('.png'))
  .sort()
  .map((name) => ({
    image_base64: fs.readFileSync(path.join(dir, name)).toString('base64'),
    mime_type: 'image/png',
  }));
const payload = JSON.stringify({ images, series });
console.log(`pages=${images.length} payloadKB=${Math.round(payload.length / 1024)}`);

const started = Date.now();
const res = await fetch(`${base}/textbook/vlm/parse-toc`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: payload,
});
const text = await res.text();
console.log(`status=${res.status} elapsedMs=${Date.now() - started}`);
let json;
try {
  json = JSON.parse(text);
} catch {
  console.log('body:', text.slice(0, 800));
  process.exit(0);
}
if (!json.ok) {
  console.log('body:', JSON.stringify(json).slice(0, 800));
  process.exit(0);
}
console.log(
  `finish=${json.finish_reason} appendix=${json.appendix_boundary_page}` +
    ` bigs=${(json.big_units || []).length} notes=${json.notes || '-'}`,
);
for (const big of json.big_units || []) {
  const mids = big.mid_units || [];
  const subs = mids.reduce((acc, m) => acc + (m.sub_units || []).length, 0);
  console.log(`  ${big.name}: mid=${mids.length} sub=${subs}`);
}
