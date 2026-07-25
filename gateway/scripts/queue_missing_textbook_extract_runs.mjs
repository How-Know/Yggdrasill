// 문제은행에 매핑되지 않은 교재 crop 을 대상으로 추출 런을 새로 만든다.
//
// 배경: 개념원리는 한 중단원 안에서 확인체크·익히기·연습문제가 소단원마다
// 되풀이되는데, 예전에는 추출 런 키가 (big, mid, sub_key, 0) 하나뿐이었다.
// 그래서 첫 소단원을 돌리고 나면 나머지 소단원은 "이미 처리된 런"으로 걸러져
// 영구 누락됐다. 러너가 이제 런의 페이지 범위로 crop 을 찾으므로, 누락된
// 페이지 블록마다 sub_index 를 새로 부여한 런을 만들면 채울 수 있다.
//
// 사용:
//   node scripts/queue_missing_textbook_extract_runs.mjs              (미리보기)
//   node scripts/queue_missing_textbook_extract_runs.mjs --apply      (실제 생성)
//   ... --book <book_id> --grade <grade_label> --limit <n>
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const PIPELINE_SOURCE_VERSION = 'textbook_pdf_only_v2_answers';
const CATEGORY_BY_SUB_KEY = {
  A: 'concept_drill',
  B: 'type_example',
  C: 'check',
  D: 'exercise',
  E: 'special_lecture',
};
const SHORT_NAME_BY_CATEGORY = {
  concept_drill: '익히기',
  type_example: '필수유형',
  check: '확인체크',
  exercise: '연습문제',
  special_lecture: '특강',
};
// 페이지가 이보다 많이 벌어지면 다른 소단원으로 본다. 개념원리 소단원은
// 연속 페이지를 차지하고, 사이에 개념 설명 지면이 한두 장 낀다.
const PAGE_BLOCK_GAP = 3;

