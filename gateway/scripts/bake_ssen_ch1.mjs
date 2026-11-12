import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import { renderSingleQuestionPdf } from '../src/problem_bank_export_worker.js';
import { hashQuestionContent } from '../src/question_render_cache_key.js';
import { resolveQuestion } from '../src/problem_bank_question_render_worker.js';

const BOOK_ID = 'c3ae29ad-4d99-4078-8381-00357074d151';
const ACADEMY_ID = '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677';
const GRADE = '1-1';
const BIG_ORDER = 1;
const PROFILE = 'student-single-v1';
const VERSION = 'pb_render_v4_colontext_12:student-single-v5';
const CONCURRENCY = 2;

const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: crops, error } = await supa
  .from('textbook_problem_crops')
  .select('id,pb_question_uid,problem_number,is_set_header')
  .eq('academy_id', ACADEMY_ID)
  .eq('book_id', BOOK_ID)
  .eq('grade_label', GRADE)
  .eq('big_order', BIG_ORDER)
  .eq('is_set_header', false)
  .not('pb_question_uid', 'is', null)
  .order('raw_page', { ascending: true })
  .order('problem_number', { ascending: true });
if (error) throw new Error(error.message);
const all = crops || [];
const ready = new Set();
for (let i = 0; i < all.length; i += 80) {
  const slice = all.slice(i, i + 80).map((row) => row.id);
  const { data, error: assetError } = await supa
    .from('question_render_assets')
    .select('crop_id,render_error,rendered_at')
    .eq('renderer_version', VERSION)
    .in('crop_id', slice);
  if (assetError) throw new Error(assetError.message);
  for (const row of data || []) {
    if (row.rendered_at && !row.render_error) ready.add(row.crop_id);
  }
}
const queue = all.filter((row) => !ready.has(row.id));
console.log(`renderable ${all.length} already ${ready.size} remaining ${queue.length}`);

let cursor = 0;
let ok = 0;
let failed = 0;

async function one(crop) {
  const job = {
    academy_id: ACADEMY_ID,
    crop_id: crop.id,
    pb_question_id: null,
  };
  const question = await resolveQuestion(supa, job);
  const rendered = await renderSingleQuestionPdf({
    academyId: ACADEMY_ID,
    question,
    renderProfile: PROFILE,
  });
  const { contentHash, cacheKey } = hashQuestionContent(
    question,
    PROFILE,
    rendered.rendererVersion,
    `${ACADEMY_ID}:${crop.id}`,
  );
  const storagePath = `${ACADEMY_ID}/${cacheKey}.pdf`;
  const { error: uploadError } = await supa.storage
    .from('question-renders')
    .upload(storagePath, rendered.bytes, {
      contentType: 'application/pdf',
      upsert: true,
    });
  if (uploadError) throw new Error(uploadError.message);
  const { error: assetError } = await supa.from('question_render_assets').upsert(
    {
      academy_id: ACADEMY_ID,
      crop_id: crop.id,
      pb_question_id: question.id,
      render_profile: PROFILE,
      content_hash: contentHash,
      renderer_version: rendered.rendererVersion,
      cache_key: cacheKey,
      storage_bucket: 'question-renders',
      storage_path: storagePath,
      page_count: rendered.pageCount,
      rendered_at: new Date().toISOString(),
      render_error: '',
    },
    { onConflict: 'cache_key' },
  );
  if (assetError) throw new Error(assetError.message);
  return crop.problem_number;
}

async function worker(name) {
  for (;;) {
    const index = cursor;
    cursor += 1;
    if (index >= queue.length) return;
    const crop = queue[index];
    try {
      const number = await one(crop);
      ok += 1;
      console.log(`[${name}] ${ok + failed}/${queue.length} ok ${number}`);
    } catch (err) {
      failed += 1;
      console.error(
        `[${name}] ${ok + failed}/${queue.length} fail ${crop.problem_number} ${crop.id} ${err?.message || err}`,
      );
    }
  }
}

await Promise.all(
  Array.from({ length: CONCURRENCY }, (_, i) => worker(i + 1)),
);
console.log(JSON.stringify({ ok, failed, total: queue.length }));
if (failed > 0) process.exit(1);
