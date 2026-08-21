// 교재 본문 한 지면을 게이트웨이 detect 로 돌려 items 를 그대로 찍는다 (읽기 전용).
//
// 크롭이 빠졌을 때 "모델이 못 읽은 것" 과 "클라이언트 가드가 지운 것" 을 가르는
// 용도다. 여기서 나오는 목록이 가드 이전의 원본이다.
//
// 사용:
//   node scripts/diag_detect_page.mjs --grade 3-1 --page 135,136
//   node scripts/diag_detect_page.mjs --grade 2-1 --page 17 --hint unit_drill
//   [--book <book_id>]    기본값은 개념+유형
//   [--series <key>]      기본값은 gaeyu
//   [--pdf <경로>]        등록 전 교재는 로컬 PDF 를 직접 지정한다 (DB 조회 생략)
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function arg(name, fallback = '') {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && process.argv[i + 1] ? String(process.argv[i + 1]).trim() : fallback;
}
const bookId = arg('book', '2c7e1188-aaf1-4959-9331-f97e3caeba37');
const gradeLabel = arg('grade', '3-1');
const pages = arg('page', '136')
  .split(',')
  .map((v) => Number.parseInt(v, 10))
  .filter(Number.isFinite);
const hint = arg('hint', '');
const series = arg('series', 'gaeyu');
const localPdf = arg('pdf', '');
const expectedStartNumber = arg('expected', '');

const gateway = String(process.env.PB_GATEWAY_URL || 'http://localhost:8787').trim();
const gatewayApiKey = String(
  process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '',
).trim();
const workDir = mkdtempSync(join(tmpdir(), 'detect-'));
let pdfPath = localPdf;
if (!pdfPath) {
  const supa = createClient(
    String(process.env.SUPABASE_URL || '').trim(),
    String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const link = await supa
    .from('resource_file_links')
    .select('storage_bucket,storage_key')
    .eq('file_id', bookId)
    .eq('grade', `${gradeLabel}#body`)
    .maybeSingle();
  if (link.error) throw new Error(link.error.message);
  pdfPath = join(workDir, 'body.pdf');
  const download = await supa.storage
    .from(link.data.storage_bucket)
    .download(link.data.storage_key);
  if (download.error) throw new Error(download.error.message);
  writeFileSync(pdfPath, Buffer.from(await download.data.arrayBuffer()));
}

for (const page of pages) {
  const prefix = join(workDir, `p${page}`);
  // 매니저 앱은 긴 변 1500px 로 렌더해 보낸다. --longedge 로 흉내 낼 수 있다.
  const longEdge = arg('longedge', '');
  execFileSync('pdftoppm', [
    '-png',
    ...(longEdge ? ['-scale-to', longEdge] : ['-r', '200']),
    '-f', String(page), '-l', String(page), pdfPath, prefix,
  ]);
  const name = readdirSync(workDir).find(
    (f) => f.startsWith(`p${page}-`) && f.endsWith('.png'),
  );
  const png = readFileSync(join(workDir, name));
  const res = await fetch(`${gateway}/textbook/vlm/detect-problems`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(gatewayApiKey ? { 'x-api-key': gatewayApiKey } : {}),
    },
    body: JSON.stringify({
      image_base64: png.toString('base64'),
      mime_type: 'image/png',
      raw_page: page,
      display_page: page,
      book_id: bookId,
      grade_label: gradeLabel,
      series,
      ...(hint ? { section_hint: hint } : {}),
      ...(expectedStartNumber
        ? { expected_start_number: expectedStartNumber }
        : {}),
    }),
  });
  const json = await res.json().catch(() => ({}));
  const result = json.result ?? json;
  console.log(`\n=== p${page} section=${result?.section} kind=${result?.page_kind} notes=${result?.notes || '-'}`);
  for (const item of result?.items ?? []) {
    const group = item.content_group || {};
    console.log(
      `  ${JSON.stringify(item.number)} cat=${item.category} label=${JSON.stringify(item.label)} ` +
        `set=${item.is_set_header === true ? JSON.stringify(item.set_range) : '-'} ` +
        `col=${item.column ?? '-'} group=${group.kind || 'none'}/${JSON.stringify(group.label || '')}/${JSON.stringify(group.title || '')} ` +
        `bbox=${JSON.stringify(item.bbox)} region=${JSON.stringify(item.item_region)} ` +
        `w=${Array.isArray(item.bbox) ? item.bbox[3] - item.bbox[1] : '-'}`,
    );
  }
}
process.exit(0);