const args = process.argv.slice(2);
const flag = (name) => {
  const at = args.indexOf(name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : '';
};
const apply = args.includes('--apply');
const onlyBookId = flag('--book');
const onlyGrade = flag('--grade');
const limit = Number.parseInt(flag('--limit') || '0', 10) || 0;

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

function chunks(list, size = 150) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

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

/// 연속된 페이지끼리 묶는다. 한 블록이 곧 하나의 추출 런(=잘라낼 PDF 범위).
function splitIntoPageBlocks(crops) {
  const sorted = [...crops].sort((a, b) => Number(a.raw_page) - Number(b.raw_page));
  const blocks = [];
  let current = null;
  for (const crop of sorted) {
    const page = Number(crop.raw_page);
    if (!Number.isFinite(page) || page <= 0) continue;
    if (current && page - current.lastPage <= PAGE_BLOCK_GAP) {
      current.crops.push(crop);
      current.lastPage = page;
      continue;
    }
    current = { crops: [crop], lastPage: page };
    blocks.push(current);
  }
  return blocks.map((block) => block.crops);
}

function pageRange(crops, field) {
  const values = crops
    .map((crop) => Number(crop[field]))
    .filter((value) => Number.isFinite(value) && value > 0);
  if (values.length === 0) return { from: null, to: null };
  return { from: Math.min(...values), to: Math.max(...values) };
}

const { data: books, error: bookError } = await supabase
  .from('textbook_metadata')
  .select('academy_id,book_id,grade_label,payload')
  .eq('payload->>series', 'wonri');
if (bookError) throw new Error(`textbook_metadata_select_failed:${bookError.message}`);

const plan = [];
for (const book of books ?? []) {
  if (onlyBookId && book.book_id !== onlyBookId) continue;
  if (onlyGrade && book.grade_label !== onlyGrade) continue;
  const scope = (query) =>
    query
      .eq('academy_id', book.academy_id)
      .eq('book_id', book.book_id)
      .eq('grade_label', book.grade_label);

  const crops = await selectAll(
    'textbook_problem_crops',
    'id,big_order,mid_order,sub_key,raw_page,display_page,pb_question_uid',
    (query) => scope(query).eq('is_set_header', false),
  );
  if (crops.length === 0) continue;

  const linked = new Set();
  for (const idChunk of chunks(crops.map((crop) => crop.id))) {
    let rows = null;
    for (let attempt = 0; attempt < 3 && rows === null; attempt += 1) {
      const { data, error } = await supabase
        .from('textbook_crop_question_links')
        .select('crop_id')
        .in('crop_id', idChunk);
      if (!error) {
        rows = data ?? [];
        break;
      }
      if (attempt === 2) throw new Error(`links_select_failed:${error.message}`);
      await new Promise((resolve) => setTimeout(resolve, 800 * (attempt + 1)));
    }
    for (const row of rows ?? []) linked.add(row.crop_id);
  }
  // crop → 문항 연결은 정규 링크 테이블이 우선이지만, 예전 추출은 crop 행의
  // pb_question_uid 만 채워 두기도 했다. 둘 중 하나라도 있으면 추출된 것이다.
  const unmapped = crops.filter(
    (crop) => !linked.has(crop.id) && !crop.pb_question_uid,
  );
  if (unmapped.length === 0) continue;

  const runs = await selectAll(
    'textbook_pb_extract_runs',
    'big_order,mid_order,sub_key,sub_index,big_name,mid_name,raw_page_from,raw_page_to',
    scope,
  );
  const usedSubIndexes = new Map();
  const namesByUnit = new Map();
  const coveredRanges = new Map();
  for (const run of runs) {
    const unitKey = `${run.big_order}/${run.mid_order}`;
    const runKey = `${unitKey}/${run.sub_key}`;
    if (!usedSubIndexes.has(runKey)) usedSubIndexes.set(runKey, new Set());
    usedSubIndexes.get(runKey).add(Number(run.sub_index ?? 0));
    if (!namesByUnit.has(unitKey) && (run.big_name || run.mid_name)) {
      namesByUnit.set(unitKey, {
        bigName: String(run.big_name ?? ''),
        midName: String(run.mid_name ?? ''),
      });
    }
    const from = Number(run.raw_page_from);
    const to = Number(run.raw_page_to);
    if (Number.isFinite(from) && Number.isFinite(to)) {
      if (!coveredRanges.has(runKey)) coveredRanges.set(runKey, []);
      coveredRanges.get(runKey).push([from, to]);
    }
  }

  const byUnit = new Map();
  for (const crop of unmapped) {
    const key = `${crop.big_order}/${crop.mid_order}/${crop.sub_key}`;
    if (!byUnit.has(key)) byUnit.set(key, []);
    byUnit.get(key).push(crop);
  }

  for (const [runKey, unitCrops] of byUnit) {
    const [bigOrder, midOrder, subKey] = runKey.split('/');
    const used = usedSubIndexes.get(runKey) ?? new Set();
    const covered = coveredRanges.get(runKey) ?? [];
    for (const block of splitIntoPageBlocks(unitCrops)) {
      const raw = pageRange(block, 'raw_page');
      const display = pageRange(block, 'display_page');
      if (raw.from == null) continue;
      // 이미 같은 페이지를 훑은 런이 있으면 추출이 아니라 매핑 쪽 문제다.
      // 같은 범위를 또 돌려도 같은 결과가 나올 뿐이라 건너뛴다.
      const alreadyRun = covered.some(
        ([from, to]) => from <= raw.from && to >= raw.to,
      );
      if (alreadyRun) continue;
      let subIndex = 0;
      while (used.has(subIndex)) subIndex += 1;
      used.add(subIndex);
      const names = namesByUnit.get(`${bigOrder}/${midOrder}`) ?? {
        bigName: '',
        midName: '',
      };
      plan.push({
        academyId: book.academy_id,
        bookId: book.book_id,
        bookName: String(book.payload?.book_name ?? book.payload?.name ?? ''),
        gradeLabel: book.grade_label,
        bigOrder: Number(bigOrder),
        midOrder: Number(midOrder),
        subKey,
        subIndex,
        bigName: names.bigName,
        midName: names.midName,
        subName:
          SHORT_NAME_BY_CATEGORY[CATEGORY_BY_SUB_KEY[subKey] ?? ''] ?? subKey,
        rawPageFrom: raw.from,
        rawPageTo: raw.to,
        displayPageFrom: display.from,
        displayPageTo: display.to,
        cropCount: block.length,
      });
    }
  }
}

plan.sort(
  (a, b) =>
    a.gradeLabel.localeCompare(b.gradeLabel) ||
    a.bigOrder - b.bigOrder ||
    a.midOrder - b.midOrder ||
    a.rawPageFrom - b.rawPageFrom,
);
const targets = limit > 0 ? plan.slice(0, limit) : plan;

console.log(`=== 새로 만들 추출 런 ${targets.length}건 (전체 후보 ${plan.length}) ===`);
const byGrade = new Map();
for (const item of targets) {
  const key = `${item.gradeLabel} · ${item.subKey} · ${item.bookId.slice(0, 8)}`;
  const prev = byGrade.get(key) ?? { runs: 0, crops: 0 };
  byGrade.set(key, { runs: prev.runs + 1, crops: prev.crops + item.cropCount });
}
for (const [key, value] of [...byGrade.entries()].sort()) {
  console.log(`  ${key.padEnd(24)} 런 ${String(value.runs).padStart(3)}개 · 문항 ${value.crops}`);
}
console.log(
  `총 문항 ${targets.reduce((sum, item) => sum + item.cropCount, 0)}건`,
);

if (!apply) {
  console.log('\n미리보기입니다. 실제로 만들려면 --apply 를 붙이세요.');
  process.exit(0);
}

const bodyLinkCache = new Map();
async function bodyLink(academyId, bookId, gradeLabel) {
  const key = `${academyId}/${bookId}/${gradeLabel}`;
  if (bodyLinkCache.has(key)) return bodyLinkCache.get(key);
  const { data, error } = await supabase
    .from('resource_file_links')
    .select('storage_bucket,storage_key,migration_status,file_size_bytes,content_hash')
    .eq('academy_id', academyId)
    .eq('file_id', bookId)
    .eq('grade', `${gradeLabel}#body`)
    .maybeSingle();
  if (error) throw new Error(`body_link_select_failed:${error.message}`);
  if (!data || data.migration_status !== 'migrated') {
    throw new Error(`body_link_not_migrated:${key}`);
  }
  bodyLinkCache.set(key, data);
  return data;
}

let created = 0;
for (const item of targets) {
  const link = await bodyLink(item.academyId, item.bookId, item.gradeLabel);
  const scope = {
    mode: 'textbook_pdf_only',
    book_id: item.bookId,
    book_name: item.bookName,
    series: 'wonri',
    grade_label: item.gradeLabel,
    big_order: item.bigOrder,
    mid_order: item.midOrder,
    sub_key: item.subKey,
    sub_index: item.subIndex,
    big_name: item.bigName,
    mid_name: item.midName,
    sub_name: item.subName,
    raw_page_from: item.rawPageFrom,
    raw_page_to: item.rawPageTo,
    display_page_from: item.displayPageFrom,
    display_page_to: item.displayPageTo,
  };
  const now = new Date().toISOString();

  const { data: document, error: documentError } = await supabase
    .from('pb_documents')
    .insert({
      academy_id: item.academyId,
      source_filename: `${item.bookName} · ${item.gradeLabel} · ${item.midName || `중${item.midOrder + 1}`} · ${item.subName} · p${item.displayPageFrom}-${item.displayPageTo}`,
      source_storage_bucket: 'problem-documents',
      source_storage_path: '',
      source_sha256: '',
      source_size_bytes: 0,
      source_pdf_storage_bucket: link.storage_bucket,
      source_pdf_storage_path: link.storage_key,
      source_pdf_filename: `${item.bookName}-${item.gradeLabel}-${item.subKey}.pdf`,
      source_pdf_sha256: String(link.content_hash ?? ''),
      source_pdf_size_bytes: Number(link.file_size_bytes ?? 0),
      status: 'extract_queued',
      curriculum_code: 'rev_2022',
      source_type_code: 'market_book',
      course_label: '',
      grade_label: item.gradeLabel,
      semester_label: '',
      exam_term_label: '',
      school_name: '',
      publisher_name: '',
      material_name: item.bookName,
      classification_detail: { textbook_scope: scope },
      meta: {
        textbook_scope: scope,
        extract_mode: 'textbook_pdf_only',
        created_at: now,
        // 이 런들은 누락 복구용이다. 사후 감사·롤백이 가능하도록 표시한다.
        created_by_script: 'queue_missing_textbook_extract_runs',
      },
    })
    .select('id')
    .maybeSingle();
  if (documentError) throw new Error(`pb_document_insert_failed:${documentError.message}`);
  const documentId = String(document?.id ?? '');
  if (!documentId) throw new Error('pb_document_insert_failed:no_id');

  const { data: job, error: jobError } = await supabase
    .from('pb_extract_jobs')
    .insert({
      academy_id: item.academyId,
      document_id: documentId,
      status: 'queued',
      source_version: PIPELINE_SOURCE_VERSION,
      result_summary: {
        engine: 'vlm_pdf_only',
        textbook_scope: scope,
        textbook_page_scoped: true,
        raw_page_from: item.rawPageFrom,
        raw_page_to: item.rawPageTo,
        display_page_from: item.displayPageFrom,
        display_page_to: item.displayPageTo,
      },
    })
    .select('id')
    .maybeSingle();
  if (jobError) throw new Error(`pb_extract_job_insert_failed:${jobError.message}`);
  const jobId = String(job?.id ?? '');
  if (!jobId) throw new Error('pb_extract_job_insert_failed:no_id');

  const { error: runError } = await supabase
    .from('textbook_pb_extract_runs')
    .upsert(
      {
        academy_id: item.academyId,
        book_id: item.bookId,
        grade_label: item.gradeLabel,
        big_order: item.bigOrder,
        mid_order: item.midOrder,
        sub_key: item.subKey,
        sub_index: item.subIndex,
        big_name: item.bigName,
        mid_name: item.midName,
        sub_name: item.subName,
        raw_page_from: item.rawPageFrom,
        raw_page_to: item.rawPageTo,
        display_page_from: item.displayPageFrom,
        display_page_to: item.displayPageTo,
        pb_document_id: documentId,
        extract_job_id: jobId,
        status: 'queued',
      },
      {
        onConflict:
          'academy_id,book_id,grade_label,big_order,mid_order,sub_key,sub_index',
      },
    );
  if (runError) throw new Error(`textbook_run_upsert_failed:${runError.message}`);

  created += 1;
  if (created % 10 === 0) console.log(`  ... ${created}/${targets.length}`);
}

console.log(`\n추출 런 ${created}건을 큐에 넣었습니다. 추출 워커가 순차 처리합니다.`);
