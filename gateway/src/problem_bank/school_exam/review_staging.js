// 내신 시험지를 교재 검수 테이블에 올린다. 시험지 한 부가 검수 범위 하나다.
//
//   책(book_id)      = pb_documents.id 와 같은 UUID 의 resource_files 행(category 'school_past', 비공개)
//   범위             = grade_label(검수 과정 라벨), big_order 0, mid_order 0, sub_key 'A', sub_index 0
//   문항 크롭        = 좌표만 저장한다(raw_page + item_region_1k). 원본은 시험지 PDF 에서 그때그때 그린다.
//   정답             = 문제은행 정답을 채점 정답(textbook_problem_answers)으로 옮긴다.
//   해설             = 시험지에는 해설이 없다. 모든 문항에 "해설 없음"(source_kind 'none')을 적는다.
//
// 여러 번 불러도 같은 결과가 나온다. 사람이 고친 정답과 이미 있는 문항 영역은 덮어쓰지 않는다.

import { DEFAULT_EXAM_TOTAL, distributeExamScores, metaWithEstimatedScore } from './score_distribution.js';

export const SCHOOL_EXAM_CATEGORY = 'school_past';
export const SCHOOL_EXAM_SERIES_KEY = 'school_exam';
export const EXAM_SCOPE = Object.freeze({ bigOrder: 0, midOrder: 0, subKey: 'A', subIndex: 0 });
const WHOLE_PAGE_REGION = Object.freeze([0, 0, 1000, 1000]);

// 2015 과정 시험지는 2022 대응 과정의 개념을 후보로 쓴다(사장님 결정: 수학Ⅰ→대수, 수학Ⅱ→미적분Ⅰ).
const COURSE_LABEL_BY_KEY = Object.freeze({
  'H1-c1': '공통수학1',
  'H1-c2': '공통수학2',
  'H-algebra': '대수',
  'H-calc1': '미적분1',
  'H-calc2': '미적분2',
  'H-probstats': '확률과 통계',
  'H-geometry': '기하',
  'H-math1': '대수',
  'H-math2': '미적분1',
  'H-calculus': '미적분2',
  'H1-math-upper': '공통수학1',
  'H1-math-lower': '공통수학2',
});

const COURSE_LABEL_BY_NAME = Object.freeze({
  공통수학1: '공통수학1',
  공통수학2: '공통수학2',
  대수: '대수',
  미적분1: '미적분1',
  미적분2: '미적분2',
  확률과통계: '확률과 통계',
  기하: '기하',
  수학1: '대수',
  수학2: '미적분1',
  미적분: '미적분2',
  '수학(상)': '공통수학1',
  '수학(하)': '공통수학2',
});

function compact(value) {
  return String(value ?? '').trim();
}

function chunk(list, size) {
  const out = [];
  for (let i = 0; i < list.length; i += size) out.push(list.slice(i, i + size));
  return out;
}

/// 검수 과정 라벨: 개념 후보를 고르는 학년 라벨(concept_sources.grade_label)과 같은 값이어야 한다.
export function examReviewCourseLabel(doc) {
  const preset = compact(doc?.meta?.exam_review?.course_label);
  if (preset) return preset;
  const key = compact(doc?.course_key);
  const middle = /^M([1-3])-([12])$/.exec(key);
  if (middle) return `${middle[1]}-${middle[2]}`;
  if (COURSE_LABEL_BY_KEY[key]) return COURSE_LABEL_BY_KEY[key];
  const name = compact(doc?.course_label)
    .replace(/\s+/g, '')
    .replace(/Ⅰ/g, '1')
    .replace(/Ⅱ/g, '2');
  const plain = /^([1-3])-([12])$/.exec(name);
  if (plain) return `${plain[1]}-${plain[2]}`;
  return COURSE_LABEL_BY_NAME[name] || '';
}

/// 시험지 이름(학교 이름 제외): "2025 2학년 1학기 중간", 고등은 과목을 붙인다.
export function examTitle(doc) {
  const gradeKey = compact(doc?.grade_key);
  const gradeNum = /([1-3])$/.exec(gradeKey)?.[1] || '';
  const parts = [
    compact(doc?.exam_year),
    gradeNum ? `${gradeNum}학년` : '',
    compact(doc?.semester_label),
    compact(doc?.exam_term_label),
  ];
  const high = compact(doc?.school_level) === 'high' || gradeKey.startsWith('H');
  if (high) parts.push(compact(doc?.course_label));
  if (/서술형/.test(compact(doc?.source_filename))) parts.push('(서술형)');
  return parts.filter(Boolean).join(' ') || compact(doc?.source_filename) || '시험지';
}

