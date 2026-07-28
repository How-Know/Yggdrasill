// 최근에 저장된 crop 을 sub_key 별로 본다 (읽기 전용).
//
// 저장이 중간에 끊겼는지 보려면 "어느 슬롯까지 updated_at 이 갱신됐는지" 를
// 보면 된다. 앱은 A→B→C… 순서로 슬롯을 하나씩 올린다.
//
// 사용: node scripts/diag_crop_recent_writes.mjs <book_id> <grade_label> [분]
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const [bookId, gradeLabel = '1-1', minutesArg = '90'] = process.argv.slice(2);
if (!bookId) throw new Error('book_id 를 넘겨주세요');
const since = new Date(Date.now() - Number(minutesArg) * 60_000).toISOString();

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data, error } = await supabase
  .from('textbook_problem_crops')
  .select('sub_key,sub_index,raw_page,problem_number,section,updated_at')
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .gte('updated_at', since)
  .order('updated_at', { ascending: true });
if (error) throw new Error(error.message);

const groups = new Map();
for (const row of data ?? []) {
  const key = `${row.sub_key}#${row.sub_index}`;
  const g = groups.get(key) ?? { count: 0, first: row.updated_at, last: row.updated_at, pages: new Set() };
  g.count += 1;
  g.last = row.updated_at;
  g.pages.add(row.raw_page);
  groups.set(key, g);
}

console.log(`최근 ${minutesArg}분 안에 갱신된 crop ${(data ?? []).length}건`);
for (const [key, g] of [...groups.entries()].sort()) {
  const pages = [...g.pages].sort((a, b) => a - b);
  console.log(
    `  ${key} · ${g.count}건 · p${pages[0]}..${pages[pages.length - 1]} · ` +
      `${g.first.slice(11, 19)} ~ ${g.last.slice(11, 19)}`,
  );
}
