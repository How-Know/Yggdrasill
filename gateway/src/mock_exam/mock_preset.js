// 모의고사 기출 자동 프리셋(pb_export_presets) 빌더 및 동기화.
//
// 2015 개정 교육과정 고3 기준:
// - 공통 1~22 + 선택과목(확률과 통계 / 미적분 / 기하) 23~30 = 30문항 합본
// - 12페이지 단 배치 고정:
//   2/2, 2/1, 2/1, 1/1, 1/1, 1/2, 2/1, 1/1, 1/1, 1/1, 1/1, 1/1
// - 1~15 객관식(1p 좌 1행 5지선다형), 16~22 단답형(6p 좌 1행 단답형),
//   23~28 선택 객관식(9p 제목 페이지 + 좌 1행 5지선다형), 29~30 선택 단답형(12p 좌 1행 단답형)
// - 8p 하단 선택과목 확인 사항, 12p 하단 단축 확인 사항

import { ELECTIVES, LEGACY_TYPES, SECTION_LABELS, isLegacyType } from './mock_pages.js';
import { slotQuestionRow } from './slot_values.js';

const ORG_LABELS = { edu: '교육청', kice: '평가원', csat: '수능' };

/// 가형·나형(2020년 시행분까지)은 고1·고2 처럼 1~21번이 5지선다형, 22~30번이 단답형이다.
export function mockExamIsObjective(grade, number, elective = '') {
  if (Number(grade) === 3 && !isLegacyType(elective)) {
    return number <= 15 || (number >= 23 && number <= 28);
  }
  return number <= 21;
}

export const GRADE3_MOCK_PAGE_COLUMN_COUNTS = Object.freeze([
  { pageIndex: 1, left: 2, right: 2 },
  { pageIndex: 2, left: 2, right: 1 },
  { pageIndex: 3, left: 2, right: 1 },
  { pageIndex: 4, left: 1, right: 1 },
  { pageIndex: 5, left: 1, right: 1 },
  { pageIndex: 6, left: 1, right: 2 },
  { pageIndex: 7, left: 2, right: 1 },
  { pageIndex: 8, left: 1, right: 1 },
  { pageIndex: 9, left: 1, right: 1 },
  { pageIndex: 10, left: 1, right: 1 },
  { pageIndex: 11, left: 1, right: 1 },
  { pageIndex: 12, left: 1, right: 1 },
]);

function compact(v) {
  return String(v ?? '').trim();
}

export function buildMockExamLinkKey(exam, elective = '') {
  const grade = Number(exam?.grade || 3);
  const year = Number(exam?.exam_year || 0);
  const month = Number(exam?.exam_month || 0);
  const org = compact(exam?.org);
  const el = compact(elective);
  return `H${grade}|${year}|${month}|${org}|${el}`;
}

export function parseMockExamLinkKey(rawKey) {
  const raw = compact(rawKey);
  if (!raw) return null;
  const parts = raw.split('|');
  if (parts.length < 4) return null;
  const gradeKey = compact(parts[0]);
  const grade = Number.parseInt(gradeKey.replace(/\D/g, ''), 10);
  const examYear = Number.parseInt(compact(parts[1]), 10);
  const examMonth = Number.parseInt(compact(parts[2]), 10);
  const org = compact(parts[3]);
  const elective = compact(parts[4] || '');
  if (!Number.isFinite(grade) || !Number.isFinite(examYear) || !Number.isFinite(examMonth) || !org) {
    return null;
  }
  return { gradeKey, grade, examYear, examMonth, org, elective };
}

export function buildMockExamTitlePageTopText(exam) {
  const grade = Number(exam?.grade || 3);
  const examYear = Number(exam?.exam_year || 0);
  const schoolYear = Number(exam?.school_year || (grade === 3 ? examYear + 1 : examYear));
  const month = Number(exam?.exam_month || 0);
  const org = compact(exam?.org);

  if (org === 'csat' || month === 11 && grade === 3) {
    return `${schoolYear}학년도 대학수학능력시험 문제지`;
  }
  if (org === 'kice' && (month === 6 || month === 9)) {
    return `${schoolYear}학년도 대학수학능력시험 ${month}월 모의평가 문제지`;
  }
  // 교육청 학력평가 (고3 3·4(5)·7·10월 및 고1·2)는 시행연도 학년도 표기를 따른다.
  const displayMonth = grade === 3 && month === 4 && examYear >= 2024 ? 5 : month;
  return `${examYear}학년도 ${displayMonth}월 고${grade} 전국연합학력평가 문제지`;
}