/// 문제은행 정답 → 채점 정답. 원문 선지가 있는 객관식은 선지 번호, 그 밖에는 주관식 정답.
export function examAnswerSeed(question) {
  const choices = Array.isArray(question?.choices) ? question.choices : [];
  const key = compact(question?.objective_answer_key);
  const subjective = compact(question?.subjective_answer);
  if (question?.allow_objective !== false && key && choices.length >= 2) {
    return { answer_kind: 'objective', answer_text: key };
  }
  if (subjective) return { answer_kind: 'subjective', answer_text: subjective };
  return null;
}

function validRegion(raw) {
  if (!Array.isArray(raw) || raw.length !== 4) return null;
  const v = raw.map((x) => Math.round(Number(x)));
  if (v.some((x) => !Number.isFinite(x) || x < 0 || x > 1000)) return null;
  if (v[2] - v[0] < 5 || v[3] - v[1] < 5) return null;
  return v;
}

function isWholePage(region) {
  return Array.isArray(region) && region.length === 4 && region.every((x, i) => Number(x) === WHOLE_PAGE_REGION[i]);
}

/// 추출 때 적어 둔 문항 영역(meta.source_item)
export function storedSourceItem(question) {
  const item = question?.meta?.source_item;
  const region = validRegion(item?.region_1k);
  const rawPage = Number(item?.raw_page);
  if (!region || !(rawPage > 0)) return null;
  return { rawPage, region1k: region };
}

function cropStorageKey(academyId, documentId, problemNumber) {
  const num = compact(problemNumber).replace(/[^0-9A-Za-z가-힣_-]/g, '_') || 'item';
  return `academies/${academyId}/books/${documentId}/exam/0_0_A/${num}.png`;
}

// 네트워크가 잠깐 끊겨 난 실패. 여러 부를 이어 돌릴 때 이런 실패 한 번으로 시험지 하나가 멈추지 않게 다시 시도한다.
const TRANSIENT_ERROR_RE = /fetch failed|network|ECONNRESET|ETIMEDOUT|EAI_AGAIN|socket hang up|UND_ERR/i;
const DEFAULT_RETRY_DELAYS_MS = Object.freeze([1500, 4000]);

function isTransientError(message) {
  return TRANSIENT_ERROR_RE.test(String(message || ''));
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/// DB 질의 하나를 돌린다. 잠깐 끊긴 실패는 같은 질의를 다시 보낸다(질의 객체는 await 할 때마다 요청을 새로 보낸다).
/// 다시 보내도 결과가 같은 질의(조회·upsert·update·delete)에만 쓴다. 그냥 insert 는 retry: false 로 부른다.
async function runQuery(query, label, { retry = true, delaysMs = DEFAULT_RETRY_DELAYS_MS } = {}) {
  for (let attempt = 0; ; attempt += 1) {
    const { data, error } = await query;
    if (!error) return data;
    if (!retry || !isTransientError(error.message) || attempt >= delaysMs.length) {
      throw new Error(`${label}:${error.message}`);
    }
    await sleep(delaysMs[attempt]);
  }
}

/// 여러 질의로 된 한 단계를 돌린다. 잠깐 끊긴 실패면 단계를 처음부터 다시 돈다(단계는 다시 돌아도 결과가 같아야 한다).
async function runStep(step, delaysMs = DEFAULT_RETRY_DELAYS_MS) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await step();
    } catch (err) {
      if (!isTransientError(err?.message || err) || attempt >= delaysMs.length) throw err;
      await sleep(delaysMs[attempt]);
    }
  }
}

