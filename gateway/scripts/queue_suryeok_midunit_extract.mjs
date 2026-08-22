// 수력충전 한 중단원의 본문 추출 런을 crop 스코프 그대로 큐에 넣는다.
//
// 기존 문서는 지우지 않는다. 런이 이미 queued/extracting 이면 건너뛰고,
// completed 같은 옛 런만 새 문서·잡으로 바꿔 가리키게 한다.
//
// 사용:
//   node scripts/queue_suryeok_midunit_extract.mjs --book <id> --grade 공통수학2 --big 1 --mid 2
//   node scripts/queue_suryeok_midunit_extract.mjs ... --apply
import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const PIPELINE_SOURCE_VERSION = 'textbook_pdf_only_v2_answers';
const SUB_NAME = { A: '유형 문제', B: '단원 마무리' };

const args = process.argv.slice(2);
const flag = (name) => {
  const at = args.indexOf(name);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : '';
};
const apply = args.includes('--apply');
const bookId = flag('--book');
const gradeLabel = flag('--grade');
const bigOrder = Number.parseInt(flag('--big'), 10);
const midOrder = Number.parseInt(flag('--mid'), 10);
if (!bookId || !gradeLabel || !Number.isFinite(bigOrder) || !Number.isFinite(midOrder)) {
  throw new Error('usage: --book <id> --grade <label> --big <n> --mid <n> [--apply]');
}

