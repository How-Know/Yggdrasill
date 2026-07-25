// 추출 잡 큐 전경 (읽기 전용).
//
// 복구용으로 넣은 런이 진행 중이던 작업을 뒤로 밀지 않았는지, 그리고 끝난
// 런들이 실제로 crop 에 연결됐는지 한눈에 본다.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: jobs, error: jobError } = await supabase
  .from('pb_extract_jobs')
  .select('id,document_id,status,source_version,created_at,error_message')
  .in('status', ['queued', 'extracting'])
  .order('created_at', { ascending: true });
if (jobError) throw new Error(`jobs_select_failed:${jobError.message}`);

const documentIds = [...new Set((jobs ?? []).map((job) => job.document_id))];
const documents = new Map();
for (let i = 0; i < documentIds.length; i += 150) {
  const { data, error } = await supabase
    .from('pb_documents')
    .select('id,source_filename,meta')
    .in('id', documentIds.slice(i, i + 150));
  if (error) throw new Error(`documents_select_failed:${error.message}`);
  for (const row of data ?? []) documents.set(row.id, row);
}

const isRecovery = (documentId) =>
  documents.get(documentId)?.meta?.created_by_script ===
  'queue_missing_textbook_extract_runs';

console.log('=== 대기·진행·실패 잡 (오래된 순 = 처리 순서) ===');
let position = 0;
for (const job of jobs ?? []) {
  position += 1;
  const document = documents.get(job.document_id);
  const tag = isRecovery(job.document_id) ? '[복구]' : '[일반]';
  console.log(
    `${String(position).padStart(3)}. ${job.status.padEnd(11)} ${tag} ${String(document?.source_filename ?? job.document_id).slice(0, 72)}`,
  );
  if (job.error_message) {
    console.log(`     ↳ ${String(job.error_message).slice(0, 200)}`);
  }
}

const recoveryPending = (jobs ?? []).filter((job) => isRecovery(job.document_id));
const otherPending = (jobs ?? []).filter((job) => !isRecovery(job.document_id));
console.log(
  `\n복구 런 대기 ${recoveryPending.length}건 · 그 외 대기 ${otherPending.length}건`,
);

// ---- 끝난 복구 런의 연결률 ----
const { data: recoveryDocs, error: recoveryError } = await supabase
  .from('pb_documents')
  .select('id')
  .eq('meta->>created_by_script', 'queue_missing_textbook_extract_runs');
if (recoveryError) throw new Error(`recovery_docs_failed:${recoveryError.message}`);
const recoveryIds = (recoveryDocs ?? []).map((row) => row.id);

const questions = [];
for (let i = 0; i < recoveryIds.length; i += 150) {
  const { data, error } = await supabase
    .from('pb_questions')
    .select('id,document_id')
    .in('document_id', recoveryIds.slice(i, i + 150));
  if (error) throw new Error(`questions_select_failed:${error.message}`);
  questions.push(...(data ?? []));
}
const linked = new Set();
for (let i = 0; i < questions.length; i += 150) {
  const { data, error } = await supabase
    .from('textbook_crop_question_links')
    .select('pb_question_id')
    .in('pb_question_id', questions.slice(i, i + 150).map((q) => q.id));
  if (error) throw new Error(`links_select_failed:${error.message}`);
  for (const row of data ?? []) linked.add(row.pb_question_id);
}
const linkedCount = questions.filter((q) => linked.has(q.id)).length;
console.log(
  `복구 런 산출 문항 ${questions.length}건 중 crop 연결 ${linkedCount}건` +
    (questions.length ? ` (${Math.round((linkedCount / questions.length) * 100)}%)` : ''),
);
