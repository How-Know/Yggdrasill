// 읽기 전용 진단 스크립트.
// 목적: 특정 문서(또는 최근 N개)에서 "figure 워커가 성공을 찍었는데
//       매니저 앱에는 그림이 안 뜨는" 현상의 원인을 단계별로 확정한다.
//
// 사용법 (gateway 폴더에서):
//   # (1) 최근 5개 문서 자동 요약
//   node scripts/diagnose_figures.mjs
//   # (2) 특정 document_id 한 건 상세
//   node scripts/diagnose_figures.mjs <document_id>
//
// 이 스크립트는 SELECT + Storage HEAD/DOWNLOAD 만 수행하며,
// 어떤 테이블/Storage 에도 UPDATE/INSERT/DELETE 하지 않는다.

import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 가 .env 에 필요합니다.');
  process.exit(2);
}
const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

function pad(s, n) {
  const x = String(s ?? '');
  return x.length >= n ? x.slice(0, n) : x + ' '.repeat(n - x.length);
}

async function countByStatus(documentId) {
  const { data, error } = await supa
    .from('pb_figure_jobs')
    .select('status,error_code,error_message,updated_at')
    .eq('document_id', documentId)
    .limit(500);
  if (error) return { error: error.message };
  const byStatus = {};
  const failures = [];
  for (const r of data || []) {
    byStatus[r.status] = (byStatus[r.status] || 0) + 1;
    if (r.status === 'failed') {
      failures.push({
        err: r.error_code || '',
        msg: (r.error_message || '').slice(0, 120),
      });
    }
  }
  return { byStatus, failures, total: (data || []).length };
}

async function listQuestions(documentId) {
  const { data, error } = await supa
    .from('pb_questions')
    .select('id,question_number,figure_refs,stem,meta,updated_at')
    .eq('document_id', documentId)
    .order('source_page', { ascending: true })
    .order('source_order', { ascending: true });
  if (error) throw new Error(`pb_questions select failed: ${error.message}`);
  return data || [];
}

// stem 텍스트에서 그림이 "있어야 하는" 위치를 암시하는 마커 수를 센다.
// 실제로 어떤 토큰을 쓰는지는 파이프라인 버전에 따라 다르므로 알려진 변종을
// 모두 조사한다. ((FIG1)), {{FIG1}}, <fig1/>, [그림1], 등.
function countFigureMarkers(stem) {
  const s = String(stem || '');
  if (!s) return 0;
  const patterns = [
    /\(\(\s*FIG\s*\d+\s*\)\)/gi,
    /\{\{\s*FIG\s*\d+\s*\}\}/gi,
    /<\s*fig\s*\d+\s*\/?>/gi,
    /\[\s*FIG\s*\d+\s*\]/gi,
    /\[\s*그림\s*\d+\s*\]/g,
    /\(\s*FIG\s*\d+\s*\)/gi,
  ];
  let total = 0;
  for (const p of patterns) {
    const m = s.match(p);
    if (m) total += m.length;
  }
  return total;
}

async function checkStorageObject(bucket, path) {
  try {
    const { data: signed, error: signErr } = await supa.storage
      .from(bucket)
      .createSignedUrl(path, 60);
    if (signErr || !signed?.signedUrl) {
      return { ok: false, reason: `sign_failed:${signErr?.message || 'no_url'}` };
    }
    // 실제 파일 전체 다운로드해서 byteLength 확인 (Range 아님)
    const res = await fetch(signed.signedUrl);
    if (!res.ok) {
      return { ok: false, status: res.status, reason: `http_${res.status}` };
    }
    const buf = await res.arrayBuffer();
    // PNG 매직 확인 (89 50 4E 47 0D 0A 1A 0A)
    const u8 = new Uint8Array(buf);
    const isPng =
      u8.length >= 8 &&
      u8[0] === 0x89 && u8[1] === 0x50 && u8[2] === 0x4e && u8[3] === 0x47;
    return {
      ok: true,
      status: res.status,
      bytes: u8.length,
      contentType: res.headers.get('content-type') || '',
      isPng,
    };
  } catch (e) {
    return { ok: false, reason: `fetch_error:${e?.message || e}` };
  }
}

