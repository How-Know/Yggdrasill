// 누락 복구용으로 만든 추출 런의 진행/결과 확인 (읽기 전용).
//
// queue_missing_textbook_extract_runs.mjs 가 만든 문서만 골라, 잡 상태와
// 실제로 crop 이 문항에 연결됐는지까지 본다. "완료" 라고만 보고하고 매핑이
// 비어 있던 예전 실패를 그대로 반복하지 않기 위함이다.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: documents, error: documentError } = await supabase
  .from('pb_documents')
  .select('id,source_filename,status,meta')
  .eq('meta->>created_by_script', 'queue_missing_textbook_extract_runs')
  .order('created_at', { ascending: true });
if (documentError) throw new Error(`pb_documents_select_failed:${documentError.message}`);
if (!documents?.length) {
  console.log('복구용 추출 런이 없습니다.');
  process.exit(0);
}

const { data: jobs, error: jobError } = await supabase
  .from('pb_extract_jobs')
  .select('id,document_id,status,error_message,result_summary')
  .in('document_id', documents.map((row) => row.id));
if (jobError) throw new Error(`pb_extract_jobs_select_failed:${jobError.message}`);
const jobByDocument = new Map((jobs ?? []).map((job) => [job.document_id, job]));

const { data: questions, error: questionError } = await supabase
  .from('pb_questions')
  .select('id,document_id')
  .in('document_id', documents.map((row) => row.id));
if (questionError) throw new Error(`pb_questions_select_failed:${questionError.message}`);
const questionsByDocument = new Map();
for (const question of questions ?? []) {
  const list = questionsByDocument.get(question.document_id) ?? [];
  list.push(question.id);
  questionsByDocument.set(question.document_id, list);
}

const allQuestionIds = (questions ?? []).map((question) => question.id);
const linkedQuestionIds = new Set();
for (let i = 0; i < allQuestionIds.length; i += 150) {
  const { data, error } = await supabase
    .from('textbook_crop_question_links')
    .select('pb_question_id')
    .in('pb_question_id', allQuestionIds.slice(i, i + 150));
  if (error) throw new Error(`links_select_failed:${error.message}`);
  for (const row of data ?? []) linkedQuestionIds.add(row.pb_question_id);
}

const tally = new Map();
for (const document of documents) {
  const job = jobByDocument.get(document.id);
  const status = String(job?.status ?? 'no_job');
  tally.set(status, (tally.get(status) ?? 0) + 1);
  const questionIds = questionsByDocument.get(document.id) ?? [];
  const linked = questionIds.filter((id) => linkedQuestionIds.has(id)).length;
  const scope = document.meta?.textbook_scope ?? {};
  const expected = Number(scope.raw_page_to) - Number(scope.raw_page_from) + 1;
  console.log(
    `${status.padEnd(12)} 문항 ${String(questionIds.length).padStart(3)} · 연결 ${String(linked).padStart(3)} · ${Number.isFinite(expected) ? `${expected}p` : '-'}  ${document.source_filename}`,
  );
  if (job?.error_message) {
    console.log(`             ↳ ${String(job.error_message).slice(0, 220)}`);
  }
}

console.log('\n=== 잡 상태 ===');
for (const [status, count] of [...tally.entries()].sort()) {
  console.log(`  ${status.padEnd(16)} ${count}`);
}
