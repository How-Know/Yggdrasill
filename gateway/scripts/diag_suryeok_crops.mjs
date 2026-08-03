// 수력충전 교재의 저장된 크롭을 스코프별로 집계한다 (읽기 전용, 일회성 점검).
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const bookId = String(process.argv[2] || '').trim();
if (!bookId) throw new Error('book_id 가 필요하다');

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data, error } = await supabase
  .from('textbook_problem_crops')
  .select(
    'grade_label,big_order,mid_order,sub_key,sub_index,raw_page,problem_number,' +
      'section,item_name,label,content_group_label,content_group_title',
  )
  .eq('book_id', bookId)
  .order('big_order')
  .order('mid_order')
  .order('sub_key')
  .order('sub_index')
  .order('raw_page');
if (error) throw new Error(error.message);

const groups = new Map();
for (const c of data ?? []) {
  const key = `${c.grade_label} B${c.big_order}/M${c.mid_order} ${c.sub_key}#${c.sub_index}`;
  const bucket = groups.get(key) ?? [];
  bucket.push(c);
  groups.set(key, bucket);
}
for (const [key, rows] of groups) {
  const pages = rows.map((r) => r.raw_page);
  const noGroup = rows.filter(
    (r) => r.section === 'type_problem' && !String(r.content_group_title || '').trim(),
  ).length;
  const conceptWithGroup = rows.filter(
    (r) => r.section === 'concept_check' && String(r.content_group_title || '').trim(),
  ).length;
  console.log(
    `${key} · ${rows.length}건 p${Math.min(...pages)}~${Math.max(...pages)} ` +
      `유형없음=${noGroup} 개념체크에유형=${conceptWithGroup}`,
  );
}
console.log(`총 ${(data ?? []).length}건`);
