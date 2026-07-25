// textbook_extract_coverage 뷰 검증 + 백필 결과 확인 (읽기 전용).
//
// 사용: node scripts/diag_coverage_view.mjs
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const url = String(process.env.SUPABASE_URL || '').trim();
const serviceKey = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
const supabase = createClient(url, serviceKey, {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function selectAll(table, columns, configure) {
  const rows = [];
  for (let from = 0; ; from += 1000) {
    let query = supabase.from(table).select(columns).range(from, from + 999);
    query = configure ? configure(query) : query;
    const { data, error } = await query;
    if (error) throw new Error(`${table}_select_failed:${error.message}`);
    const batch = data ?? [];
    rows.push(...batch);
    if (batch.length < 1000) return rows;
  }
}

const backfilled = await selectAll('textbook_crop_question_links', 'crop_id', (q) =>
  q.eq('source', 'coverage_backfill'),
);
console.log(`coverage_backfill 로 새로 연결된 링크: ${backfilled.length}건\n`);

const books = await selectAll('resource_files', 'id,name');
const bookName = new Map(books.map((b) => [String(b.id), String(b.name ?? '')]));

const coverage = await selectAll(
  'textbook_extract_coverage',
  'book_id,grade_label,big_order,mid_order,sub_key,crop_count,mapped_count,unmapped_count,coverage_ratio,unmapped_pages,run_count,last_status',
);
console.log(`뷰 행 수: ${coverage.length}\n`);

const byBook = new Map();
for (const row of coverage) {
  const name = bookName.get(String(row.book_id)) || String(row.book_id);
  if (!byBook.has(name)) byBook.set(name, { crops: 0, mapped: 0, gaps: 0 });
  const b = byBook.get(name);
  b.crops += Number(row.crop_count);
  b.mapped += Number(row.mapped_count);
  if (Number(row.unmapped_count) > 0) b.gaps += 1;
}

console.log('교재'.padEnd(14), 'crop'.padStart(7), '매핑'.padStart(7), '커버'.padStart(6), '공백스코프'.padStart(10));
for (const [name, b] of [...byBook.entries()].sort((a, c) => c[1].crops - a[1].crops)) {
  console.log(
    name.slice(0, 12).padEnd(14),
    String(b.crops).padStart(7),
    String(b.mapped).padStart(7),
    `${Math.round((b.mapped / b.crops) * 100)}%`.padStart(6),
    String(b.gaps).padStart(10),
  );
}

console.log('\n=== 공백이 가장 큰 스코프 8개 (재추출 페이지 포함) ===');
const worst = coverage
  .filter((r) => Number(r.unmapped_count) > 0)
  .sort((a, b) => Number(b.unmapped_count) - Number(a.unmapped_count))
  .slice(0, 8);
for (const r of worst) {
  const pages = (r.unmapped_pages ?? []).slice(0, 14).join(', ');
  console.log(
    `${(bookName.get(String(r.book_id)) || '?').padEnd(6)} ${String(r.grade_label).padEnd(8)} 대${r.big_order}-중${r.mid_order}-${r.sub_key}  누락 ${String(r.unmapped_count).padStart(3)}  런 ${r.run_count}(${r.last_status ?? '없음'})`,
  );
  console.log(`   재추출 페이지: ${pages}`);
}
