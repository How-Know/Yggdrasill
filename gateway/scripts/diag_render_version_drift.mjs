// renderer_version 불일치 자산 진단 (읽기 전용).
//
// Edge Function 은 student-single-v4 만 조회한다. 다른 버전으로 렌더된 자산이
// 남아 있으면 (a) 같은 crop 에 v4 자산도 있으면 무해한 잔재, (b) v4 자산이
// 없으면 매번 즉석 렌더 → 학생이 로딩을 본다.
//
// 사용: node scripts/diag_render_version_drift.mjs
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const CURRENT = 'pb_render_v4_slotmeasure_01:student-single-v4';

const url = String(process.env.SUPABASE_URL || '').trim();
const serviceKey = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
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

const assets = await selectAll(
  'question_render_assets',
  'crop_id,renderer_version,rendered_at,render_error,storage_path',
);

const currentByCrop = new Set();
const byVersion = new Map();
for (const a of assets) {
  const v = String(a.renderer_version ?? '');
  if (!byVersion.has(v)) byVersion.set(v, []);
  byVersion.get(v).push(a);
  if (v === CURRENT && a.rendered_at && !a.render_error) {
    currentByCrop.add(String(a.crop_id));
  }
}

console.log('=== renderer_version 별 자산 수 ===');
for (const [v, rows] of [...byVersion.entries()].sort((a, b) => b[1].length - a[1].length)) {
  const ok = rows.filter((r) => r.rendered_at && !r.render_error).length;
  const times = rows
    .map((r) => r.rendered_at)
    .filter(Boolean)
    .sort();
  const span = times.length
    ? `${times[0].slice(0, 10)} ~ ${times[times.length - 1].slice(0, 10)}`
    : '-';
  console.log(
    `${(v === CURRENT ? '* ' : '  ') + v.padEnd(46)} ${String(rows.length).padStart(6)}건 (성공 ${ok})  ${span}`,
  );
}

let orphan = 0;
let redundant = 0;
for (const [v, rows] of byVersion) {
  if (v === CURRENT) continue;
  for (const a of rows) {
    if (currentByCrop.has(String(a.crop_id))) redundant += 1;
    else orphan += 1;
  }
}
console.log(`\n구버전 자산 중 · 현재 버전도 있어 무해: ${redundant} · 현재 버전 없음(즉석 렌더 유발): ${orphan}`);
console.log('* = Edge Function 이 조회하는 현재 버전');