export function buildMockExamPresetDisplayName(exam, elective = '') {
  const grade = Number(exam?.grade || 3);
  const examYear = Number(exam?.exam_year || 0);
  const month = Number(exam?.exam_month || 0);
  const orgLabel = ORG_LABELS[compact(exam?.org)] || compact(exam?.org);
  const base = `${examYear} 고${grade} ${month}월 ${orgLabel}`.trim();
  const el = compact(elective);
  if (!el) return base;
  const elLabel = SECTION_LABELS[el] || el;
  return `${base} (${elLabel})`;
}

export function buildGrade3ColumnLabelAnchors(electiveLabel) {
  const cleanElective = compact(electiveLabel) || '확률과 통계';
  return [
    {
      page: 1,
      columnIndex: 0,
      rowIndex: 0,
      label: '5지선다형',
      source: 'auto',
      topPt: 16,
      paddingTopPt: 27,
    },
    {
      page: 6,
      columnIndex: 0,
      rowIndex: 0,
      label: '단답형',
      source: 'auto',
      topPt: 9.2,
      paddingTopPt: 35.8,
    },
    {
      page: 8,
      columnIndex: 1,
      rowIndex: 99,
      label: `선택과목(${cleanElective})`,
      source: 'auto',
      topPt: 0,
      paddingTopPt: 0,
    },
    {
      page: 9,
      columnIndex: 0,
      rowIndex: 0,
      label: '5지선다형',
      source: 'auto',
      topPt: 16,
      paddingTopPt: 27,
    },
    {
      page: 12,
      columnIndex: 0,
      rowIndex: 0,
      label: '단답형',
      source: 'auto',
      topPt: 9.2,
      paddingTopPt: 35.8,
    },
    {
      page: 12,
      columnIndex: 1,
      rowIndex: 99,
      label: '확인 사항',
      source: 'auto',
      topPt: 0,
      paddingTopPt: 0,
    },
  ];
}

