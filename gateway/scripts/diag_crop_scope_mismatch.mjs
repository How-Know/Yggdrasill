// 추출 런의 스코프(sub_key + 페이지 범위)와 실제 crop 이 맞물리는지 본다.
//
// vlm_textbook_crop_scope_empty 는 "런 범위 안에 crop 이 하나도 없다" 는
// 뜻이다. 어디가 어긋났는지 보려면 양쪽을 나란히 찍어 봐야 한다.
//
// 사용: node scripts/diag_crop_scope_mismatch.mjs <grade_label>
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const gradeLabel = String(process.argv[2] || '1-1').trim();

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: runs, error: runErr } = await supabase
  .from('textbook_pb_extract_runs')
  .select(
    'book_id,grade_label,big_order,mid_order,sub_key,sub_index,status,' +
      'raw_page_from,raw_page_to,error_message,updated_at',
  )
  .eq('grade_label', gradeLabel)
  .order('updated_at', { ascending: false })
  .limit(40);
if (runErr) throw new Error(`runs_failed:${runErr.message}`);

console.log(`=== 런 ${(runs ?? []).length}건 (${gradeLabel}) ===`);
for (const r of runs ?? []) {
  console.log(
    `${r.status.padEnd(9)} big=${r.big_order} mid=${r.mid_order} ` +
      `sub=${r.sub_key}#${r.sub_index} pages=${r.raw_page_from}..${r.raw_page_to} ` +
      `${r.error_message ? '· ' + String(r.error_message).slice(0, 60) : ''}`,
  );
}

const bookId = runs?.[0]?.book_id;
if (!bookId) {
  console.log('런이 없어 crop 비교를 생략한다.');
  process.exit(0);
}

const { data: crops, error: cropErr } = await supabase
  .from('textbook_problem_crops')
  .select(
    'big_order,mid_order,sub_key,sub_index,section,raw_page,display_page,' +
      'problem_number,is_set_header',
  )
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .order('raw_page', { ascending: true })
  .limit(2000);
if (cropErr) throw new Error(`crops_failed:${cropErr.message}`);

const groups = new Map();
for (const c of crops ?? []) {
  const key = `big=${c.big_order} mid=${c.mid_order} sub=${c.sub_key}#${c.sub_index}`;
  const g = groups.get(key) ?? {
    count: 0,
    minPage: Infinity,
    maxPage: -Infinity,
    sections: new Set(),
    numbers: [],
  };
  g.count += 1;
  const page = Number(c.raw_page);
  if (Number.isFinite(page)) {
    g.minPage = Math.min(g.minPage, page);
    g.maxPage = Math.max(g.maxPage, page);
  }
  g.sections.add(c.section);
  if (g.numbers.length < 6) g.numbers.push(c.problem_number);
  groups.set(key, g);
}

console.log(`\n=== crop 그룹 ${groups.size}개 (총 ${(crops ?? []).length}건) ===`);
for (const [key, g] of [...groups.entries()].sort()) {
  console.log(
    `${key} · ${g.count}건 · rawPage ${g.minPage}..${g.maxPage} · ` +
      `section=${[...g.sections].join('/')} · 예시 ${g.numbers.join(',')}`,
  );
}
