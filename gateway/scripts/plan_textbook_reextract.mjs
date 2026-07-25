// 교재 단원(스코프)별 추출 커버리지를 계산해 재추출 작업 목록을 만든다 (읽기 전용).
//
// crop = PDF 에서 검출된 실제 문항, pb_question = HWPX 추출 결과.
// 두 수가 크게 벌어지는 스코프가 재추출 대상이다.
//
// 사용: node scripts/plan_textbook_reextract.mjs --book 개념원리 [--csv out.csv]
import 'dotenv/config';
import { writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

function argValue(flag) {
  const i = process.argv.indexOf(flag);
  return i >= 0 ? String(process.argv[i + 1] || '').trim() : '';
}
const bookArg = argValue('--book');
const csvPath = argValue('--csv');

const url = String(process.env.SUPABASE_URL || '').trim();
const serviceKey = String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
if (!url || !serviceKey) {
  throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
}
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

function scopeKey(bookId, gradeLabel, bigOrder, midOrder, subKey) {
  return [
    String(bookId ?? ''),
    String(gradeLabel ?? ''),
    Number(bigOrder ?? 0),
    Number(midOrder ?? 0),
    String(subKey ?? '').toUpperCase(),
  ].join('|');
}

const books = await selectAll('resource_files', 'id,name');
const bookName = new Map(books.map((b) => [String(b.id), String(b.name ?? '')]));
const targetBookIds = new Set(
  books
    .filter((b) => !bookArg || String(b.name ?? '').includes(bookArg))
    .map((b) => String(b.id)),
);

const crops = await selectAll(
  'textbook_problem_crops',
  'id,book_id,grade_label,big_order,mid_order,sub_key,big_name,mid_name,raw_page,pb_question_uid',
  (q) => q.eq('is_set_header', false),
);
const links = await selectAll('textbook_crop_question_links', 'crop_id');
const linkedCrops = new Set(links.map((r) => String(r.crop_id)));

const questions = await selectAll('pb_questions', 'id,document_id,meta');
const documents = await selectAll('pb_documents', 'id,source_filename');
const docTitle = new Map(
  documents.map((d) => [String(d.id), String(d.source_filename ?? '')]),
);
// 스코프 단위 추출 이력 — 아예 돌지 않은 단원과 실패한 단원을 구분한다.
const runs = await selectAll(
  'textbook_pb_extract_runs',
  'book_id,grade_label,big_order,mid_order,sub_key,status,error_code,error_message',
);
const runByScope = new Map(
  runs.map((r) => [
    scopeKey(r.book_id, r.grade_label, r.big_order, r.mid_order, r.sub_key),
    r,
  ]),
);

const scopeStats = new Map();
function bucket(key) {
  if (!scopeStats.has(key)) {
    scopeStats.set(key, {
      key,
      crops: 0,
      mapped: 0,
      questions: 0,
      pages: [],
      bigName: '',
      midName: '',
      docs: new Set(),
    });
  }
  return scopeStats.get(key);
}

for (const crop of crops) {
  if (!targetBookIds.has(String(crop.book_id))) continue;
  const key = scopeKey(
    crop.book_id,
    crop.grade_label,
    crop.big_order,
    crop.mid_order,
    crop.sub_key,
  );
  const row = bucket(key);
  row.crops += 1;
  if (crop.pb_question_uid || linkedCrops.has(String(crop.id))) row.mapped += 1;
  if (Number.isFinite(Number(crop.raw_page))) row.pages.push(Number(crop.raw_page));
  if (!row.bigName) row.bigName = String(crop.big_name ?? '');
  if (!row.midName) row.midName = String(crop.mid_name ?? '');
}

for (const q of questions) {
  const scope = q?.meta?.textbook_scope;
  if (!scope || !scope.book_id) continue;
  if (!targetBookIds.has(String(scope.book_id))) continue;
  const key = scopeKey(
    scope.book_id,
    scope.grade_label,
    scope.big_order,
    scope.mid_order,
    scope.sub_key,
  );
  if (!scopeStats.has(key)) continue;
  const row = scopeStats.get(key);
  row.questions += 1;
  const title = docTitle.get(String(q.document_id));
  if (title) row.docs.add(title);
}

const rows = [...scopeStats.values()]
  .map((r) => ({
    ...r,
    missing: r.crops - r.mapped,
    coverage: r.crops === 0 ? 1 : r.mapped / r.crops,
    pageFrom: r.pages.length ? Math.min(...r.pages) : 0,
    pageTo: r.pages.length ? Math.max(...r.pages) : 0,
  }))
  .filter((r) => r.missing > 0)
  .sort((a, b) => b.missing - a.missing);

const totalMissing = rows.reduce((a, r) => a + r.missing, 0);
console.log(
  `재추출 대상 스코프 ${rows.length}개, 미매핑 문항 ${totalMissing}건\n`,
);
console.log(
  '학년/과정'.padEnd(12),
  '단원'.padEnd(10),
  'crop'.padStart(5),
  '매핑'.padStart(5),
  '문항'.padStart(5),
  '누락'.padStart(5),
  '커버'.padStart(6),
  '페이지'.padStart(10),
  ' 추출런',
);
console.log('-'.repeat(112));
const runTally = new Map();
for (const r of rows) {
  const unit = (([, , big, mid, sub]) => `대${big}-중${mid}-${sub}`)(
    r.key.split('|'),
  );
  const grade = r.key.split('|')[1];
  const run = runByScope.get(r.key);
  const runLabel = run
    ? `${run.status}${run.error_code ? `(${run.error_code})` : ''}`
    : '실행이력 없음';
  runTally.set(runLabel, (runTally.get(runLabel) ?? 0) + r.missing);
  console.log(
    grade.slice(0, 11).padEnd(12),
    unit.padEnd(10),
    String(r.crops).padStart(5),
    String(r.mapped).padStart(5),
    String(r.questions).padStart(5),
    String(r.missing).padStart(5),
    `${Math.round(r.coverage * 100)}%`.padStart(6),
    `${r.pageFrom}-${r.pageTo}`.padStart(10),
    ` ${runLabel}`,
  );
}

console.log('\n=== 추출런 상태별 누락 문항 수 ===');
for (const [k, v] of [...runTally.entries()].sort((a, b) => b[1] - a[1])) {
  console.log(`${String(v).padStart(5)}건  ${k}`);
}

if (csvPath) {
  const header =
    'book,grade_label,big_order,mid_order,sub_key,big_name,mid_name,crops,mapped,questions,missing,coverage_pct,page_from,page_to,documents\n';
  const body = rows
    .map((r) => {
      const [bookId, grade, big, mid, sub] = r.key.split('|');
      const cells = [
        bookName.get(bookId) || bookId,
        grade,
        big,
        mid,
        sub,
        r.bigName,
        r.midName,
        r.crops,
        r.mapped,
        r.questions,
        r.missing,
        Math.round(r.coverage * 100),
        r.pageFrom,
        r.pageTo,
        [...r.docs].join(' | '),
      ];
      return cells
        .map((c) => `"${String(c).replaceAll('"', '""')}"`)
        .join(',');
    })
    .join('\n');
  writeFileSync(csvPath, header + body + '\n', 'utf8');
  console.log(`\nCSV 저장: ${csvPath}`);
}
