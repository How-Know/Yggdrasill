// 실패한 추출 런의 오류 메시지를 본다 (읽기 전용).
//
// 사용: node scripts/diag_failed_runs.mjs
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: runs, error } = await supabase
  .from('textbook_pb_extract_runs')
  .select(
    'grade_label,big_order,mid_order,sub_key,sub_index,status,error_code,' +
      'error_message,raw_page_from,raw_page_to,extract_job_id,updated_at',
  )
  .in('status', ['failed', 'cancelled'])
  .order('updated_at', { ascending: false });
if (error) throw new Error(`runs_select_failed:${error.message}`);

console.log(`실패·취소된 런 ${(runs ?? []).length}건`);
for (const run of runs ?? []) {
  console.log(
    `\n${run.grade_label} 대${run.big_order}-중${run.mid_order}-${run.sub_key}#${run.sub_index} ` +
      `p${run.raw_page_from ?? '?'}-${run.raw_page_to ?? '?'} [${run.status}] ${run.updated_at?.slice(0, 16) ?? ''}`,
  );
  if (run.error_code) console.log(`  코드: ${run.error_code}`);
  if (run.error_message) {
    console.log(`  내용: ${String(run.error_message).slice(0, 400)}`);
  }
  if (run.extract_job_id) {
    const { data: job } = await supabase
      .from('pb_extract_jobs')
      .select('status,error_code,error_message')
      .eq('id', run.extract_job_id)
      .maybeSingle();
    if (job) {
      console.log(`  잡 상태: ${job.status} ${job.error_code ?? ''}`);
      if (job.error_message) {
        console.log(`  잡 오류: ${String(job.error_message).slice(0, 400)}`);
      }
    }
  }
}
