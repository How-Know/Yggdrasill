import 'dotenv/config';
import { pathToFileURL } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import {
  renderSingleQuestionPdf,
  SINGLE_QUESTION_RENDERER_VERSION,
} from './problem_bank_export_worker.js';
import {
  canonicalize,
  hashQuestionContent as computeQuestionContentHash,
} from './question_render_cache_key.js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const BATCH_SIZE = Math.max(
  1,
  Number.parseInt(process.env.QUESTION_RENDER_WORKER_BATCH_SIZE || '4', 10),
);
const INTERVAL_MS = Math.max(
  250,
  Number.parseInt(process.env.QUESTION_RENDER_WORKER_INTERVAL_MS || '1500', 10),
);
const STALE_MS = Math.max(
  30_000,
  Number.parseInt(process.env.QUESTION_RENDER_WORKER_STALE_MS || '600000', 10),
);
const WORKER_NAME =
  process.env.QUESTION_RENDER_WORKER_NAME || `question-render-${process.pid}`;
const PROCESS_ONCE =
  process.argv.includes('--once') ||
  process.env.QUESTION_RENDER_WORKER_ONCE === '1';
const STORAGE_BUCKET = 'question-renders';
const IS_DIRECT_RUN =
  (typeof process.argv[1] === 'string' &&
    import.meta.url === pathToFileURL(process.argv[1]).href) ||
  (typeof process.env.pm_exec_path === 'string' &&
    process.env.pm_exec_path.length > 0 &&
    import.meta.url === pathToFileURL(process.env.pm_exec_path).href);

const supabase =
  SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY
    ? createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
        auth: { persistSession: false, autoRefreshToken: false },
      })
    : null;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function hashQuestionContent(
  question,
  renderProfile,
  rendererVersion = SINGLE_QUESTION_RENDERER_VERSION,
  namespace = '',
) {
  return computeQuestionContentHash(
    question,
    renderProfile,
    rendererVersion,
    namespace,
  );
}

async function reclaimStaleJobs(client) {
  const staleBefore = new Date(Date.now() - STALE_MS).toISOString();
  const { data, error } = await client
    .from('question_render_jobs')
    .select('id,retry_count,max_retries,heartbeat_at,started_at')
    .eq('status', 'rendering')
    .or(`heartbeat_at.lt.${staleBefore},and(heartbeat_at.is.null,started_at.lt.${staleBefore})`)
    .limit(BATCH_SIZE * 2);
  if (error) throw new Error(`stale_query_failed:${error.message}`);

  for (const job of data || []) {
    const nextRetry = Number(job.retry_count || 0) + 1;
    const exhausted = nextRetry > Number(job.max_retries || 0);
    await client
      .from('question_render_jobs')
      .update({
        status: exhausted ? 'failed' : 'queued',
        retry_count: nextRetry,
        available_at: new Date().toISOString(),
        worker_name: '',
        heartbeat_at: null,
        finished_at: exhausted ? new Date().toISOString() : null,
        error: 'stale_render_reclaimed',
      })
      .eq('id', job.id)
      .eq('status', 'rendering');
  }
}

async function claimJobs(client) {
  const now = new Date().toISOString();
  const { data, error } = await client
    .from('question_render_jobs')
    .select('*')
    .eq('status', 'queued')
    .lte('available_at', now)
    .order('priority', { ascending: true })
    .order('available_at', { ascending: true })
    .order('created_at', { ascending: true })
    .limit(BATCH_SIZE * 3);
  if (error) throw new Error(`job_poll_failed:${error.message}`);

  const claimed = [];
  for (const candidate of data || []) {
    if (claimed.length >= BATCH_SIZE) break;
    const { data: rows, error: claimError } = await client
      .from('question_render_jobs')
      .update({
        status: 'rendering',
        worker_name: WORKER_NAME,
        started_at: now,
        heartbeat_at: now,
        error: '',
      })
      .eq('id', candidate.id)
      .eq('status', 'queued')
      .select('*');
    if (claimError) throw new Error(`job_claim_failed:${claimError.message}`);
    if (rows?.length === 1) claimed.push(rows[0]);
  }
  return claimed;
}

