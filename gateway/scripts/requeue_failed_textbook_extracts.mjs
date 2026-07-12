import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
  process.exit(1);
}
const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// --apply 플래그가 있으면 실제로 재큐잉, 없으면 조회만.
const APPLY = process.argv.includes('--apply');

const { data: runs, error } = await supa
  .from('textbook_pb_extract_runs')
  .select(
    'id,book_id,grade_label,big_order,mid_order,sub_key,sub_index,status,' +
      'error_code,error_message,extract_job_id,pb_document_id,updated_at',
  )
  .eq('status', 'failed')
  .order('updated_at', { ascending: false });
if (error) {
  console.error('query_failed:', error.message || error);
  process.exit(1);
}

console.log(`failed textbook extract runs: ${runs?.length || 0}`);
for (const r of runs || []) {
  console.log(
    `- run=${r.id} doc=${r.pb_document_id} job=${r.extract_job_id} ` +
      `scope=(${r.big_order}/${r.mid_order}/${r.sub_key}#${r.sub_index}) ` +
      `err=${r.error_code || ''} at=${r.updated_at}`,
  );
}

if (!APPLY) {
  console.log('\n(dry-run) 재큐잉하려면 --apply 를 붙여 다시 실행하세요.');
  process.exit(0);
}

let requeued = 0;
for (const r of runs || []) {
  const jobId = String(r.extract_job_id || '').trim();
  const docId = String(r.pb_document_id || '').trim();
  if (!jobId || !docId) {
    console.log(`skip run=${r.id} (missing job/doc)`);
    continue;
  }
  const nowIso = new Date().toISOString();
  const { error: jobErr } = await supa
    .from('pb_extract_jobs')
    .update({
      status: 'queued',
      retry_count: 0,
      worker_name: '',
      started_at: null,
      finished_at: null,
      error_code: '',
      error_message: '',
      updated_at: nowIso,
    })
    .eq('id', jobId);
  if (jobErr) {
    console.log(`job_update_failed run=${r.id}: ${jobErr.message || jobErr}`);
    continue;
  }
  await supa
    .from('pb_documents')
    .update({ status: 'queued', updated_at: nowIso })
    .eq('id', docId);
  await supa
    .from('textbook_pb_extract_runs')
    .update({
      status: 'queued',
      error_code: '',
      error_message: '',
      updated_at: nowIso,
    })
    .eq('id', r.id);
  requeued += 1;
  console.log(`requeued run=${r.id} job=${jobId}`);
}
console.log(`\ndone. requeued=${requeued}`);
