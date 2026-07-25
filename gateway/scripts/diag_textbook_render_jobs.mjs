// 교재별 렌더 잡/실패/미매핑 진단 (읽기 전용).
//
// diag_textbook_render_readiness 로 "예열 제외" 는 0 임을 확인했으므로,
// 남은 후보는 ① 렌더 잡이 실패/적체 ② 문항 매핑 실패로 body PDF 폴백.
//
// 사용: node scripts/diag_textbook_render_jobs.mjs
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const RENDER_PROFILE = 'student-single-v1';
const RENDERER_VERSION = 'pb_render_v4_slotmeasure_01:student-single-v4';

const url = String(process.env.SUPABASE_URL || '').trim();
const serviceKey = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
if (!url || !serviceKey) {
  throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
}
const supabase = createClient(url, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function selectAll(table, columns, configure) {
  const rows = [];
  for (let from = 0; ; from += 1000) {
    let query = supabase.from(table).select(columns).range(from, from + 999);
    query = configure ? configure(query) : query;
    const { data, error } = await query;
    if (error) throw new Error(`${table}_select_failed:${error.message}`);
    const batch = data ?? [];
    rows.push(...batch);
    if (batch.length < 1000) return rows;
  }
}

const books = await selectAll('resource_files', 'id,name');
const bookName = new Map(books.map((b) => [String(b.id), String(b.name ?? '')]));

const crops = await selectAll(
  'textbook_problem_crops',
  'id,book_id,pb_question_uid',
  (q) => q.eq('is_set_header', false),
);
const cropBook = new Map(crops.map((c) => [String(c.id), String(c.book_id)]));

const jobs = await selectAll(
  'question_render_jobs',
  'crop_id,status,priority,error',
  (q) => q.eq('render_profile', RENDER_PROFILE),
);
const failedAssets = await selectAll(
  'question_render_assets',
  'crop_id,render_error,renderer_version',
  (q) => q.neq('render_error', ''),
);
// 버전이 달라 무효가 된 캐시 (renderer_version 불일치).
const staleAssets = await selectAll(
  'question_render_assets',
  'crop_id,renderer_version',
  (q) => q.neq('renderer_version', RENDERER_VERSION),
);

function tally(rows, keyFn) {
  const out = new Map();
  for (const row of rows) {
    const book = cropBook.get(String(row.crop_id));
    if (!book) continue;
    const name = bookName.get(book) || book;
    if (!out.has(name)) out.set(name, new Map());
    const inner = out.get(name);
    const k = keyFn(row);
    inner.set(k, (inner.get(k) ?? 0) + 1);
  }
  return out;
}

console.log('=== question_render_jobs (status별) ===');
const jobTally = tally(jobs, (r) => String(r.status ?? ''));
for (const [book, inner] of jobTally) {
  const parts = [...inner.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([k, v]) => `${k}=${v}`)
    .join('  ');
  console.log(`${book.padEnd(16)} ${parts}`);
}

console.log('\n=== 실패한 잡의 error 상위 ===');
const errors = new Map();
for (const job of jobs) {
  const msg = String(job.error ?? '').trim();
  if (!msg) continue;
  const book = bookName.get(cropBook.get(String(job.crop_id)) ?? '') || '?';
  const key = `${book} :: ${msg.slice(0, 110)}`;
  errors.set(key, (errors.get(key) ?? 0) + 1);
}
for (const [k, v] of [...errors.entries()].sort((a, b) => b[1] - a[1]).slice(0, 15)) {
  console.log(`${String(v).padStart(5)}  ${k}`);
}
if (errors.size === 0) console.log('(없음)');

console.log('\n=== render_error 가 남은 asset ===');
const failTally = tally(failedAssets, (r) =>
  String(r.render_error ?? '').slice(0, 80),
);
for (const [book, inner] of failTally) {
  for (const [k, v] of [...inner.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5)) {
    console.log(`${book.padEnd(16)} ${String(v).padStart(5)}  ${k}`);
  }
}
if (failTally.size === 0) console.log('(없음)');

console.log('\n=== 구버전 renderer_version 캐시 (현재 버전과 불일치) ===');
const staleTally = tally(staleAssets, (r) => String(r.renderer_version ?? ''));
for (const [book, inner] of staleTally) {
  for (const [k, v] of [...inner.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`${book.padEnd(16)} ${String(v).padStart(5)}  ${k}`);
  }
}
if (staleTally.size === 0) console.log('(없음)');

console.log('\n=== 매핑 안 된 crop (uid 없음 + canonical link 없음) ===');
const links = await selectAll('textbook_crop_question_links', 'crop_id');
const linked = new Set(links.map((r) => String(r.crop_id)));
const orphanByBook = new Map();
for (const crop of crops) {
  if (crop.pb_question_uid || linked.has(String(crop.id))) continue;
  const name = bookName.get(String(crop.book_id)) || String(crop.book_id);
  orphanByBook.set(name, (orphanByBook.get(name) ?? 0) + 1);
}
for (const [k, v] of [...orphanByBook.entries()].sort((a, b) => b[1] - a[1])) {
  console.log(`${k.padEnd(16)} ${String(v).padStart(5)} 건 → view 시 body PDF 폴백`);
}
if (orphanByBook.size === 0) console.log('(없음)');
