// 저장된 크롭의 좌표(bbox / item_region)를 지면 단위로 찍어 본다 (읽기 전용).
// 사용: node scripts/diag_crop_regions.mjs <book_id> <raw_page>
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const bookId = String(process.argv[2] || '').trim();
const rawPage = Number(process.argv[3]);
if (!bookId || !Number.isFinite(rawPage)) {
  throw new Error('사용: node scripts/diag_crop_regions.mjs <book_id> <raw_page>');
}

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data, error } = await supabase
  .from('textbook_problem_crops')
  .select(
    'sub_key,sub_index,raw_page,problem_number,section,bbox_1k,item_region_1k,updated_at',
  )
  .eq('book_id', bookId)
  .eq('raw_page', rawPage)
  .order('problem_number');
if (error) throw new Error(error.message);

for (const row of data ?? []) {
  console.log(
    `${row.sub_key}#${row.sub_index} ${row.problem_number} (${row.section}) ` +
      `bbox=${JSON.stringify(row.bbox_1k)} region=${JSON.stringify(row.item_region_1k)} ` +
      `updated=${row.updated_at}`,
  );
}
console.log(`총 ${(data ?? []).length}건`);
