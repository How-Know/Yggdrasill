import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
const supa = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_SERVICE_ROLE_KEY,
  { auth: { persistSession: false } },
);
const { data, error } = await supa
  .from('resource_file_links')
  .select('id, academy_id, file_id, grade, storage_key, migration_status')
  .in('id', [1040, 1041, 1186, 1022]);
if (error) throw error;
for (const r of data) {
  console.log(JSON.stringify(r));
}
process.exit(0);
