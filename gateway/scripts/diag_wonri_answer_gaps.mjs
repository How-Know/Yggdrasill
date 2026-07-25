// 개념원리 문항 중 정답이 비어 있는 것을 카테고리·소단원별로 센다 (읽기 전용).
//
// 정답 동기화가 (대단원, 중단원, 카테고리) 당 문서 하나만 갱신하고 있었다.
// 소단원별로 문서가 여러 개인 카테고리에서는 첫 문서만 정답이 채워지고
// 나머지는 비었을 것이다. 그 흔적을 확인한다.
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
console.log(`개념원리 추출 문서 ${documents.length}건`);

const scopeByDocument = new Map();
for (const document of documents) {
  const scope = document.meta?.textbook_scope ?? {};
  scopeByDocument.set(document.id, {
    grade: String(scope.grade_label ?? ''),
    big: scope.big_order,
    mid: scope.mid_order,
    subKey: String(scope.sub_key ?? ''),
    subIndex: Number(scope.sub_index ?? 0),
  });
}

const ids = [...scopeByDocument.keys()];
const questions = [];
for (let i = 0; i < ids.length; i += 60) {
  const batch = ids.slice(i, i + 60);
  const rows = await selectAll(
    'pb_questions',
    'id,document_id,objective_answer_key,subjective_answer',
    (query) => query.in('document_id', batch),
  );
  questions.push(...rows);
}
console.log(`개념원리 문항 ${questions.length}건`);

const hasAnswer = (question) => {
  const objective = String(question.objective_answer_key ?? '').trim();
  const subjective = String(question.subjective_answer ?? '').trim();
  return objective.length > 0 || subjective.length > 0;
};

// 같은 (대단원, 중단원, 카테고리) 에 문서가 여러 개인지에 따라 나눠 본다.
const documentsByScope = new Map();
for (const [documentId, scope] of scopeByDocument) {
  const key = `${scope.grade}|${scope.big}|${scope.mid}|${scope.subKey}`;
  if (!documentsByScope.has(key)) documentsByScope.set(key, []);
  documentsByScope.get(key).push(documentId);
}

const tally = new Map();
for (const question of questions) {
  const scope = scopeByDocument.get(question.document_id);
  if (!scope) continue;
  const scopeKey = `${scope.grade}|${scope.big}|${scope.mid}|${scope.subKey}`;
  const siblings = documentsByScope.get(scopeKey) ?? [];
  const multi = siblings.length > 1;
  // 그 스코프에서 가장 먼저 만들어진 문서(=예전 로직이 유일하게 갱신했을 문서)인지.
  const isFirst = siblings[0] === question.document_id;
  const bucket = `${scope.subKey} · ${multi ? (isFirst ? '문서 여러개/첫문서' : '문서 여러개/나머지') : '문서 1개'}`;
  const prev = tally.get(bucket) ?? { total: 0, missing: 0 };
  prev.total += 1;
  if (!hasAnswer(question)) prev.missing += 1;
  tally.set(bucket, prev);
}

console.log('\n카테고리 · 문서 상황            문항    정답없음   비율');
for (const [bucket, value] of [...tally.entries()].sort()) {
  const pct = value.total ? Math.round((value.missing / value.total) * 100) : 0;
  console.log(
    `${bucket.padEnd(30)} ${String(value.total).padStart(5)} ${String(value.missing).padStart(9)} ${String(pct).padStart(5)}%`,
  );
}
