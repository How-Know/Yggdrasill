// 개념+유형 탄탄 단원 다지기 크롭의 난이도(label)·중요 표시만 다시 읽어 채운다.
//
// 탄탄은 첫 쪽에만 "STEP 2" 배지가 인쇄돼서, 이어지는 쪽을 모델이 쏙쏙(STEP1)
// 으로 잘못 보면 난이도 원 세 개를 아예 읽지 않는다. 클라이언트 가드가 코너는
// 되돌려 주지만 안 읽은 난이도는 만들어 낼 수 없다. 그런 쪽만 골라 본문 지면을
// 다시 한 번 판독해 label / is_important 두 컬럼만 갱신한다.
//
// 문항 번호·좌표·문항 연결은 건드리지 않으므로 정답·해설 매칭과 이미 추출된
// 문제은행 문서에는 영향이 없다. 학습앱은 표시할 때마다 크롭의 label 을 다시
// 읽으므로 이 스크립트만 돌리면 난이도가 바로 반영된다.
//
// 사용:
//   node scripts/backfill_gaeyu_difficulty_labels.mjs \
//     --book <book_id> --grade 2-1 --big 0 --mid 0 [--sub D] [--pages 17,18] [--apply]
//
// --apply 없이 돌리면 무엇을 바꿀지만 출력한다 (기본은 미리보기).
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
const apply = process.argv.includes('--apply');

const bookId = arg('book');
const gradeLabel = arg('grade');
const bigOrder = Number.parseInt(arg('big', '0'), 10);
const midOrder = Number.parseInt(arg('mid', '0'), 10);
const subKey = arg('sub', 'D');
const pageFilter = arg('pages')
  .split(',')
  .map((v) => Number.parseInt(v.trim(), 10))
  .filter((v) => Number.isFinite(v));

if (!bookId || !gradeLabel) {
  throw new Error('--book 과 --grade 는 필수입니다');
}

const gateway = String(process.env.PB_GATEWAY_URL || 'http://localhost:8787').trim();
const gatewayApiKey = String(
  process.env.PB_GATEWAY_API_KEY || process.env.PB_API_KEY || '',
).trim();

const supa = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

// 난이도가 빈 크롭만 대상으로 삼는다. 이미 읽힌 쪽은 다시 묻지 않는다.
let query = supa
  .from('textbook_problem_crops')
  .select('id,academy_id,raw_page,problem_number,label,is_important,section')
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .eq('big_order', bigOrder)
  .eq('mid_order', midOrder)
  .eq('sub_key', subKey)
  .eq('label', '');
if (pageFilter.length) query = query.in('raw_page', pageFilter);
const { data: crops, error: cropError } = await query.order('raw_page');
if (cropError) throw new Error(cropError.message);
if (!crops?.length) {
  console.log('난이도가 빈 크롭이 없습니다. 할 일이 없습니다.');
  process.exit(0);
}

const pages = [...new Set(crops.map((c) => c.raw_page))].sort((a, b) => a - b);
const academyId = crops[0].academy_id;
console.log(`대상 ${crops.length}건 · 지면 ${pages.join(', ')}`);

const link = await supa
  .from('resource_file_links')
  .select('storage_bucket,storage_key')
  .eq('file_id', bookId)
  .eq('grade', `${gradeLabel}#body`)
  .maybeSingle();
if (link.error) throw new Error(link.error.message);
if (!link.data?.storage_key) throw new Error('본문 PDF 링크를 찾지 못했습니다');

const workDir = mkdtempSync(join(tmpdir(), 'gaeyu-label-'));
const pdfPath = join(workDir, 'body.pdf');
console.log(`본문 PDF 내려받는 중: ${link.data.storage_key}`);
const download = await supa.storage
  .from(link.data.storage_bucket)
  .download(link.data.storage_key);
if (download.error) throw new Error(download.error.message);
writeFileSync(pdfPath, Buffer.from(await download.data.arrayBuffer()));

function renderPage(page) {
  const prefix = join(workDir, `p${page}`);
  execFileSync('pdftoppm', [
    '-png',
    '-r',
    '200',
    '-f',
    String(page),
    '-l',
    String(page),
    pdfPath,
    prefix,
  ]);
  const name = readdirSync(workDir).find(
    (f) => f.startsWith(`p${page}-`) && f.endsWith('.png'),
  );
  if (!name) throw new Error(`${page}쪽 PNG 렌더 실패`);
  return readFileSync(join(workDir, name));
}

async function detectPage(page, png) {
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
      academy_id: academyId,
      book_id: bookId,
      grade_label: gradeLabel,
      series: 'gaeyu',
      section_hint: 'unit_drill',
    }),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok || json?.ok !== true) {
    throw new Error(`detect 실패(${res.status}): ${json?.error || 'unknown'}`);
  }
  return json.result?.items ?? json.items ?? [];
}

const LABELS = new Set(['상', '중', '하']);
let updated = 0;
for (const page of pages) {
  const items = await detectPage(page, renderPage(page));
  const byNumber = new Map();
  for (const item of items) {
    const key = String(item?.number || '').trim();
    if (key) byNumber.set(key, item);
  }
  for (const crop of crops.filter((c) => c.raw_page === page)) {
    const hit = byNumber.get(String(crop.problem_number).trim());
    const label = String(hit?.label || '').trim();
    const important = hit?.is_important === true;
    if (!LABELS.has(label)) {
      console.log(`  p${page} ${crop.problem_number} → 난이도를 못 읽음, 건너뜀`);
      continue;
    }
    console.log(
      `  p${page} ${crop.problem_number} → 난이도=${label}${important ? ' 중요' : ''}`,
    );
    if (!apply) continue;
    const { error } = await supa
      .from('textbook_problem_crops')
      .update({ label, is_important: important })
      .eq('id', crop.id);
    if (error) throw new Error(error.message);
    updated += 1;
  }
}

console.log(
  apply
    ? `갱신 ${updated}건 완료`
    : '미리보기입니다. 반영하려면 --apply 를 붙여 다시 실행하세요.',
);
// supabase-js 가 남긴 keep-alive 소켓 때문에 스크립트가 끝나도 붙잡혀 있다.
process.exit(0);
