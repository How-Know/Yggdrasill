// 대기 중인 비복구 추출 잡의 scope 를 그대로 찍는다 (읽기 전용).
// 소단원별로 sub_index 가 갈렸는지(=새 매니저 빌드로 만든 런인지) 확인용.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: jobs, error } = await supabase
  .from('pb_extract_jobs')
  .select('id,document_id,status,created_at')
  .in('status', ['queued', 'extracting'])
  .order('created_at', { ascending: true });
if (error) throw new Error(`jobs_select_failed:${error.message}`);

const ids = [...new Set((jobs ?? []).map((job) => job.document_id))];
const documents = new Map();
for (let i = 0; i < ids.length; i += 150) {
  const { data, error: documentError } = await supabase
    .from('pb_documents')
    .select('id,meta')
    .in('id', ids.slice(i, i + 150));
  if (documentError) throw new Error(`documents_failed:${documentError.message}`);
  for (const row of data ?? []) documents.set(row.id, row);
}

for (const job of jobs ?? []) {
  const document = documents.get(job.document_id);
  if (document?.meta?.created_by_script) continue;
  const scope = document?.meta?.textbook_scope ?? {};
  console.log(
    [
      job.status.padEnd(11),
      String(scope.grade_label ?? '').padEnd(10),
      `big${scope.big_order}/mid${scope.mid_order}`.padEnd(12),
      `${scope.sub_key}#${scope.sub_index}`.padEnd(6),
      `p${scope.raw_page_from ?? '?'}-${scope.raw_page_to ?? '?'}`.padEnd(12),
      String(scope.mid_name ?? ''),
    ].join(' '),
  );
}