async function diagnoseOne(documentId) {
  console.log('\n=== Document', documentId, '===');
  const { data: doc, error: docErr } = await supa
    .from('pb_documents')
    .select('id,source_filename,academy_id,updated_at,status')
    .eq('id', documentId)
    .maybeSingle();
  if (docErr || !doc) {
    console.log('  ! 문서 조회 실패 또는 없음:', docErr?.message || 'not_found');
    return;
  }
  console.log('  filename    :', doc.source_filename);
  console.log('  academy_id  :', doc.academy_id);
  console.log('  status      :', doc.status);
  console.log('  updated_at  :', doc.updated_at);

  const jobSummary = await countByStatus(documentId);
  if (jobSummary.error) {
    console.log('  ! figure_jobs 조회 실패:', jobSummary.error);
  } else {
    console.log(
      '  figure_jobs :',
      JSON.stringify(jobSummary.byStatus),
      '(total =', jobSummary.total, ')',
    );
    if (jobSummary.failures.length) {
      console.log('    실패 예시 (최대 3):');
      for (const f of jobSummary.failures.slice(0, 3)) {
        console.log('     -', f.err, '|', f.msg);
      }
    }
  }

  const qs = await listQuestions(documentId);
  const hasRef = qs.filter((q) => Array.isArray(q.figure_refs) && q.figure_refs.length > 0);
  console.log('  questions   : total =', qs.length, ', with figure_refs =', hasRef.length);

  // meta.figure_assets 상태 분포 + stem 의 figure marker 개수 비교
  let emptyAssets = 0;
  let filledAssets = 0;
  const mismatch = []; // figure_refs 있는데 figure_assets 비어있는 케이스
  const markerMismatch = []; // stem 에 fig marker 는 있는데 figure_refs 없는 케이스
  const perQuestion = [];
  for (const q of qs) {
    const meta = q.meta && typeof q.meta === 'object' ? q.meta : {};
    const assets = Array.isArray(meta.figure_assets) ? meta.figure_assets : [];
    const refs = Array.isArray(q.figure_refs) ? q.figure_refs : [];
    const marker = countFigureMarkers(q.stem);
    if (assets.length === 0) emptyAssets += 1;
    else filledAssets += 1;
    if (refs.length > 0 && assets.length === 0) {
      mismatch.push({ id: q.id, qn: q.question_number });
    }
    if (marker > 0 && refs.length === 0) {
      markerMismatch.push({ qn: q.question_number, marker });
    }
    if (marker > 0 || refs.length > 0 || assets.length > 0) {
      perQuestion.push({
        qn: q.question_number,
        marker,
        refs: refs.length,
        assets: assets.length,
      });
    }
  }
  console.log('  meta assets : filled =', filledAssets, ', empty =', emptyAssets);
  if (perQuestion.length) {
    console.log('  --- 문항별 상세 (marker=stem내 그림마커, refs=figure_refs, assets=figure_assets) ---');
    for (const p of perQuestion) {
      console.log('     q', pad(p.qn, 3), ' marker=', p.marker, ' refs=', p.refs, ' assets=', p.assets);
    }
  }
  if (mismatch.length) {
    console.log('  ! figure_refs 는 있는데 figure_assets 가 비어있는 문항:');
    for (const m of mismatch.slice(0, 10)) {
      console.log('     - q', m.qn, m.id);
    }
    if (mismatch.length > 10) console.log('       ... (+', mismatch.length - 10, ')');
  }
  if (markerMismatch.length) {
    console.log('  ! stem 에 그림 마커는 있는데 figure_refs 가 빠진 문항:');
    for (const m of markerMismatch.slice(0, 10)) {
      console.log('     - q', m.qn, ' markers=', m.marker);
    }
  }

  // 샘플 asset 의 Storage 실제 접근성 확인
  console.log('  --- Storage access check (sampling up to 5) ---');
  let sampled = 0;
  for (const q of qs) {
    if (sampled >= 5) break;
    const meta = q.meta && typeof q.meta === 'object' ? q.meta : {};
    const assets = Array.isArray(meta.figure_assets) ? meta.figure_assets : [];
    for (const a of assets) {
      if (sampled >= 5) break;
      const bucket = String(a?.bucket || '').trim();
      const path = String(a?.path || '').trim();
      if (!bucket || !path) continue;
      const r = await checkStorageObject(bucket, path);
      sampled += 1;
      console.log(
        '   q', pad(q.question_number, 3),
        '|', pad(bucket, 18),
        '|', pad(path, 90),
        '=>',
        r.ok
          ? `OK ${r.status} ${r.contentType} bytes=${r.bytes} png=${r.isPng}`
          : `FAIL ${r.reason || r.status}`,
      );
    }
  }
  if (sampled === 0) {
    console.log('   (샘플할 figure_assets 가 없어서 Storage 체크 스킵)');
  }
}

async function main() {
  const arg = process.argv[2];
  if (arg) {
    await diagnoseOne(arg);
    return;
  }
  // 인자 없을 때: 최근 5개 문서 상단 요약
  const { data: recent, error } = await supa
    .from('pb_documents')
    .select('id,source_filename,updated_at')
    .order('updated_at', { ascending: false })
    .limit(5);
  if (error) {
    console.error('pb_documents 조회 실패:', error.message);
    process.exit(1);
  }
  console.log('최근 업데이트된 문서 5건:');
  for (const d of recent || []) {
    console.log('  ', d.updated_at, '|', pad(d.id, 36), '|', d.source_filename);
  }
  for (const d of recent || []) {
    await diagnoseOne(d.id);
  }
}

main().catch((e) => {
  console.error('diagnose_figures failed:', e?.stack || e?.message || e);
  process.exit(1);
});