async function resolveQuestion(client, job) {
  const fields =
    'id,academy_id,document_id,question_uid,question_number,question_type,stem,choices,figure_refs,equations,meta';
  if (job.pb_question_id) {
    const { data } = await client
      .from('pb_questions')
      .select(fields)
      .eq('academy_id', job.academy_id)
      .eq('id', job.pb_question_id)
      .maybeSingle();
    if (data) return data;
  }

  const { data: crop, error: cropError } = await client
    .from('textbook_problem_crops')
    .select('id,pb_question_uid')
    .eq('academy_id', job.academy_id)
    .eq('id', job.crop_id)
    .maybeSingle();
  if (cropError || !crop) throw new Error('crop_not_found');

  if (crop.pb_question_uid) {
    const { data } = await client
      .from('pb_questions')
      .select(fields)
      .eq('academy_id', job.academy_id)
      .eq('question_uid', crop.pb_question_uid)
      .maybeSingle();
    if (data) return data;
  }

  const { data: fallback, error: fallbackError } = await client
    .from('pb_questions')
    .select(fields)
    .eq('academy_id', job.academy_id)
    .contains('meta', {
      textbook_crop_page: { crop_id: String(job.crop_id) },
    })
    .order('updated_at', { ascending: false })
    .limit(1);
  if (fallbackError) {
    throw new Error(`question_meta_lookup_failed:${fallbackError.message}`);
  }
  if (!fallback?.[0]) throw new Error('pb_question_not_mapped');
  return fallback[0];
}

async function completeJob(client, job, patch = {}) {
  const { error } = await client
    .from('question_render_jobs')
    .update({
      status: 'completed',
      finished_at: new Date().toISOString(),
      heartbeat_at: new Date().toISOString(),
      error: '',
      ...patch,
    })
    .eq('id', job.id)
    .eq('status', 'rendering')
    .eq('worker_name', WORKER_NAME);
  if (error) throw new Error(`job_complete_failed:${error.message}`);
}

async function failJob(client, job, error) {
  const retryCount = Number(job.retry_count || 0) + 1;
  const willRetry = retryCount <= Number(job.max_retries || 0);
  const delayMs = Math.min(60_000, 1000 * 2 ** Math.min(retryCount, 6));
  const { error: updateError } = await client
    .from('question_render_jobs')
    .update({
      status: willRetry ? 'queued' : 'failed',
      retry_count: retryCount,
      available_at: new Date(Date.now() + delayMs).toISOString(),
      worker_name: willRetry ? '' : WORKER_NAME,
      heartbeat_at: null,
      finished_at: willRetry ? null : new Date().toISOString(),
      error: String(error?.message || error).slice(0, 4000),
    })
    .eq('id', job.id)
    .eq('status', 'rendering')
    .eq('worker_name', WORKER_NAME);
  if (updateError) {
    throw new Error(`job_fail_update_failed:${updateError.message}`);
  }
}

