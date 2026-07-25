// 런 기록에 연결되지 않은 추출 문서를 센다 (읽기 전용).
//
// 정답 동기화는 런 행을 통해 문서를 찾는다. 같은 키의 런이 덮어써지면서
// 문서만 남고 런 연결이 끊긴 것이 있으면, 그 문서의 문항은 정답 동기화의
// 사각지대가 된다.
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

async function selectAll(table, columns, configure) {
  const rows = [];
  for (let from = 0; ; from += 1000) {
    let query = supabase.from(table).select(columns).range(from, from + 999);
    query = configure ? configure(query) : query;
    const { data, error } = await query;
    if (error) throw new Error(`${table}_select_failed:${error.message}`);
    rows.push(...(data ?? []));
    if ((data ?? []).length < 1000) return rows;
  }
}

const documents = await selectAll('pb_documents', 'id,meta', (query) =>
  query.eq('meta->textbook_scope->>series', 'wonri'),
);
const runs = await selectAll('textbook_pb_extract_runs', 'pb_document_id');
const linkedDocumentIds = new Set(
  runs.map((run) => String(run.pb_document_id ?? '').trim()).filter(Boolean),
);

const orphans = documents.filter((document) => !linkedDocumentIds.has(document.id));
console.log(
  `개념원리 추출 문서 ${documents.length}건 중 런 연결 없음 ${orphans.length}건`,
);

const orphanIds = orphans.map((document) => document.id);
let orphanQuestions = 0;
let orphanMissingAnswers = 0;
for (let i = 0; i < orphanIds.length; i += 60) {
  const rows = await selectAll(
    'pb_questions',
    'id,objective_answer_key,subjective_answer',
    (query) => query.in('document_id', orphanIds.slice(i, i + 60)),
  );
  orphanQuestions += rows.length;
  for (const row of rows) {
    const objective = String(row.objective_answer_key ?? '').trim();
    const subjective = String(row.subjective_answer ?? '').trim();
    if (!objective && !subjective) orphanMissingAnswers += 1;
  }
}
console.log(
  `연결 끊긴 문서의 문항 ${orphanQuestions}건 · 그중 정답 없음 ${orphanMissingAnswers}건`,
);

const byScope = new Map();
for (const document of orphans) {
  const scope = document.meta?.textbook_scope ?? {};
  const key = `${scope.grade_label ?? '?'} · ${scope.sub_key ?? '?'}`;
  byScope.set(key, (byScope.get(key) ?? 0) + 1);
}
if (byScope.size > 0) {
  console.log('\n연결 끊긴 문서 분포');
  for (const [key, count] of [...byScope.entries()].sort()) {
    console.log(`  ${key.padEnd(26)} ${count}건`);
  }
}
