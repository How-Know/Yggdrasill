// 복구용 추출 잡을 큐 뒤로 미룬다.
//
// 추출 워커는 created_at 오름차순 FIFO 로만 잡을 집는다(우선순위 컬럼이 없다).
// 누락 복구 런을 한꺼번에 넣으면 사람이 지금 작업하던 교재의 본문 추출이
// 그 뒤로 밀린다. 대기 중인 복구 잡의 created_at 을 일반 잡 뒤로 옮겨,
// 사람 작업이 먼저 끝나게 한다. (created_at 은 이 잡들에서 큐 순서로만
// 쓰이고, 생성 출처는 pb_documents.meta 에 남아 있다.)
//
// 사용: node scripts/defer_recovery_extract_jobs.mjs [--apply]
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const apply = process.argv.includes('--apply');
const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: jobs, error } = await supabase
  .from('pb_extract_jobs')
  .select('id,document_id,created_at')
  .eq('status', 'queued')
  .order('created_at', { ascending: true });
if (error) throw new Error(`jobs_select_failed:${error.message}`);

const ids = [...new Set((jobs ?? []).map((job) => job.document_id))];
const recoveryDocumentIds = new Set();
for (let i = 0; i < ids.length; i += 150) {
  const { data, error: documentError } = await supabase
    .from('pb_documents')
    .select('id,meta')
    .in('id', ids.slice(i, i + 150));
  if (documentError) throw new Error(`documents_failed:${documentError.message}`);
  for (const row of data ?? []) {
    if (row.meta?.created_by_script === 'queue_missing_textbook_extract_runs') {
      recoveryDocumentIds.add(row.id);
    }
  }
}

const recovery = (jobs ?? []).filter((job) => recoveryDocumentIds.has(job.document_id));
const others = (jobs ?? []).filter((job) => !recoveryDocumentIds.has(job.document_id));
if (recovery.length === 0 || others.length === 0) {
  console.log(`복구 대기 ${recovery.length}건 · 일반 대기 ${others.length}건 — 조정할 것이 없습니다.`);
  process.exit(0);
}

const latestOther = others.reduce(
  (max, job) => (job.created_at > max ? job.created_at : max),
  others[0].created_at,
);
const base = new Date(latestOther).getTime() + 60_000;

console.log(
  `복구 대기 ${recovery.length}건을 일반 대기 ${others.length}건 뒤로 미룹니다.`,
);
console.log(`  기준 시각: ${new Date(base).toISOString()} 부터 1초 간격`);
if (!apply) {
  console.log('\n미리보기입니다. 실제로 적용하려면 --apply 를 붙이세요.');
  process.exit(0);
}

let moved = 0;
for (const [index, job] of recovery.entries()) {
  const { error: updateError } = await supabase
    .from('pb_extract_jobs')
    .update({ created_at: new Date(base + index * 1000).toISOString() })
    .eq('id', job.id)
    .eq('status', 'queued');
  if (updateError) throw new Error(`job_update_failed:${updateError.message}`);
  moved += 1;
}
console.log(`\n${moved}건을 큐 뒤로 옮겼습니다.`);