async function processJob(client, job) {
  const question = await resolveQuestion(client, job);
  const renderProfile = String(job.render_profile || 'student-single-v1');
  const { contentHash, cacheKey } = hashQuestionContent(
    question,
    renderProfile,
    SINGLE_QUESTION_RENDERER_VERSION,
    `${job.academy_id}:${job.crop_id}`,
  );
  const storagePath = `${job.academy_id}/${cacheKey}.pdf`;

  const { data: existing, error: existingError } = await client
    .from('question_render_assets')
    .select('id,storage_bucket,storage_path,page_count,rendered_at,render_error')
    .eq('cache_key', cacheKey)
    .maybeSingle();
  if (existingError) {
    throw new Error(`asset_lookup_failed:${existingError.message}`);
  }
  if (existing?.rendered_at && !existing.render_error) {
    const { data: objects, error: listError } = await client.storage
      .from(existing.storage_bucket)
      .list(String(job.academy_id), {
        search: `${cacheKey}.pdf`,
        limit: 2,
      });
    const objectExists =
      !listError &&
      (objects || []).some((object) => object.name === `${cacheKey}.pdf`);
    if (objectExists) {
      await completeJob(client, job, {
        pb_question_id: question.id,
        cache_key: cacheKey,
      });
      return { cached: true, cacheKey };
    }
  }

  const heartbeat = new Date().toISOString();
  await client
    .from('question_render_jobs')
    .update({
      heartbeat_at: heartbeat,
      pb_question_id: question.id,
      cache_key: cacheKey,
    })
    .eq('id', job.id)
    .eq('worker_name', WORKER_NAME);

  try {
    const rendered = await renderSingleQuestionPdf({
      academyId: job.academy_id,
      question,
      renderProfile,
    });
    const { error: uploadError } = await client.storage
      .from(STORAGE_BUCKET)
      .upload(storagePath, rendered.bytes, {
        contentType: 'application/pdf',
        upsert: true,
      });
    if (uploadError) {
      throw new Error(`render_upload_failed:${uploadError.message}`);
    }

    const renderedAt = new Date().toISOString();
    const { error: assetError } = await client
      .from('question_render_assets')
      .upsert(
        {
          academy_id: job.academy_id,
          crop_id: job.crop_id,
          pb_question_id: question.id,
          render_profile: renderProfile,
          content_hash: contentHash,
          renderer_version: rendered.rendererVersion,
          cache_key: cacheKey,
          storage_bucket: STORAGE_BUCKET,
          storage_path: storagePath,
          page_count: rendered.pageCount,
          rendered_at: renderedAt,
          render_error: '',
        },
        { onConflict: 'cache_key' },
      );
    if (assetError) throw new Error(`asset_upsert_failed:${assetError.message}`);
  } catch (error) {
    await client
      .from('question_render_assets')
      .upsert(
        {
          academy_id: job.academy_id,
          crop_id: job.crop_id,
          pb_question_id: question.id,
          render_profile: renderProfile,
          content_hash: contentHash,
          renderer_version: SINGLE_QUESTION_RENDERER_VERSION,
          cache_key: cacheKey,
          storage_bucket: STORAGE_BUCKET,
          storage_path: storagePath,
          page_count: 0,
          rendered_at: null,
          render_error: String(error?.message || error).slice(0, 4000),
        },
        { onConflict: 'cache_key' },
      );
    throw error;
  }

  await completeJob(client, job, {
    pb_question_id: question.id,
    cache_key: cacheKey,
  });
  return { cached: false, cacheKey };
}

async function processBatch(client = supabase) {
  if (!client) throw new Error('supabase_client_missing');
  await reclaimStaleJobs(client);
  const jobs = await claimJobs(client);
  const summary = { claimed: jobs.length, completed: 0, failed: 0 };
  for (const job of jobs) {
    try {
      await processJob(client, job);
      summary.completed += 1;
    } catch (error) {
      summary.failed += 1;
      console.error(
        '[question-render-worker] job_failed',
        job.id,
        String(error?.message || error),
      );
      await failJob(client, job, error);
    }
  }
  return summary;
}

async function main() {
  if (!supabase) {
    throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
  }
  console.log(
    '[question-render-worker] start',
    JSON.stringify({
      worker: WORKER_NAME,
      batchSize: BATCH_SIZE,
      intervalMs: INTERVAL_MS,
      staleMs: STALE_MS,
      rendererVersion: SINGLE_QUESTION_RENDERER_VERSION,
    }),
  );
  do {
    const summary = await processBatch();
    if (summary.claimed > 0) {
      console.log('[question-render-worker] batch', JSON.stringify(summary));
    }
    if (!PROCESS_ONCE) await sleep(INTERVAL_MS);
  } while (!PROCESS_ONCE);
}

export {
  canonicalize,
  hashQuestionContent,
  claimJobs,
  reclaimStaleJobs,
  processJob,
  processBatch,
};

if (IS_DIRECT_RUN) {
  main().catch((error) => {
    console.error('[question-render-worker] fatal', error);
    process.exit(1);
  });
}
