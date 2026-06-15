// For migrated sol/ans textbook links, compare:
//   - DB file_size_bytes (what the client expects)
//   - Supabase storage object size (list metadata)
//   - actual signed-URL Content-Length (what the client really downloads)
//
// A mismatch between DB file_size_bytes and the real download size means
// TextbookPdfService.resolve() treats the cache as stale and re-downloads the
// whole PDF on EVERY open.
//
// Usage: node gateway/scripts/adhoc_textbook_size_audit.mjs

import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!url || !key) {
  console.error('missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY');
  process.exit(1);
}
const supa = createClient(url, key, { auth: { persistSession: false } });

function kindOf(grade) {
  const g = String(grade || '').toLowerCase();
  if (g.includes('sol')) return 'sol';
  if (g.includes('ans')) return 'ans';
  if (g.includes('body')) return 'body';
  return 'other';
}

async function headSize({ bucket, storageKey }) {
  const segments = String(storageKey).split('/');
  const base = segments.pop() || '';
  const prefix = segments.join('/');
  const { data, error } = await supa.storage
    .from(bucket)
    .list(prefix, { limit: 100, search: base });
  if (error) return { ok: false, error: error.message || String(error) };
  const entry = Array.isArray(data) ? data.find((e) => e?.name === base) : null;
  if (!entry) return { ok: false, error: 'not_found' };
  return { ok: true, size: Number(entry?.metadata?.size || 0) };
}

async function signedContentLength({ bucket, storageKey }) {
  const { data, error } = await supa.storage
    .from(bucket)
    .createSignedUrl(storageKey, 120);
  if (error) return { ok: false, error: error.message || String(error) };
  const signed = String(data?.signedUrl || '');
  if (!signed) return { ok: false, error: 'no_signed_url' };
  // Range request for first byte → response carries Content-Range total.
  try {
    const res = await fetch(signed, { headers: { Range: 'bytes=0-0' } });
    const cr = res.headers.get('content-range'); // bytes 0-0/12345
    if (cr && cr.includes('/')) {
      const total = Number(cr.split('/')[1]);
      if (Number.isFinite(total)) return { ok: true, size: total };
    }
    const cl = res.headers.get('content-length');
    if (cl && res.status === 200) return { ok: true, size: Number(cl) };
    return { ok: false, error: `status=${res.status} cr=${cr} cl=${cl}` };
  } catch (e) {
    return { ok: false, error: e?.message || String(e) };
  }
}

const { data: rows, error } = await supa
  .from('resource_file_links')
  .select(
    'id, grade, migration_status, file_size_bytes, storage_bucket, storage_key',
  )
  .eq('migration_status', 'migrated');
if (error) throw error;

const targets = (rows || []).filter((r) => {
  const k = kindOf(r.grade);
  return k === 'sol' || k === 'ans';
});

console.log(`migrated sol/ans 행: ${targets.length}\n`);
console.log(
  'id      kind grade                 DB_size      store_size   served_size  verdict',
);
console.log('-'.repeat(95));

let mismatchCount = 0;
for (const r of targets) {
  const bucket = r.storage_bucket;
  const storageKey = r.storage_key;
  const dbSize = Number(r.file_size_bytes || 0);
  let storeSize = -1;
  let servedSize = -1;
  if (bucket && storageKey) {
    const h = await headSize({ bucket, storageKey });
    if (h.ok) storeSize = h.size;
    const s = await signedContentLength({ bucket, storageKey });
    if (s.ok) servedSize = s.size;
  }
  const fmt = (n) =>
    n < 0 ? 'ERR'.padStart(12) : String(n).padStart(12);
  const dbVsServed =
    servedSize >= 0 && dbSize > 0 && servedSize !== dbSize
      ? '⚠ MISMATCH → 매오픈 재다운로드'
      : dbSize === 0
        ? '(DB=0 → 검증생략)'
        : 'ok';
  if (dbVsServed.startsWith('⚠')) mismatchCount += 1;
  console.log(
    `${String(r.id).padEnd(7)} ${kindOf(r.grade).padEnd(4)} ${String(r.grade).padEnd(20)} ${fmt(dbSize)} ${fmt(storeSize)} ${fmt(servedSize)}  ${dbVsServed}`,
  );
}

console.log('\n' + '='.repeat(60));
console.log(`크기 불일치(매 오픈 재다운로드) 행: ${mismatchCount} / ${targets.length}`);
process.exit(0);
