// 탐지 덤프를 받아 "덤프 이후" 좌표 보정 단계를 그대로 다시 태운다.
//
// 덤프는 좌표 보정 전에 기록되므로, 앱이 최종적으로 받은 좌표는 덤프에 없다.
// 번호 상자가 통째로 갈리는(overwriteItemGeometry) 경로를 확인할 때 쓴다.
//
// 사용: node scripts/diag_replay_dump_geometry.mjs .tmp_vlm_dump/detect_...json
import 'dotenv/config';
import { readFileSync } from 'node:fs';
import {
  detectItemGeometryOnPage,
  numberBboxesLookTemplated,
  overwriteItemGeometry,
  repairSuryeokItemRegions,
} from '../src/textbook/vlm_detect_client.js';

const input = process.argv[2];
if (!input) throw new Error('usage: diag_replay_dump_geometry.mjs <dump.json>');
const dump = JSON.parse(readFileSync(input, 'utf8'));
const imageBase64 = readFileSync(input.replace(/\.json$/, '.png')).toString('base64');
const rawPage = Number.parseInt(input.match(/_p(\d+)_/)?.[1] ?? '0', 10);
const normalized = dump.normalized;

const show = (label) => {
  console.log(`--- ${label}`);
  for (const item of normalized.items) {
    const width = Array.isArray(item.bbox) ? item.bbox[3] - item.bbox[1] : '-';
    const height = Array.isArray(item.bbox) ? item.bbox[2] - item.bbox[0] : '-';
    console.log(
      `  ${String(item.number).padEnd(6)} bbox=${JSON.stringify(item.bbox)} ` +
        `(${width}x${height}) region=${JSON.stringify(item.item_region)}`,
    );
  }
};

show('덤프에 남은 좌표');
console.log('templated?', numberBboxesLookTemplated(normalized.items));

const geometry = await detectItemGeometryOnPage({
  imageBase64,
  mimeType: 'image/png',
  rawPage,
  displayPage: rawPage,
  model: (process.env.TEXTBOOK_VLM_MODEL || 'gemini-3.1-pro-preview').trim(),
  apiKey: (process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY || '').trim(),
  timeoutMs: 120000,
  series: 'suryeok',
  numbers: normalized.items.map((item) => item?.number),
});

const retry = geometry?.parsedJson?.items ?? [];
console.log('--- 2차 판독이 준 좌표');
for (const item of retry) {
  const width = Array.isArray(item.bbox) ? item.bbox[3] - item.bbox[1] : '-';
  const height = Array.isArray(item.bbox) ? item.bbox[2] - item.bbox[0] : '-';
  console.log(
    `  ${String(item.number).padEnd(6)} bbox=${JSON.stringify(item.bbox)} ` +
      `(${width}x${height}) region=${JSON.stringify(item.item_region)}`,
  );
}
console.log('retry templated?', numberBboxesLookTemplated(retry));

if (Array.isArray(retry) && !numberBboxesLookTemplated(retry)) {
  const replaced = overwriteItemGeometry(normalized, geometry.parsedJson);
  if (replaced > 0) repairSuryeokItemRegions(normalized, 'suryeok');
  show(`덮어쓴 뒤 (replaced=${replaced})`);
} else {
  console.log('덮어쓰지 않고 1차 좌표를 유지한다.');
}
