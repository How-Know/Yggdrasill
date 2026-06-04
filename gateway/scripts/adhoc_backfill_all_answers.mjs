import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const supa = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const CHECKPOINT = 'scripts/_backfill_checkpoint.json';
function readCheckpoint() {
  try {
    if (existsSync(CHECKPOINT)) return JSON.parse(readFileSync(CHECKPOINT, 'utf8'));
  } catch (_) { /* ignore */ }
  return null;
}
function writeCheckpoint(obj) {
  try { writeFileSync(CHECKPOINT, JSON.stringify(obj)); } catch (_) { /* ignore */ }
}

const port = process.env.PB_API_PORT || '8787';
// 한 요청이 Node fetch 기본 헤더 타임아웃(~300s)을 넘지 않도록 페이지를 작게.
// (이전 96 descriptor 렌더 ~155s 기준, 40문항이면 여유 있게 5분 이내)
const LIMIT = 40;
const SOURCE_KIND = process.argv[2] || 'pb_question';
// 시작 offset: 인자가 있으면 우선, 없으면 체크포인트 파일에서 복구 (pm2 자동재시작 대비)
const cp = readCheckpoint();
if (cp && cp.offset === 'done') {
  console.log(`${new Date().toISOString().slice(11, 19)} checkpoint=done; nothing to do.`);
  process.exit(0);
}
const START_OFFSET = process.argv[3] != null
  ? Math.max(0, Number.parseInt(process.argv[3], 10) || 0)
  : (cp && Number.isFinite(cp.offset) ? cp.offset : 0);

async function postBackfill(payload, attempt = 1) {
  try {
    const res = await fetch(`http://127.0.0.1:${port}/answers/render-assets/backfill`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(payload),
    });
    return res;
  } catch (err) {
    if (attempt <= 3) {
      console.error(`${new Date().toISOString().slice(11, 19)} fetch error (attempt ${attempt}): ${err?.cause?.code || err?.message}; retrying in 5s`);
      await new Promise((r) => setTimeout(r, 5000));
      return postBackfill(payload, attempt + 1);
    }
    throw err;
  }
}

const { data: docs } = await supa.from('pb_documents').select('academy_id');
const academies = [...new Set((docs || []).map((d) => d.academy_id))];

const ts = () => new Date().toISOString().slice(11, 19);

for (const academyId of academies) {
  let offset = START_OFFSET;
  let page = 0;
  let totalAttempted = 0;
  let totalRendered = 0;
  let totalFailed = 0;
  const allErrors = [];
  console.log(`${ts()} === academy ${academyId} (${SOURCE_KIND}) ===`);

  while (true) {
    page += 1;
    const res = await postBackfill({
      academy_id: academyId,
      source_kind: SOURCE_KIND,
      limit: LIMIT,
      offset,
      force: true,
    });
    if (!res.ok) {
      const txt = await res.text();
      console.error(`${ts()} page#${page} HTTP ${res.status}: ${txt.slice(0, 300)}`);
      break;
    }
    const j = await res.json();
    const ra = j.render_assets || {};
    totalAttempted += ra.attempted || 0;
    totalRendered += ra.rendered || 0;
    totalFailed += ra.failed || 0;
    if (Array.isArray(ra.errors)) allErrors.push(...ra.errors);
    console.log(
      `${ts()} page#${page} offset=${offset} fetched=${j.fetched} `
      + `attempted=${ra.attempted} rendered=${ra.rendered} failed=${ra.failed} `
      + `has_more=${j.has_more} | cum rendered=${totalRendered} failed=${totalFailed}`,
    );
    if (!j.has_more) break;
    offset += LIMIT;
    writeCheckpoint({ offset });
  }

  console.log(
    `${ts()} === DONE academy ${academyId}: attempted=${totalAttempted} `
    + `rendered=${totalRendered} failed=${totalFailed} ===`,
  );
  if (allErrors.length > 0) {
    console.log('sample errors:', JSON.stringify(allErrors.slice(0, 8)));
  }
}

writeCheckpoint({ offset: 'done' });
console.log(`${ts()} ALL DONE`);