export function buildMockExamPresetPayload({
  exam,
  elective = '',
  orderedQuestions,
  commonDocumentId,
  electiveDocumentId = '',
}) {
  const grade = Number(exam?.grade || 3);
  const el = compact(elective);
  const elLabel = SECTION_LABELS[el] || el;
  const selectedQuestionIds = [];
  const selectedQuestionUids = [];
  const questionModeByQuestionUid = {};
  const questionScoreByQuestionUid = {};

  for (const row of orderedQuestions || []) {
    const id = compact(row?.id);
    const uid = compact(row?.question_uid) || id;
    if (!id || !uid) continue;
    selectedQuestionIds.push(id);
    selectedQuestionUids.push(uid);

    const num = Number.parseInt(compact(row?.question_number), 10);
    const isObj = Number.isFinite(num)
      ? mockExamIsObjective(grade, num, el)
      : compact(row?.question_type) !== '주관식';
    questionModeByQuestionUid[uid] = isObj ? 'objective' : 'subjective';

    // 다른 구간의 문항을 가리키는 자리(row.__slot)는 이 시험지의 번호(위의 question_number)와 배점을 쓴다.
    // 본문·선지 순서는 내보낼 때 자리에서 다시 읽는다(mock_exam/paper_slots.js).
    const score = Number(row?.__slot?.score ?? row?.meta?.score_point ?? row?.score_point);
    if (Number.isFinite(score) && score > 0) {
      questionScoreByQuestionUid[uid] = score;
    }
  }

  const sourceDocumentIds = [compact(commonDocumentId), compact(electiveDocumentId)]
    .filter(Boolean)
    .filter((v, idx, arr) => arr.indexOf(v) === idx);
  const sourceDocumentId = compact(electiveDocumentId) || compact(commonDocumentId);

  const titlePageTopText = buildMockExamTitlePageTopText(exam);
  // 가형·나형은 시험지 한 부가 구간 하나라 고1·고2 와 같은 한 묶음 지면이다(첫 쪽 제목에 유형을 적는다).
  const isGrade3Elective = grade === 3 && ELECTIVES.includes(el);
  const pageColumnQuestionCounts = isGrade3Elective
    ? GRADE3_MOCK_PAGE_COLUMN_COUNTS.map((row) => ({ ...row }))
    : [];
  const titlePageIndices = isGrade3Elective ? [1, 9] : [1];
  const titlePageHeaders = isGrade3Elective
    ? [
        { page: 1, title: '수학 영역', subtitle: '' },
        { page: 9, title: '수학 영역', subtitle: elLabel },
      ]
    : [{ page: 1, title: '수학 영역', subtitle: isLegacyType(el) ? elLabel : '' }];
  const columnLabelAnchors = isGrade3Elective
    ? buildGrade3ColumnLabelAnchors(elLabel)
    : [];
  const mockExamLinkKey = buildMockExamLinkKey(exam, el);
  const displayName = buildMockExamPresetDisplayName(exam, el);

  const renderConfig = {
    renderConfigVersion: 4,
    presetKind: 'settings',
    templateProfile: 'csat',
    paperSize: '8절',
    font: {
      family: 'KoPubWorldBatangPro',
      size: 11.0,
    },
    layoutColumns: 2,
    maxQuestionsPerPage: 4,
    layoutMode: 'custom_columns',
    pageColumnQuestionCounts,
    columnLabelAnchors,
    titlePageIndices,
    titlePageHeaders,
    titlePageTopText,
    titlePageGoalText: '제 2 교시',
    subjectTitleText: '수학 영역',
    timeLimitText: '100분',
    includeAcademyLogo: false,
    includeCoverPage: false,
    coverPageTexts: {},
    includeAnswerSheet: true,
    includeExplanation: false,
    includeQuestionScore: true,
    questionNumberPlacement: 'inline',
    questionNumberFormat: 'source',
    renumberQuestions: false,
    mathEngine: 'xelatex-v2',
    disableAutoLabels: false,
    questionMode: 'original',
    selectedQuestionUidsOrdered: selectedQuestionUids,
    selectedQuestionIdsOrdered: selectedQuestionIds,
    questionModeByQuestionUid,
    questionModeByQuestionId: questionModeByQuestionUid,
    questionScoreByQuestionUid,
    questionScoreByQuestionId: questionScoreByQuestionUid,
    mockExamLinkKey,
    mockExamMeta: {
      examId: compact(exam?.id),
      grade,
      examYear: Number(exam?.exam_year || 0),
      schoolYear: Number(exam?.school_year || 0),
      examMonth: Number(exam?.exam_month || 0),
      org: compact(exam?.org),
      elective: el,
      electiveLabel: elLabel,
    },
  };

  return {
    academy_id: compact(exam?.academy_id),
    source_document_id: sourceDocumentId,
    document_id: null,
    source_document_ids: sourceDocumentIds,
    preset_kind: 'settings',
    display_name: displayName,
    render_config: renderConfig,
    selected_question_uids: selectedQuestionUids,
    selected_question_ids: selectedQuestionIds,
    question_mode_by_question_uid: questionModeByQuestionUid,
    question_mode_by_question_id: questionModeByQuestionUid,
  };
}

/// 검수에서 만든 구간 문서이고 아직 확정(공개)하지 않았는가. 그동안 문항은 비공개다.
export function mockReviewPending(meta) {
  const review = meta?.mock_review;
  return Boolean(
    review && typeof review === 'object' && review.publish_on_confirm === true && !compact(review.published_at),
  );
}

