// Diagnose resource_file_links migration state, focused on solution PDFs.
//
// Reports:
//   - migration_status distribution across all rows (and per kind)
//   - for `sol` (해설) rows: how many have file_size_bytes populated vs null/0
//   - largest solution PDFs by size
//   - rows still on `legacy` (no local-cache path) for sol/ans
//
// Usage: node gateway/scripts/adhoc_textbook_link_status.mjs

import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error('missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY');
  process.exit(1);
}
const supa = createClient(url, key, { auth: { persistSession: false } });

// resource_file_links.grade encodes a composite like "<grade_label>::<kind>".
// We don't know the exact separator here, so derive kind heuristically from
// the grade string. Pull everything and bucket in JS.
const PAGE = 1000;
let from = 0;
const rows = [];
for (;;) {
  const { data, error } = await supa
    .from('resource_file_links')
    .select(
      'id, academy_id, file_id, grade, migration_status, file_size_bytes, content_hash, storage_key, storage_bucket, storage_driver, url, uploaded_at',
    )
    .range(from, from + PAGE - 1);
  if (error) throw error;
  if (!data || data.length === 0) break;
  rows.push(...data);
  if (data.length < PAGE) break;
  from += PAGE;
}

console.log(`총 resource_file_links 행: ${rows.length}`);

function kindOf(grade) {
  const g = String(grade || '').toLowerCase();
  if (g.includes('sol')) return 'sol';
  if (g.includes('ans')) return 'ans';
  if (g.includes('body')) return 'body';
  return 'other';
}

const byStatus = {};
const byKindStatus = {};
for (const r of rows) {
  const st = String(r.migration_status || 'legacy');
  const kind = kindOf(r.grade);
  byStatus[st] = (byStatus[st] || 0) + 1;
  byKindStatus[kind] = byKindStatus[kind] || {};
  byKindStatus[kind][st] = (byKindStatus[kind][st] || 0) + 1;
}

console.log('\n=== migration_status 분포 (전체) ===');
for (const [st, n] of Object.entries(byStatus).sort((a, b) => b[1] - a[1])) {
  console.log(`  ${st.padEnd(10)} : ${n}`);
}

console.log('\n=== kind × migration_status ===');
for (const [kind, m] of Object.entries(byKindStatus)) {
  const parts = Object.entries(m)
    .map(([s, n]) => `${s}=${n}`)
    .join('  ');
  console.log(`  ${kind.padEnd(6)} : ${parts}`);
}

// Focus on sol + ans (the kinds used for 해설/답지 viewing).
const viewerRows = rows.filter((r) => {
  const k = kindOf(r.grade);
  return k === 'sol' || k === 'ans';
});

let sizeMissing = 0;
let sizeZero = 0;
let sizeOk = 0;
for (const r of viewerRows) {
  const sz = Number(r.file_size_bytes);
  if (r.file_size_bytes == null) sizeMissing += 1;
  else if (!Number.isFinite(sz) || sz <= 0) sizeZero += 1;
  else sizeOk += 1;
}
console.log('\n=== 해설/답지(sol+ans) file_size_bytes 상태 ===');
console.log(`  대상 행            : ${viewerRows.length}`);
console.log(`  size NULL          : ${sizeMissing}  (캐시 검증 통과 → 재다운로드 안함)`);
console.log(`  size 0/invalid     : ${sizeZero}  (캐시 검증 통과 → 재다운로드 안함)`);
console.log(`  size 정상(>0)      : ${sizeOk}  (로컬 크기와 다르면 재다운로드 유발)`);

const legacyViewer = viewerRows.filter(
  (r) => String(r.migration_status || 'legacy') === 'legacy',
);
console.log('\n=== legacy 상태(캐시 미적용 → 매번 스트리밍) ===');
console.log(`  sol+ans legacy 행  : ${legacyViewer.length}`);

console.log('\n=== 가장 큰 해설/답지 PDF Top 15 ===');
const sorted = [...viewerRows]
  .filter((r) => Number(r.file_size_bytes) > 0)
  .sort((a, b) => Number(b.file_size_bytes) - Number(a.file_size_bytes))
  .slice(0, 15);
for (const r of sorted) {
  const mb = (Number(r.file_size_bytes) / (1024 * 1024)).toFixed(1);
  console.log(
    `  id=${String(r.id).padEnd(7)} ${String(kindOf(r.grade)).padEnd(4)} ${String(r.migration_status || 'legacy').padEnd(9)} ${mb.padStart(7)}MB  grade="${r.grade}"`,
  );
}

process.exit(0);
