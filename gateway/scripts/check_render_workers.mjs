import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const since = new Date(Date.now() - 6 * 60 * 60 * 1000).toISOString();
const { data, error } = await supa
  .from('question_render_jobs')
  .select('status,worker_name,updated_at,error')
  .gte('updated_at', since)
  .order('updated_at', { ascending: false })
  .limit(20);
if (error) {
  console.error(error.message);
  process.exit(1);
}
const counts = {};
for (const row of data || []) {
  const key = `${row.status}|${row.worker_name || '-'}`;
  counts[key] = (counts[key] || 0) + 1;
}
console.log(JSON.stringify({ since, recent: data?.length || 0, counts }, null, 2));
