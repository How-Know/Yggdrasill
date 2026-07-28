// 실패한 교재 추출 런을 같은 문서·잡으로 다시 큐에 넣는다.
//
// crop 은 이미 저장돼 있으므로 새 문서를 만들 필요가 없다. 잡을 queued 로
// 되돌리면 워커가 같은 페이지 범위를 다시 훑는다.
//
// 사용:
//   node scripts/requeue_failed_textbook_extract_runs.mjs --grade 1-1
//   node scripts/requeue_failed_textbook_extract_runs.mjs --grade 1-1 --apply
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const args = process.argv.slice(2);
const flag = (name) => {
  const at = args.indexOf(name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : '';
};
const apply = args.includes('--apply');
const gradeLabel = flag('--grade');
const onlyError = flag('--error');
const onlyStatus = flag('--status') || 'failed';
const onlyBook = flag('--book');
const onlySubKey = flag('--sub');
const onlyBig = flag('--big');
const onlyMid = flag('--mid');
const onlySubIndex = flag('--sub-index');
const onlyFrom = flag('--from');
const onlyTo = flag('--to');

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

let query = supabase
  .from('textbook_pb_extract_runs')
  .select(
    'id,book_id,grade_label,big_order,mid_order,sub_key,sub_index,raw_page_from,' +
      'raw_page_to,pb_document_id,extract_job_id,status,error_message',
  )
  .eq('status', onlyStatus);
if (gradeLabel) query = query.eq('grade_label', gradeLabel);
if (onlyBook) query = query.eq('book_id', onlyBook);
if (onlySubKey) query = query.eq('sub_key', onlySubKey);
if (onlyBig) query = query.eq('big_order', Number(onlyBig));
if (onlyMid) query = query.eq('mid_order', Number(onlyMid));
if (onlySubIndex) query = query.eq('sub_index', Number(onlySubIndex));
if (onlyFrom) query = query.eq('raw_page_from', Number(onlyFrom));
if (onlyTo) query = query.eq('raw_page_to', Number(onlyTo));
const { data: runs, error } = await query;
if (error) throw new Error(`runs_select_failed:${error.message}`);

const targets = (runs ?? []).filter((run) => {
  if (!run.extract_job_id || !run.pb_document_id) return false;
  if (!onlyError) return true;
  return String(run.error_message || '').includes(onlyError);
});

console.log(`다시 큐에 넣을 런 ${targets.length}건`);
for (const run of targets) {
  console.log(
    `  ${run.grade_label} 대${run.big_order}-중${run.mid_order}-${run.sub_key}#${run.sub_index} ` +
      `p${run.raw_page_from}-${run.raw_page_to} · ${String(run.error_message || '').slice(0, 50)}`,
  );
}
if (!apply) {
  console.log('\n미리보기입니다. 실제로 넣으려면 --apply 를 붙이세요.');
  process.exit(0);
}

const nowIso = new Date().toISOString();
let done = 0;
for (const run of targets) {
  const { error: jobErr } = await supabase
    .from('pb_extract_jobs')
    .update({
      status: 'queued',
      retry_count: 0,
      started_at: null,
      finished_at: null,
      error_code: '',
      error_message: '',
      updated_at: nowIso,
    })
    .eq('id', run.extract_job_id);
  if (jobErr) throw new Error(`job_update_failed:${jobErr.message}`);

  const { error: docErr } = await supabase
    .from('pb_documents')
    .update({ status: 'extract_queued' })
    .eq('id', run.pb_document_id);
  if (docErr) throw new Error(`document_update_failed:${docErr.message}`);

  const { error: runErr } = await supabase
    .from('textbook_pb_extract_runs')
    .update({
      status: 'queued',
      error_code: '',
      error_message: '',
      updated_at: nowIso,
    })
    .eq('id', run.id);
  if (runErr) throw new Error(`run_update_failed:${runErr.message}`);
  done += 1;
}

console.log(`\n${done}건을 큐에 넣었습니다. 추출 워커가 순차 처리합니다.`);