const supabase = createClient(
  String(process.env.SUPABASE_URL || '').trim(),
  String(process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const { data: meta, error: metaError } = await supabase
  .from('textbook_metadata')
  .select('academy_id,payload')
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .maybeSingle();
if (metaError) throw new Error(`metadata_failed:${metaError.message}`);
if (!meta) throw new Error('textbook_metadata_not_found');

const { data: crops, error: cropError } = await supabase
  .from('textbook_problem_crops')
  .select('sub_key,sub_index,raw_page,display_page,big_name,mid_name,is_set_header')
  .eq('academy_id', meta.academy_id)
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .eq('big_order', bigOrder)
  .eq('mid_order', midOrder)
  .eq('is_set_header', false);
if (cropError) throw new Error(`crops_failed:${cropError.message}`);

const groups = new Map();
for (const crop of crops ?? []) {
  const key = `${crop.sub_key}#${crop.sub_index}`;
  if (!groups.has(key)) {
    groups.set(key, {
      subKey: crop.sub_key,
      subIndex: Number(crop.sub_index ?? 0),
      bigName: String(crop.big_name ?? ''),
      midName: String(crop.mid_name ?? ''),
      pages: [],
      displayPages: [],
      count: 0,
    });
  }
  const group = groups.get(key);
  group.count += 1;
  const raw = Number(crop.raw_page);
  const display = Number(crop.display_page);
  if (Number.isFinite(raw) && raw > 0) group.pages.push(raw);
  if (Number.isFinite(display) && display > 0) group.displayPages.push(display);
}

const { data: runs, error: runError } = await supabase
  .from('textbook_pb_extract_runs')
  .select('sub_key,sub_index,status,pb_document_id,extract_job_id,updated_at')
  .eq('academy_id', meta.academy_id)
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .eq('big_order', bigOrder)
  .eq('mid_order', midOrder);
if (runError) throw new Error(`runs_failed:${runError.message}`);
const runByKey = new Map(
  (runs ?? []).map((run) => [`${run.sub_key}#${run.sub_index}`, run]),
);

const bookName = String(meta.payload?.book_name || meta.payload?.name || '수력충전');
const { data: courseHint } = await supabase
  .from('textbook_pb_extract_runs')
  .select('grade_key,course_key,course_label')
  .eq('book_id', bookId)
  .eq('grade_label', gradeLabel)
  .not('grade_key', 'eq', '')
  .limit(1)
  .maybeSingle();
const gradeKey = String(courseHint?.grade_key || 'H1');
const courseKey = String(courseHint?.course_key || 'H1-c2');
const courseLabel = String(courseHint?.course_label || gradeLabel);
const plan = [...groups.values()]
  .sort((a, b) => a.subKey.localeCompare(b.subKey) || a.subIndex - b.subIndex)
  .map((group) => {
    const existing = runByKey.get(`${group.subKey}#${group.subIndex}`);
    const status = String(existing?.status ?? '');
    const skip = status === 'queued' || status === 'extracting';
    return {
      ...group,
      rawFrom: Math.min(...group.pages),
      rawTo: Math.max(...group.pages),
      displayFrom: Math.min(...group.displayPages),
      displayTo: Math.max(...group.displayPages),
      subName: SUB_NAME[group.subKey] || group.subKey,
      existingStatus: status || '(없음)',
      skip,
      retarget: Boolean(existing) && !skip,
    };
  });

console.log(`=== ${bookName} ${gradeLabel} 대${bigOrder}-중${midOrder} 추출 계획 ${plan.length}건 ===`);
for (const item of plan) {
  const action = item.skip ? '건너뜀' : item.retarget ? '새문서+런교체' : '신규';
  console.log(
    `  ${item.subKey}#${item.subIndex} ${item.subName.padEnd(8)} p${item.rawFrom}-${item.rawTo} ` +
      `문항 ${String(item.count).padStart(2)} · 현재 ${item.existingStatus.padEnd(16)} → ${action}`,
  );
}
const targets = plan.filter((item) => !item.skip);
if (!apply) {
  console.log(`\n실제 넣을 런 ${targets.length}건. --apply 로 큐에 넣습니다.`);
  process.exit(0);
}

const { data: link, error: linkError } = await supabase
  .from('resource_file_links')
  .select('storage_bucket,storage_key,migration_status,file_size_bytes,content_hash')
  .eq('academy_id', meta.academy_id)
  .eq('file_id', bookId)
  .eq('grade', `${gradeLabel}#body`)
  .maybeSingle();
if (linkError) throw new Error(`body_link_failed:${linkError.message}`);
if (!link || link.migration_status !== 'migrated') {
  throw new Error('body_link_not_migrated');
}

let created = 0;
for (const item of targets) {
  const scope = {
    mode: 'textbook_pdf_only',
    book_id: bookId,
    book_name: bookName,
    series: 'suryeok',
    grade_label: gradeLabel,
    grade_key: gradeKey,
    course_key: courseKey,
    course_label: courseLabel,
    big_order: bigOrder,
    mid_order: midOrder,
    sub_key: item.subKey,
    sub_index: item.subIndex,
    big_name: item.bigName,
    mid_name: item.midName,
    sub_name: item.subName,
    raw_page_from: item.rawFrom,
    raw_page_to: item.rawTo,
    display_page_from: item.displayFrom,
    display_page_to: item.displayTo,
  };
  const now = new Date().toISOString();
  const suffix = item.subIndex > 0 ? ` · 소단원${item.subIndex + 1}` : '';
  const { data: document, error: documentError } = await supabase
    .from('pb_documents')
    .insert({
      academy_id: meta.academy_id,
      source_filename: `${bookName} · ${gradeLabel} · ${item.midName} · ${item.subName}${suffix}`,
      source_storage_bucket: 'problem-documents',
      source_storage_path: '',
      source_sha256: '',
      source_size_bytes: 0,
      source_pdf_storage_bucket: link.storage_bucket,
      source_pdf_storage_path: link.storage_key,
      source_pdf_filename: `${bookName}-${gradeLabel}-${item.subKey}.pdf`,
      source_pdf_sha256: String(link.content_hash ?? ''),
      source_pdf_size_bytes: Number(link.file_size_bytes ?? 0),
      status: 'extract_queued',
      curriculum_code: 'rev_2022',
      source_type_code: 'market_book',
      course_label: '',
      grade_label: gradeLabel,
      semester_label: '',
      exam_term_label: '',
      school_name: '',
      publisher_name: '',
      material_name: bookName,
      classification_detail: {
        textbook_scope: scope,
        textbook_course: {
          grade_key: gradeKey,
          course_key: courseKey,
          course_label: courseLabel,
        },
      },
      meta: {
        source_classification: {
          private_material: true,
          school_past_exam: false,
          mock_past_exam: false,
          textbook: {
            book_id: bookId,
            book_name: bookName,
            grade_label: gradeLabel,
            grade_key: gradeKey,
            course_key: courseKey,
            course_label: courseLabel,
            big_order: bigOrder,
            mid_order: midOrder,
            sub_key: item.subKey,
            big_name: item.bigName,
            mid_name: item.midName,
            sub_name: item.subName,
          },
        },
        textbook_scope: scope,
        textbook_course: {
          grade_key: gradeKey,
          course_key: courseKey,
          course_label: courseLabel,
        },
        extract_mode: 'textbook_pdf_only',
        created_at: now,
        created_by_script: 'queue_suryeok_midunit_extract',
      },
    })
    .select('id')
    .maybeSingle();
  if (documentError) throw new Error(`document_insert_failed:${documentError.message}`);
  const documentId = String(document?.id ?? '');
  if (!documentId) throw new Error('document_insert_failed:no_id');

  const { data: job, error: jobError } = await supabase
    .from('pb_extract_jobs')
    .insert({
      academy_id: meta.academy_id,
      document_id: documentId,
      status: 'queued',
      source_version: PIPELINE_SOURCE_VERSION,
      result_summary: {
        engine: 'vlm_pdf_only',
        textbook_scope: scope,
      },
    })
    .select('id')
    .maybeSingle();
  if (jobError) throw new Error(`job_insert_failed:${jobError.message}`);
  const jobId = String(job?.id ?? '');
  if (!jobId) throw new Error('job_insert_failed:no_id');

  const { error: upsertError } = await supabase
    .from('textbook_pb_extract_runs')
    .upsert(
      {
        academy_id: meta.academy_id,
        book_id: bookId,
        grade_label: gradeLabel,
        grade_key: gradeKey,
        course_key: courseKey,
        course_label: courseLabel,
        big_order: bigOrder,
        mid_order: midOrder,
        sub_key: item.subKey,
        sub_index: item.subIndex,
        big_name: item.bigName,
        mid_name: item.midName,
        sub_name: item.subName,
        raw_page_from: item.rawFrom,
        raw_page_to: item.rawTo,
        display_page_from: item.displayFrom,
        display_page_to: item.displayTo,
        pb_document_id: documentId,
        extract_job_id: jobId,
        status: 'queued',
        error_code: '',
        error_message: '',
        result_summary: { textbook_scope: scope },
      },
      {
        onConflict:
          'academy_id,book_id,grade_label,big_order,mid_order,sub_key,sub_index',
      },
    );
  if (upsertError) throw new Error(`run_upsert_failed:${upsertError.message}`);
  created += 1;
  console.log(`  queued ${item.subKey}#${item.subIndex} ${documentId}`);
}

console.log(`\n추출 런 ${created}건을 큐에 넣었습니다.`);
