// 최근 추출 실패의 시점·원인 확인 (읽기 전용).
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: jobs, error } = await supabase
  .from('pb_extract_jobs')
  .select('id,status,created_at,updated_at,error_message')
  .order('updated_at', { ascending: false })
  .limit(60);
if (error) throw new Error(`jobs_select_failed:${error.message}`);

console.log('=== 최근 처리된 잡 60건 (updated_at 내림차순) ===');
for (const job of jobs ?? []) {
  const reason = String(job.error_message ?? '')
    .replace(/\s+/g, ' ')
    .slice(0, 90);
  console.log(
    `${String(job.updated_at).slice(0, 19)}  ${job.status.padEnd(16)} ${reason}`,
  );
}

const tally = new Map();
for (const job of jobs ?? []) {
  tally.set(job.status, (tally.get(job.status) ?? 0) + 1);
}
console.log('\n=== 상태 분포 (최근 60건) ===');
for (const [status, count] of [...tally.entries()].sort()) {
  console.log(`  ${status.padEnd(18)} ${count}`);
}