/// loadPdf(doc) → Buffer, readLayout({ pdfBuffer, questions }) → { regions: Map(번호 → { rawPage, region1k }) }
/// refreshAnswers: 방금 다시 추출한 문서라 문제은행 정답을 채점 정답에 다시 옮긴다(사람이 고친 정답은 그대로).
/// redetect: 사람이 고치지 않은 문항 영역을 모두 다시 찾는다.
/// identityOnly: 책 행과 본문 PDF 연결만 만들고 검수 범위(책·과정 라벨·이름)를 돌려준다.
/// retryDelaysMs: 네트워크가 잠깐 끊겼을 때 다시 시도하기 전 기다리는 시간들(빈 배열이면 다시 시도하지 않는다).
export async function prepareExamReview({
  supa,
  academyId,
  documentId,
  loadPdf,
  readLayout,
  refreshAnswers = false,
  redetect = false,
  identityOnly = false,
  retryDelaysMs = DEFAULT_RETRY_DELAYS_MS,
  log = null,
}) {
  const must = (query, label, options = {}) => runQuery(query, label, { delaysMs: retryDelaysMs, ...options });
  const doc = await must(
    supa
      .from('pb_documents')
      .select(
        'id,academy_id,status,source_filename,source_pdf_storage_bucket,source_pdf_storage_path,source_pdf_size_bytes,source_pdf_sha256,source_storage_bucket,curriculum_code,source_type_code,school_level,grade_key,course_key,course_label,grade_label,exam_year,semester_label,exam_term_label,school_name,meta',
      )
      .eq('id', documentId)
      .eq('academy_id', academyId)
      .maybeSingle(),
    'exam_review_document_fetch_failed',
  );
  if (!doc) return { ok: false, status: 404, error: 'document_not_found' };
  const isExam =
    compact(doc.source_type_code) === SCHOOL_EXAM_CATEGORY ||
    (doc.meta?.exam_review && typeof doc.meta.exam_review === 'object');
  if (!isExam) return { ok: false, status: 400, error: 'not_school_exam' };
  const pdfPath = compact(doc.source_pdf_storage_path);
  if (!pdfPath) return { ok: false, status: 400, error: 'pdf_source_required' };
  const gradeLabel = examReviewCourseLabel(doc);
  if (!gradeLabel) return { ok: false, status: 400, error: 'course_unresolved' };

  const schoolName = compact(doc.school_name) || '학교 미지정';
  const title = examTitle(doc);
  const pdfBucket = compact(doc.source_pdf_storage_bucket || doc.source_storage_bucket) || 'problem-documents';
  const identity = { bookId: documentId, bookName: `${schoolName} ${title}`, gradeLabel, schoolName, title };

  // 1) 책 행(학습앱·교재 목록에는 보이지 않는다)
  await must(
    supa.from('resource_files').upsert(
      {
        id: documentId,
        academy_id: academyId,
        name: `${schoolName} ${title}`,
        category: SCHOOL_EXAM_CATEGORY,
        is_published: false,
        description: '내신기출 검수용',
      },
      { onConflict: 'id' },
    ),
    'exam_review_book_upsert_failed',
  );

  // 2) 본문 PDF 연결(검수 화면이 시험지 PDF 를 받는 경로)
  const composite = `${gradeLabel}#body`;
  const linkValues = {
    academy_id: academyId,
    file_id: documentId,
    grade: composite,
    url: '',
    storage_driver: 'supabase',
    storage_bucket: pdfBucket,
    storage_key: pdfPath,
    migration_status: 'migrated',
    file_size_bytes: Number(doc.source_pdf_size_bytes) || null,
    content_hash: compact(doc.source_pdf_sha256) || null,
    uploaded_at: new Date().toISOString(),
  };
  // 연결 행에는 겹침을 막는 키가 없다. 넣다가 끊기면 다시 읽어 보고 없을 때만 넣는다.
  await runStep(async () => {
    const links = await must(
      supa.from('resource_file_links').select('id,grade,storage_key').eq('academy_id', academyId).eq('file_id', documentId),
      'exam_review_link_fetch_failed',
    );
    const sameLink = (links || []).find((l) => compact(l.grade) === composite);
    if (!sameLink) {
      await must(supa.from('resource_file_links').insert(linkValues), 'exam_review_link_insert_failed', { retry: false });
    } else if (compact(sameLink.storage_key) !== pdfPath) {
      await must(
        supa.from('resource_file_links').update(linkValues).eq('id', sameLink.id),
        'exam_review_link_update_failed',
      );
    }
  }, retryDelaysMs);
  // 작업 지시를 만들 때는 여기까지만 한다(추출 전이라 문항이 아직 없을 수 있다).
  if (identityOnly) return { ok: true, ...identity, identityOnly: true };

  const questions = await must(
    supa
      .from('pb_questions')
      .select(
        'id,question_uid,question_number,source_page,source_order,question_type,stem,choices,allow_objective,objective_answer_key,subjective_answer,source_item:meta->source_item',
      )
      .eq('academy_id', academyId)
      .eq('document_id', documentId)
      .order('source_order', { ascending: true }),
    'exam_review_questions_fetch_failed',
  );
  const byNumber = new Map();
  for (const q of questions || []) {
    const number = compact(q.question_number);
    if (number && compact(q.question_uid) && !byNumber.has(number)) byNumber.set(number, q);
  }
  if (byNumber.size === 0) return { ok: false, status: 400, error: 'no_questions' };

  // 3) 문항 크롭(좌표)
  const existingCrops = await must(
    supa
      .from('textbook_problem_crops')
      .select('id,problem_number,raw_page,item_region_1k,pb_question_uid,region_source,grade_label,big_order,mid_order,sub_key,sub_index')
      .eq('academy_id', academyId)
      .eq('book_id', documentId),
    'exam_review_crops_fetch_failed',
  );
  const inScope = (c) =>
    compact(c.grade_label) === gradeLabel &&
    Number(c.big_order) === EXAM_SCOPE.bigOrder &&
    Number(c.mid_order) === EXAM_SCOPE.midOrder &&
    compact(c.sub_key) === EXAM_SCOPE.subKey &&
    Number(c.sub_index || 0) === EXAM_SCOPE.subIndex;
  const cropByNumber = new Map();
  const staleCropIds = [];
  for (const c of existingCrops || []) {
    const number = compact(c.problem_number);
    if (inScope(c) && byNumber.has(number) && !cropByNumber.has(number)) cropByNumber.set(number, c);
    else staleCropIds.push(c.id);
  }

  // 문항 uid 가 바뀌었다 = 문서를 다시 올려 문항을 새로 만들었다.
  const isRecreated = (crop, q) =>
    Boolean(crop) && compact(crop.pb_question_uid) !== '' && compact(crop.pb_question_uid) !== compact(q.question_uid);

  const regionOf = new Map();
  const needDetect = [];
  for (const [number, q] of byNumber) {
    const crop = cropByNumber.get(number);
    const cropRegion = validRegion(crop?.item_region_1k);
    const manual = compact(crop?.region_source) === 'manual';
    // 새로 만든 문항은 예전 영역을 그대로 믿지 않는다(PDF 를 바꿔 올렸을 수 있다). 새 추출 영역을 먼저 쓴다.
    const fresh = !redetect && !isRecreated(crop, q) && !isWholePage(cropRegion);
    if (crop && cropRegion && Number(crop.raw_page) > 0 && (manual || fresh)) {
      regionOf.set(number, { rawPage: Number(crop.raw_page), region1k: cropRegion, keep: true });
      continue;
    }
    const stored = redetect ? null : storedSourceItem({ meta: { source_item: q.source_item } });
    if (stored) regionOf.set(number, stored);
    else needDetect.push(q);
  }

  let detected = 0;
  if (needDetect.length > 0) {
    try {
      const pdfBuffer = await runStep(() => loadPdf(doc), retryDelaysMs);
      const layout = await readLayout({
        pdfBuffer,
        questions: needDetect.map((q) => ({
          number: compact(q.question_number),
          sourcePage: q.source_page,
          sourceOrder: q.source_order,
          stem: q.stem,
          questionType: q.question_type,
        })),
      });
      for (const q of needDetect) {
        const number = compact(q.question_number);
        const hit = layout?.regions?.get(number);
        const region = validRegion(hit?.region1k);
        if (region && Number(hit?.rawPage) > 0) {
          regionOf.set(number, { rawPage: Number(hit.rawPage), region1k: region });
          detected += 1;
        }
      }
    } catch (err) {
      log?.('exam_review_region_detect_failed', { documentId, message: compact(err?.message || err) });
    }
  }
  // 끝내 못 찾은 문항: 예전에 찾아 둔 영역이 있으면 그것을 쓰고, 없으면 쪽 전체를 원본으로 쓴다
  // (검수는 돌고, 다음 준비 때 다시 찾는다).
  const pageFallbacks = [];
  for (const [number, q] of byNumber) {
    if (regionOf.has(number)) continue;
    const crop = cropByNumber.get(number);
    const previous = validRegion(crop?.item_region_1k);
    if (previous && Number(crop?.raw_page) > 0 && !isWholePage(previous)) {
      regionOf.set(number, { rawPage: Number(crop.raw_page), region1k: previous });
      continue;
    }
    regionOf.set(number, {
      rawPage: Number(crop?.raw_page) > 0 ? Number(crop.raw_page) : Math.max(1, Number(q.source_page) || 1),
      region1k: [...WHOLE_PAGE_REGION],
    });
    pageFallbacks.push(number);
  }

  const cropRows = [];
  const recreatedCropIds = [];
  for (const [number, q] of byNumber) {
    const crop = cropByNumber.get(number);
    const region = regionOf.get(number);
    const uidSame = compact(crop?.pb_question_uid) === compact(q.question_uid);
    // 새로 만든 문항에는 예전 문항의 검수 기록이 맞지 않는다.
    if (isRecreated(crop, q)) recreatedCropIds.push(crop.id);
    if (crop && region.keep && uidSame) continue;
    cropRows.push({
      academy_id: academyId,
      book_id: documentId,
      grade_label: gradeLabel,
      big_order: EXAM_SCOPE.bigOrder,
      mid_order: EXAM_SCOPE.midOrder,
      sub_key: EXAM_SCOPE.subKey,
      sub_index: EXAM_SCOPE.subIndex,
      big_name: schoolName,
      mid_name: title,
      raw_page: region.rawPage,
      display_page: region.rawPage,
      problem_number: number,
      label: '',
      is_set_header: false,
      item_region_1k: region.region1k,
      storage_key: cropStorageKey(academyId, documentId, number),
      pb_question_uid: q.question_uid,
      category_code: 'A',
      region_source: compact(crop?.region_source) === 'manual' ? 'manual' : 'vlm',
    });
  }
  for (const rows of chunk(cropRows, 100)) {
    await must(
      supa.from('textbook_problem_crops').upsert(rows, {
        onConflict: 'academy_id,book_id,grade_label,big_order,mid_order,sub_key,sub_index,problem_number',
      }),
      'exam_review_crops_upsert_failed',
    );
  }
  // 다시 추출해 없어진 번호나 다른 과정 라벨로 만든 예전 크롭은 지운다(검수 기록도 함께 지워진다).
  for (const ids of chunk(staleCropIds, 100)) {
    await must(supa.from('textbook_problem_crops').delete().in('id', ids), 'exam_review_crops_delete_failed');
  }
  // 문항을 새로 만든 크롭은 검수 기록(판정·지적·반영 대기)을 비워 처음부터 다시 검수하게 한다.
  for (const ids of chunk(recreatedCropIds, 100)) {
    await must(
      supa.from('textbook_review_findings').delete().in('crop_id', ids),
      'exam_review_findings_reset_failed',
    );
    await must(
      supa.from('textbook_problem_analyses').delete().in('crop_id', ids),
      'exam_review_analyses_reset_failed',
    );
  }

  const crops = await must(
    supa
      .from('textbook_problem_crops')
      .select('id,problem_number')
      .eq('academy_id', academyId)
      .eq('book_id', documentId)
      .eq('grade_label', gradeLabel)
      .eq('big_order', EXAM_SCOPE.bigOrder)
      .eq('mid_order', EXAM_SCOPE.midOrder)
      .eq('sub_key', EXAM_SCOPE.subKey)
      .eq('sub_index', EXAM_SCOPE.subIndex),
    'exam_review_crops_reload_failed',
  );
  const cropIdByNumber = new Map((crops || []).map((c) => [compact(c.problem_number), c.id]));
  const cropIds = Array.from(cropIdByNumber.values());

  // 4) 문제은행 문항 연결
  const linkRows = await must(
    supa.from('textbook_crop_question_links').select('crop_id,pb_question_id').in('crop_id', cropIds),
    'exam_review_links_fetch_failed',
  );
  const linkedTo = new Map((linkRows || []).map((l) => [l.crop_id, l.pb_question_id]));
  const newLinks = [];
  for (const [number, q] of byNumber) {
    const cropId = cropIdByNumber.get(number);
    if (cropId && linkedTo.get(cropId) !== q.id) {
      newLinks.push({ crop_id: cropId, academy_id: academyId, pb_question_id: q.id, source: 'extract', confidence: 1 });
    }
  }
  for (const rows of chunk(newLinks, 100)) {
    await must(
      supa.from('textbook_crop_question_links').upsert(rows, { onConflict: 'crop_id' }),
      'exam_review_links_upsert_failed',
    );
  }

  // 5) 채점 정답
  const answerRows = await must(
    supa.from('textbook_problem_answers').select('crop_id,answer_kind,answer_text,answer_source').in('crop_id', cropIds),
    'exam_review_answers_fetch_failed',
  );
  const answerOf = new Map((answerRows || []).map((a) => [a.crop_id, a]));
  const recreatedCrops = new Set(recreatedCropIds);
  const answerInserts = [];
  const answerUpdates = [];
  const missingAnswers = [];
  for (const [number, q] of byNumber) {
    const cropId = cropIdByNumber.get(number);
    if (!cropId) continue;
    const seed = examAnswerSeed(q);
    const cur = answerOf.get(cropId);
    if (!cur) {
      if (!seed) {
        missingAnswers.push(number);
        continue;
      }
      answerInserts.push({ crop_id: cropId, academy_id: academyId, ...seed, answer_source: 'vlm' });
    } else if (
      // 새로 만든 문항은 요청이 없어도 문제은행 정답을 다시 옮긴다(사람이 고친 정답은 그대로).
      (refreshAnswers || recreatedCrops.has(cropId)) &&
      seed &&
      compact(cur.answer_source) !== 'manual' &&
      (compact(cur.answer_kind) !== seed.answer_kind || compact(cur.answer_text) !== seed.answer_text)
    ) {
      answerUpdates.push({ cropId, seed });
    }
  }
  // 이미 있는 정답 행은 건드리지 않는다(그 사이 사람이 넣은 정답 포함). 다시 보내도 결과가 같다.
  for (const rows of chunk(answerInserts, 100)) {
    await must(
      supa.from('textbook_problem_answers').upsert(rows, { onConflict: 'crop_id', ignoreDuplicates: true }),
      'exam_review_answers_insert_failed',
    );
  }
  for (const u of answerUpdates) {
    await must(
      supa.from('textbook_problem_answers').update(u.seed).eq('crop_id', u.cropId).neq('answer_source', 'manual'),
      'exam_review_answers_update_failed',
    );
  }

  // 6) 해설 없음
  const refRows = await must(
    supa.from('textbook_problem_solution_refs').select('crop_id').in('crop_id', cropIds),
    'exam_review_solution_refs_fetch_failed',
  );
  const hasRef = new Set((refRows || []).map((r) => r.crop_id));
  const nowIso = new Date().toISOString();
  const refInserts = cropIds
    .filter((id) => !hasRef.has(id))
    .map((id) => ({
      crop_id: id,
      academy_id: academyId,
      raw_page: 0,
      number_region_1k: [0, 0, 0, 0],
      source_kind: 'none',
      edited_at: nowIso,
    }));
  for (const rows of chunk(refInserts, 100)) {
    await must(
      supa.from('textbook_problem_solution_refs').upsert(rows, { onConflict: 'crop_id', ignoreDuplicates: true }),
      'exam_review_solution_refs_insert_failed',
    );
  }

  // 7) 점수를 못 읽은 문항에 점수를 나눠 총합을 맞춘다. 읽은 점수·사람이 넣은 점수는 그대로 둔다.
  //    실패해도 검수 준비는 끝낸다(점수는 다음 준비 때 다시 나눈다).
  const scores = { estimated: 0, total: DEFAULT_EXAM_TOTAL, unit: 1, reason: null };
  try {
    const scoreRows = await must(
      supa
        .from('pb_questions')
        .select('id,question_number,source_order,question_type,choices,meta')
        .eq('academy_id', academyId)
        .eq('document_id', documentId)
        .order('source_order', { ascending: true }),
      'exam_review_scores_fetch_failed',
    );
    const dist = distributeExamScores(scoreRows || []);
    scores.unit = dist.unit;
    scores.reason = dist.ok ? null : dist.reason;
    if (dist.ok) {
      for (const row of scoreRows || []) {
        if (!dist.scores.has(row.id)) continue;
        const nextMeta = metaWithEstimatedScore(row.meta, dist.scores.get(row.id), { at: nowIso });
        if (!nextMeta) continue;
        await must(
          supa.from('pb_questions').update({ meta: nextMeta }).eq('id', row.id).eq('academy_id', academyId),
          'exam_review_scores_update_failed',
        );
        scores.estimated += 1;
      }
    }
  } catch (err) {
    scores.reason = 'failed';
    log?.('exam_review_scores_failed', { documentId, message: String(err?.message || err) });
  }

  const result = {
    ok: true,
    ...identity,
    scoresEstimated: scores.estimated,
    scoreUnit: scores.unit,
    scoreIssue: scores.reason,
    questionCount: byNumber.size,
    cropCount: cropIds.length,
    cropsWritten: cropRows.length,
    cropsRemoved: staleCropIds.length,
    reviewsReset: recreatedCropIds.length,
    regionsDetected: detected,
    pageFallbacks,
    answersSeeded: answerInserts.length,
    answersRefreshed: answerUpdates.length,
    missingAnswers,
  };
  log?.('exam_review_prepared', { documentId, ...result });
  return result;
}