// 회차(exam_id)의 추출된 pb_questions 가 준비된 과목 조합마다 자동 프리셋을 upsert 한다.
export async function syncMockExamPresetsForExam(supa, examId) {
  const cleanExamId = compact(examId);
  if (!cleanExamId) return { synced: 0, presets: [] };

  const { data: exam, error: examErr } = await supa
    .from('mock_exams')
    .select('*')
    .eq('id', cleanExamId)
    .maybeSingle();
  if (examErr) throw new Error(`mock_preset_exam_fetch_failed:${examErr.message}`);
  if (!exam) return { synced: 0, presets: [] };

  const { data: sectionRows, error: secErr } = await supa
    .from('mock_exam_sections')
    .select('section, pb_document_id')
    .eq('exam_id', cleanExamId);
  if (secErr) throw new Error(`mock_preset_sections_fetch_failed:${secErr.message}`);

  const docIdBySection = new Map();
  for (const row of sectionRows || []) {
    const sec = compact(row?.section);
    const docId = compact(row?.pb_document_id);
    if (sec && docId) docIdBySection.set(sec, docId);
  }
  // 검수에서 만든 구간 문서(meta.mock_review.publish_on_confirm)는 구간을 확정해 공개하기 전에는 프리셋에 넣지 않는다.
  if (docIdBySection.size > 0) {
    const { data: docRows, error: docErr } = await supa
      .from('pb_documents')
      .select('id, meta')
      .in('id', [...new Set([...docIdBySection.values()])]);
    if (docErr) throw new Error(`mock_preset_documents_fetch_failed:${docErr.message}`);
    const hidden = new Set((docRows || []).filter((d) => mockReviewPending(d?.meta)).map((d) => d.id));
    for (const [sec, docId] of [...docIdBySection]) {
      if (hidden.has(docId)) docIdBySection.delete(sec);
    }
  }
  const commonDocId = docIdBySection.get('common') || '';
  // 가형·나형 회차에는 공통 구간이 없다. 유형 구간 하나(30문항)가 프리셋 하나다.
  const legacyTypes = LEGACY_TYPES.filter((t) => docIdBySection.has(t));
  if (!commonDocId && legacyTypes.length === 0) return { synced: 0, presets: [] };

  const allDocIds = [...new Set([...docIdBySection.values()])];
  const { data: qRows, error: qErr } = await supa
    .from('pb_questions')
    .select('id, question_uid, document_id, question_number, source_order, question_type, meta')
    .eq('academy_id', exam.academy_id)
    .in('document_id', allDocIds);
  if (qErr) throw new Error(`mock_preset_questions_fetch_failed:${qErr.message}`);

  const questionsByDocId = new Map();
  for (const row of qRows || []) {
    const docId = compact(row?.document_id);
    if (!questionsByDocId.has(docId)) questionsByDocId.set(docId, []);
    questionsByDocId.get(docId).push(row);
  }

  // 같은 문항을 합친 가형·나형: 한 구간만 문항을 갖고, 다른 구간의 자리(merged_at)는 그 문항을 가리킨다.
  // 그 문항은 이 구간 문서에 없으므로 자리로 채운다. 문항을 가진 구간이 아직 확정 전이면 qRows 에 없어
  // 이 시험지는 30문항이 되지 않고, 아래 개수 검사에서 프리셋을 만들지 않는다.
  const { data: slotRows, error: slotErr } = await supa
    .from('mock_exam_items')
    .select('section, problem_number, pb_question_id, score, choice_order, stem_override')
    .eq('exam_id', cleanExamId)
    .not('merged_at', 'is', null);
  if (slotErr) throw new Error(`mock_preset_slots_fetch_failed:${slotErr.message}`);
  const questionById = new Map((qRows || []).map((row) => [compact(row?.id), row]));
  for (const item of slotRows || []) {
    const docId = docIdBySection.get(compact(item?.section));
    if (!docId) continue;
    const row = slotQuestionRow(item, questionById.get(compact(item?.pb_question_id)));
    if (!row) continue;
    if (!questionsByDocId.has(docId)) questionsByDocId.set(docId, []);
    questionsByDocId.get(docId).push(row);
  }
  const sortQuestions = (rows) =>
    [...(rows || [])].sort((a, b) => {
      const na = Number.parseInt(compact(a?.question_number), 10);
      const nb = Number.parseInt(compact(b?.question_number), 10);
      if (Number.isFinite(na) && Number.isFinite(nb) && na !== nb) return na - nb;
      return Number(a?.source_order || 0) - Number(b?.source_order || 0);
    });

  const commonQuestions = sortQuestions(questionsByDocId.get(commonDocId) || []);
  const grade = Number(exam.grade || 3);
  const commonReady = Boolean(commonDocId) && commonQuestions.length >= (grade === 3 ? 22 : 30);
  if (!commonReady && (grade !== 3 || legacyTypes.length === 0)) {
    return { synced: 0, presets: [] };
  }

  // 기존 학원 settings 프리셋 중 mockExamLinkKey 가 있는 항목을 조회해 덮어쓰기 대상으로 매칭
  const { data: existingRows, error: exErr } = await supa
    .from('pb_export_presets')
    .select('id, display_name, render_config')
    .eq('academy_id', exam.academy_id)
    .eq('preset_kind', 'settings');
  if (exErr) throw new Error(`mock_preset_existing_fetch_failed:${exErr.message}`);

  const existingByLinkKey = new Map();
  for (const row of existingRows || []) {
    const key = compact(row?.render_config?.mockExamLinkKey);
    if (key && !existingByLinkKey.has(key)) {
      existingByLinkKey.set(key, row);
    }
  }

  const targets = grade === 3 ? [...(commonReady ? ELECTIVES : []), ...legacyTypes] : [''];
  const syncedPresets = [];

  for (const elective of targets) {
    let orderedQuestions = commonQuestions;
    let electiveDocId = '';
    let commonId = commonDocId;
    if (isLegacyType(elective)) {
      electiveDocId = docIdBySection.get(elective) || '';
      const typeQuestions = sortQuestions(questionsByDocId.get(electiveDocId) || []);
      if (typeQuestions.length < 30) continue;
      orderedQuestions = typeQuestions.slice(0, 30);
      commonId = '';
    } else if (grade === 3) {
      electiveDocId = docIdBySection.get(elective) || '';
      if (!electiveDocId) continue;
      const electiveQuestions = sortQuestions(questionsByDocId.get(electiveDocId) || []);
      if (electiveQuestions.length < 8) continue;
      orderedQuestions = [...commonQuestions.slice(0, 22), ...electiveQuestions.slice(0, 8)];
    }

    const payload = buildMockExamPresetPayload({
      exam,
      elective,
      orderedQuestions,
      commonDocumentId: commonId,
      electiveDocumentId: electiveDocId,
    });
    const linkKey = payload.render_config.mockExamLinkKey;
    const existing = existingByLinkKey.get(linkKey);

    if (existing?.id) {
      const { data: updated, error: upErr } = await supa
        .from('pb_export_presets')
        .update({
          source_document_id: payload.source_document_id,
          source_document_ids: payload.source_document_ids,
          display_name: payload.display_name,
          render_config: payload.render_config,
          selected_question_uids: payload.selected_question_uids,
          selected_question_ids: payload.selected_question_ids,
          question_mode_by_question_uid: payload.question_mode_by_question_uid,
          question_mode_by_question_id: payload.question_mode_by_question_id,
          updated_at: new Date().toISOString(),
        })
        .eq('academy_id', exam.academy_id)
        .eq('id', existing.id)
        .select('id, display_name')
        .single();
      if (upErr) throw new Error(`mock_preset_update_failed:${upErr.message}`);
      syncedPresets.push(updated);
    } else {
      const { data: inserted, error: inErr } = await supa
        .from('pb_export_presets')
        .insert({
          ...payload,
          created_by: exam.created_by || null,
        })
        .select('id, display_name')
        .single();
      if (inErr) throw new Error(`mock_preset_insert_failed:${inErr.message}`);
      syncedPresets.push(inserted);
    }
  }

  return { synced: syncedPresets.length, presets: syncedPresets };
}
