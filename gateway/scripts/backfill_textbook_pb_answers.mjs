// crop ??? ???? ???? ??? (??? ??).
//
// ??: ??? ?????? ??? ??? ??? ??? '??' ?????
// ???, ? ??? ? ?? ??? ?? ???. ??? crop ??? ? ???
// pb_questions ??? ?? ?? ??? ???. ?? ??/??? crop ???
// ??? ??? ??, ???? ???(??? ??)? ???.
//
// ??? ?? ?? ????? ?????(/textbook/answers/sync-pb)? ????.
// ?? ??(??/??/???) ?? ??? ??? ?? ???? ????
// ??? ? ????, ??? ??? ??? ??.
//
// ??:
//   node scripts/backfill_textbook_pb_answers.mjs                 (????)
//   node scripts/backfill_textbook_pb_answers.mjs --apply
//   ... --series wonri --book <book_id> --grade <grade_label> --limit <n>
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const args = process.argv.slice(2);
const flag = (name) => {
  const at = args.indexOf(name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : '';
};
const apply = args.includes('--apply');
const onlySeries = flag('--series');
const onlyBookId = flag('--book');
const onlyGrade = flag('--grade');
const limit = Number.parseInt(flag('--limit') || '0', 10) || 0;

const gatewayUrl = (
  process.env.PB_GATEWAY_URL || 'http://localhost:8787'
).replace(/\/$/, '');
const gatewayApiKey = String(process.env.PB_GATEWAY_API_KEY || '').trim();

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

let bookQuery = supabase
  .from('textbook_metadata')
  .select('academy_id,book_id,grade_label,payload');
if (onlySeries) bookQuery = bookQuery.eq('payload->>series', onlySeries);
const { data: books, error: bookError } = await bookQuery;
if (bookError) throw new Error(`textbook_metadata_failed:${bookError.message}`);

// ??? ?? ?? ??? ??? ?? ???? ???? ???.
const targets = [];
for (const book of books ?? []) {
  if (onlyBookId && book.book_id !== onlyBookId) continue;
  if (onlyGrade && book.grade_label !== onlyGrade) continue;

  // ??? ???? ?? crop ? ?? ??? ??. ?/?? ??? ??
  // ??(????? 1/3)? ???? ?? ????.
  const crops = await selectAll(
    'textbook_problem_crops',
    'id,big_order,mid_order,sub_key',
    (query) =>
      query
        .eq('academy_id', book.academy_id)
        .eq('book_id', book.book_id)
        .eq('grade_label', book.grade_label)
        .eq('is_set_header', false),
  );
  if (crops.length === 0) continue;
  const scopeByCropId = new Map(
    crops.map((crop) => [
      crop.id,
      `${crop.big_order}/${crop.mid_order}/${crop.sub_key}`,
    ]),
  );

  const scopeByQuestionId = new Map();
  const cropIds = crops.map((crop) => crop.id);
  for (let i = 0; i < cropIds.length; i += 120) {
    const { data, error } = await supabase
      .from('textbook_crop_question_links')
      .select('crop_id,pb_question_id')
      .in('crop_id', cropIds.slice(i, i + 120));
    if (error) throw new Error(`links_select_failed:${error.message}`);
    for (const link of data ?? []) {
      const scope = scopeByCropId.get(link.crop_id);
      if (scope) scopeByQuestionId.set(link.pb_question_id, scope);
    }
  }

  const missingByScope = new Map();
  const totalByScope = new Map();
  const questionIds = [...scopeByQuestionId.keys()];
  for (let i = 0; i < questionIds.length; i += 120) {
    const { data, error } = await supabase
      .from('pb_questions')
      .select('id,objective_answer_key,subjective_answer')
      .in('id', questionIds.slice(i, i + 120));
    if (error) throw new Error(`questions_select_failed:${error.message}`);
    for (const row of data ?? []) {
      const scope = scopeByQuestionId.get(row.id);
      if (!scope) continue;
      totalByScope.set(scope, (totalByScope.get(scope) ?? 0) + 1);
      const objective = String(row.objective_answer_key ?? '').trim();
      const subjective = String(row.subjective_answer ?? '').trim();
      if (!objective && !subjective) {
        missingByScope.set(scope, (missingByScope.get(scope) ?? 0) + 1);
      }
    }
  }

  for (const [scope, missing] of missingByScope) {
    if (missing === 0) continue;
    const [bigOrder, midOrder, subKey] = scope.split('/');
    targets.push({
      academyId: book.academy_id,
      bookId: book.book_id,
      gradeLabel: book.grade_label,
      bigOrder: Number(bigOrder),
      midOrder: Number(midOrder),
      subKey,
      missing,
      total: totalByScope.get(scope) ?? 0,
    });
  }
}

targets.sort(
  (a, b) =>
    a.gradeLabel.localeCompare(b.gradeLabel) ||
    a.bigOrder - b.bigOrder ||
    a.midOrder - b.midOrder ||
    a.subKey.localeCompare(b.subKey),
);

const totalMissing = targets.reduce((sum, item) => sum + item.missing, 0);
console.log(
  `??? ? ??? ?? ??? ${targets.length}? · ?? ?? ${totalMissing}?`,
);
const byGrade = new Map();
for (const item of targets) {
  const key = `${item.gradeLabel} · ${item.subKey}`;
  const prev = byGrade.get(key) ?? { scopes: 0, missing: 0 };
  byGrade.set(key, {
    scopes: prev.scopes + 1,
    missing: prev.missing + item.missing,
  });
}
for (const [key, value] of [...byGrade.entries()].sort()) {
  console.log(
    `  ${key.padEnd(26)} ??? ${String(value.scopes).padStart(3)} · ? ?? ${value.missing}`,
  );
}

if (!apply) {
  console.log('\n???????. ??? ????? --apply ? ????.');
  process.exit(0);
}
if (targets.length === 0) process.exit(0);

const applyTargets = limit > 0 ? targets.slice(0, limit) : targets;
console.log(`\n${applyTargets.length}? ???? ?????.`);

let updatedTotal = 0;
let failed = 0;
for (const [index, item] of applyTargets.entries()) {
  const response = await fetch(`${gatewayUrl}/textbook/answers/sync-pb`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(gatewayApiKey ? { 'x-api-key': gatewayApiKey } : {}),
    },
    body: JSON.stringify({
      academy_id: item.academyId,
      book_id: item.bookId,
      grade_label: item.gradeLabel,
      big_order: item.bigOrder,
      mid_order: item.midOrder,
      sub_key: item.subKey,
    }),
  });
  const json = await response.json().catch(() => ({}));
  if (!response.ok || json?.ok !== true) {
    failed += 1;
    console.log(
      `  ?? ${item.gradeLabel} ?${item.bigOrder}-?${item.midOrder}-${item.subKey}: ` +
        `${response.status} ${json?.error ?? ''}`,
    );
    continue;
  }
  const updated = Number(json.updated_questions ?? 0);
  updatedTotal += updated;
  if ((index + 1) % 20 === 0 || index === applyTargets.length - 1) {
    console.log(
      `  ... ${index + 1}/${applyTargets.length} · ?? ?? ${updatedTotal}`,
    );
  }
}

console.log(`\n?? ${updatedTotal}? ?? · ?? ??? ${failed}?`);
