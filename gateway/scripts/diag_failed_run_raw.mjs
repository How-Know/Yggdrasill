// 실패한 런의 오류 메시지를 자르지 않고 전부 파일로 뽑는다 (읽기 전용).
//
// VLM 응답 파싱 실패는 응답 본문을 봐야 원인을 알 수 있다. 콘솔은 인코딩
// 문제로 읽기 어려우니 파일로 떨어뜨린다.
//
// 사용: node scripts/diag_failed_run_raw.mjs
import 'dotenv/config';
import { writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: runs, error } = await supabase
  .from('textbook_pb_extract_runs')
  .select('grade_label,big_order,mid_order,sub_key,sub_index,error_message,extract_job_id')
  .eq('status', 'failed');
if (error) throw new Error(`runs_select_failed:${error.message}`);

const parts = [];
for (const run of runs ?? []) {
  parts.push(
    `=== ${run.grade_label} 대${run.big_order}-중${run.mid_order}-${run.sub_key}#${run.sub_index} ===`,
  );
  parts.push(`run.error_message (${String(run.error_message ?? '').length}자):`);
  parts.push(String(run.error_message ?? ''));
  if (run.extract_job_id) {
    const { data: job } = await supabase
      .from('pb_extract_jobs')
      .select('error_message,result_summary')
      .eq('id', run.extract_job_id)
      .maybeSingle();
    parts.push(`\njob.error_message (${String(job?.error_message ?? '').length}자):`);
    parts.push(String(job?.error_message ?? ''));
    parts.push('\njob.result_summary:');
    parts.push(JSON.stringify(job?.result_summary ?? {}, null, 2));
  }
  parts.push('');
}

const out = 'tmp_failed_run_raw.txt';
writeFileSync(out, parts.join('\n'), 'utf8');
console.log(`wrote ${out} (${parts.join('\n').length} chars)`);
