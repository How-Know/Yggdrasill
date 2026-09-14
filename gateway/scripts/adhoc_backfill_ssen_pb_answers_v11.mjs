import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import {
  existsSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';

const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } },
);

const API_PORT = process.env.PB_API_PORT || '8787';
const STYLE_VERSION = 'answer-xelatex-v11-uniform-line';
const SOURCE_CHUNK_SIZE = Math.max(
  1,
  Math.min(80, Number.parseInt(process.env.SSEN_BACKFILL_CHUNK || '40', 10) || 40),
);
const CHECKPOINT_PATH = 'scripts/_ssen_pb_answer_v11_checkpoint.json';
const RESET = process.argv.includes('--reset');
const DRY_RUN = process.argv.includes('--dry-run');
const ts = () => new Date().toISOString().slice(11, 19);

function chunks(items, size) {
  const out = [];
  for (let i = 0; i < items.length; i += size) {
    out.push(items.slice(i, i + size));
  }
  return out;
}

function readCheckpoint() {
  if (RESET || !existsSync(CHECKPOINT_PATH)) return null;
  try {
    return JSON.parse(readFileSync(CHECKPOINT_PATH, 'utf8'));
  } catch {
    return null;
  }
}

function writeCheckpoint(value) {
  writeFileSync(CHECKPOINT_PATH, JSON.stringify(value, null, 2));
}

async function loadSsenTargets() {
  const { data: metadataRows, error: metadataError } = await supa
    .from('textbook_metadata')
    .select('academy_id,book_id,grade_label,payload');
  if (metadataError) throw metadataError;

  const ssenScopes = (metadataRows || [])
    .filter((row) => String(row?.payload?.series || '').trim().toLowerCase() === 'ssen')
    .map((row) => ({
      academyId: String(row.academy_id || '').trim(),
      bookId: String(row.book_id || '').trim(),
      gradeLabel: String(row.grade_label || '').trim(),
    }))
    .filter((row) => row.academyId && row.bookId && row.gradeLabel);

  const documentIdsByAcademy = new Map();
  for (const scope of ssenScopes) {
    const { data: runRows, error: runError } = await supa
      .from('textbook_pb_extract_runs')
      .select('pb_document_id')
      .eq('academy_id', scope.academyId)
      .eq('book_id', scope.bookId)
      .eq('grade_label', scope.gradeLabel)
      .not('pb_document_id', 'is', null);
    if (runError) throw runError;
    const ids = documentIdsByAcademy.get(scope.academyId) || new Set();
    for (const row of runRows || []) {
      const id = String(row?.pb_document_id || '').trim();
      if (id) ids.add(id);
    }
    documentIdsByAcademy.set(scope.academyId, ids);
  }

  const targetsByAcademy = new Map();
  for (const [academyId, documentIds] of documentIdsByAcademy) {
    const questionIds = new Set();
    for (const documentChunk of chunks([...documentIds], 10)) {
      const { data: questionRows, error: questionError } = await supa
        .from('pb_questions')
        .select('id')
        .eq('academy_id', academyId)
        .eq('allow_subjective', true)
        .in('document_id', documentChunk);
      if (questionError) throw questionError;
      for (const row of questionRows || []) {
        const id = String(row?.id || '').trim();
        if (id) questionIds.add(id);
      }
    }
    targetsByAcademy.set(academyId, [...questionIds].sort());
  }
  return targetsByAcademy;
}

async function postBackfill(academyId, sourceIds, attempt = 1) {
  try {
    const response = await fetch(
      `http://127.0.0.1:${API_PORT}/answers/render-assets/backfill`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          academy_id: academyId,
          source_kind: 'pb_question',
          source_ids: sourceIds,
          answer_kind: 'subjective',
          style_version: STYLE_VERSION,
          limit: sourceIds.length,
          force: false,
        }),
        signal: AbortSignal.timeout(15 * 60 * 1000),
      },
    );
    if (!response.ok) {
      throw new Error(`HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
    }
    return response.json();
  } catch (error) {
    if (attempt >= 3) throw error;
    console.error(`${ts()} chunk failed (attempt ${attempt}): ${error.message}`);
    await new Promise((resolve) => setTimeout(resolve, 5000));
    return postBackfill(academyId, sourceIds, attempt + 1);
  }
}

const targetsByAcademy = await loadSsenTargets();
const academyEntries = [...targetsByAcademy.entries()].sort(([a], [b]) =>
  a.localeCompare(b),
);
if (DRY_RUN) {
  for (const [academyId, questionIds] of academyEntries) {
    console.log(`${academyId} ssen_questions=${questionIds.length}`);
  }
  console.log(
    `total_ssen_questions=${academyEntries.reduce((sum, [, ids]) => sum + ids.length, 0)}`,
  );
  process.exit(0);
}
const checkpoint = readCheckpoint();
let resumeReached = !checkpoint;
let totalRendered = 0;
let totalFailed = 0;

for (const [academyId, questionIds] of academyEntries) {
  const sourceChunks = chunks(questionIds, SOURCE_CHUNK_SIZE);
  console.log(`${ts()} academy=${academyId} ssen_questions=${questionIds.length}`);
  for (let chunkIndex = 0; chunkIndex < sourceChunks.length; chunkIndex += 1) {
    if (!resumeReached) {
      if (
        checkpoint.academyId === academyId &&
        Number(checkpoint.chunkIndex || 0) <= chunkIndex
      ) {
        resumeReached = true;
      } else {
        continue;
      }
    }
    const result = await postBackfill(academyId, sourceChunks[chunkIndex]);
    const render = result?.render_assets || {};
    totalRendered += Number(render.rendered || 0);
    totalFailed += Number(render.failed || 0);
    console.log(
      `${ts()} academy=${academyId} chunk=${chunkIndex + 1}/${sourceChunks.length} ` +
        `questions=${sourceChunks[chunkIndex].length} attempted=${render.attempted || 0} ` +
        `rendered=${render.rendered || 0} failed=${render.failed || 0}`,
    );
    writeCheckpoint({
      academyId,
      chunkIndex: chunkIndex + 1,
      updatedAt: new Date().toISOString(),
    });
  }
}

writeCheckpoint({
  done: true,
  rendered: totalRendered,
  failed: totalFailed,
  updatedAt: new Date().toISOString(),
});
console.log(`${ts()} ALL DONE rendered=${totalRendered} failed=${totalFailed}`);
