// 중학교 내신 기출 자동 프리셋(pb_export_presets) 빌더 및 동기화.
//
// 대상 학교(8개 중학교):
// - 경신중 (gyeongsin) : 표지 ON, 표지 뒤 빈 페이지 ON
// - 능인중 (neungin)   : 표지 ON, 표지 뒤 빈 페이지 OFF
// - 대륜중 (daeryun)   : 표지 OFF, 표지 뒤 빈 페이지 OFF
// - 동도중 (dongdo)    : 표지 OFF, 표지 뒤 빈 페이지 OFF
// - 소선여중 (soseon)  : 표지 ON, 표지 뒤 빈 페이지 OFF
// - 오성중 (oseong)    : 표지 ON, 표지 뒤 빈 페이지 OFF
// - 정화중 (jeonghwa)  : 표지 ON, 표지 뒤 빈 페이지 OFF
// - 황금중 (hwanggeum) : 표지 ON, 표지 뒤 빈 페이지 OFF
//
// 기본 용지: B4, 2단, 단별 문항수(pageColumnQuestionCounts) 기본값은 자동([]).
// 이미 해당 학교 템플릿으로 저장된 프리셋을 재동기화할 때는 사용자가 수동으로
// 수정·저장해 둔 pageColumnQuestionCounts 및 표지 문구를 보존한다.

export const MIDDLE_SCHOOL_TEMPLATE_MAP = Object.freeze({
  경신중: Object.freeze({
    schoolKey: '경신중',
    fullSchoolName: '경신중학교',
    templateProfile: 'gyeongsin',
    includeCoverPage: true,
    includeCoverBlankPage: true,
  }),
  능인중: Object.freeze({
    schoolKey: '능인중',
    fullSchoolName: '능인중학교',
    templateProfile: 'neungin',
    includeCoverPage: true,
    includeCoverBlankPage: false,
  }),
  대륜중: Object.freeze({
    schoolKey: '대륜중',
    fullSchoolName: '대륜중학교',
    templateProfile: 'daeryun',
    includeCoverPage: false,
    includeCoverBlankPage: false,
  }),
  동도중: Object.freeze({
    schoolKey: '동도중',
    fullSchoolName: '동도중학교',
    templateProfile: 'dongdo',
    includeCoverPage: false,
    includeCoverBlankPage: false,
  }),
  소선여중: Object.freeze({
    schoolKey: '소선여중',
    fullSchoolName: '소선여자중학교',
    templateProfile: 'soseon',
    includeCoverPage: true,
    includeCoverBlankPage: false,
  }),
  오성중: Object.freeze({
    schoolKey: '오성중',
    fullSchoolName: '오성중학교',
    templateProfile: 'oseong',
    includeCoverPage: true,
    includeCoverBlankPage: false,
  }),
  정화중: Object.freeze({
    schoolKey: '정화중',
    fullSchoolName: '정화중학교',
    templateProfile: 'jeonghwa',
    includeCoverPage: true,
    includeCoverBlankPage: false,
  }),
  황금중: Object.freeze({
    schoolKey: '황금중',
    fullSchoolName: '황금중학교',
    templateProfile: 'hwanggeum',
    includeCoverPage: true,
    includeCoverBlankPage: false,
  }),
});

const MIDDLE_SCHOOL_KEYS = Object.freeze(Object.keys(MIDDLE_SCHOOL_TEMPLATE_MAP));

function compact(v) {
  return String(v ?? '').trim();
}

export function canonicalMiddleSchoolKey(raw) {
  const s = compact(raw).replace(/\s+/g, '');
  if (!s) return '';
  for (const key of MIDDLE_SCHOOL_KEYS) {
    if (s === key || s === MIDDLE_SCHOOL_TEMPLATE_MAP[key].fullSchoolName) {
      return key;
    }
  }
  const normalized = s
    .replace(/여자중학교$/, '여중')
    .replace(/중학교$/, '중');
  if (MIDDLE_SCHOOL_TEMPLATE_MAP[normalized]) {
    return normalized;
  }
  if (s.includes('소선여중') || s.includes('소선여자중')) return '소선여중';
  for (const key of MIDDLE_SCHOOL_KEYS) {
    if (s.includes(key)) return key;
  }
  return '';
}

export function parseNaesinLinkKeyParts(rawKey) {
  const raw = compact(rawKey);
  if (!raw) return null;
  const parts = raw.split('|');
  if (parts.length !== 5 && parts.length !== 6) return null;
  const gradeKey = compact(parts[0]);
  const courseKey = compact(parts[1]);
  const examTerm = compact(parts[2]);
  const school = compact(parts[3]);
  const year = Number.parseInt(compact(parts[4]), 10);
  const cellLabel = parts.length >= 6 ? compact(parts[5]) : '';
  if (!gradeKey || !courseKey || !examTerm || !school || !Number.isFinite(year)) {
    return null;
  }
  return {
    gradeKey,
    courseKey,
    examTerm,
    school,
    year,
    cellLabel,
  };
}

export function normalizeNaesinLinkKeyForCompare(rawKey) {
  const parsed = parseNaesinLinkKeyParts(rawKey);
  if (!parsed) return compact(rawKey).replace(/\|+$/, '');
  const schoolKey = canonicalMiddleSchoolKey(parsed.school) || parsed.school;
  const base = `${parsed.gradeKey}|${parsed.courseKey}|${parsed.examTerm}|${schoolKey}|${parsed.year}`;
  return parsed.cellLabel ? `${base}|${parsed.cellLabel}` : base;
}

function inferFromFilenames(doc) {
  const text = `${compact(doc?.source_filename)} ${compact(doc?.source_pdf_filename)}`.trim();
  if (!text) {
    return { schoolKey: '', grade: 0, semester: 0, examTerm: '', examYear: 0 };
  }
  const schoolKey = canonicalMiddleSchoolKey(text);

  let examYear = 0;
  const year4Match = text.match(/(20\d{2})\s*(?:년|학년도)?/);
  if (year4Match) {
    examYear = Number.parseInt(year4Match[1], 10);
  } else {
    const year2Match = text.match(/(?:^|\D)(2[1-9])\s*(?:년|학년도|\s)/);
    if (year2Match) {
      examYear = 2000 + Number.parseInt(year2Match[1], 10);
    }
  }

  let grade = 0;
  const gradeMatch =
    text.match(/중\s*([123])/) ||
    text.match(/([123])\s*학년/) ||
    text.match(/중등수학\s*([123])/);
  if (gradeMatch) {
    grade = Number.parseInt(gradeMatch[1], 10);
  }

  let semester = 0;
  const semMatch = text.match(/([12])\s*학기/);
  if (semMatch) {
    semester = Number.parseInt(semMatch[1], 10);
  } else {
    const sangHaMatch = text.match(/중등수학\s*[123]\s*(상|하)/);
    if (sangHaMatch) {
      semester = sangHaMatch[1] === '하' ? 2 : 1;
    }
  }

  let examTerm = '';
  if (text.includes('중간')) examTerm = '중간고사';
  else if (text.includes('기말')) examTerm = '기말고사';

  return { schoolKey, grade, semester, examTerm, examYear };
}

export function resolveMiddleSchoolNaesinMeta(doc, { fallbackLinkKey = '' } = {}) {
  const parsedLink = parseNaesinLinkKeyParts(fallbackLinkKey);
  const naesinMeta =
    doc?.meta?.source_classification?.naesin &&
    typeof doc.meta.source_classification.naesin === 'object'
      ? doc.meta.source_classification.naesin
      : {};
  const fromFile = inferFromFilenames(doc);

  const schoolKey =
    canonicalMiddleSchoolKey(doc?.school_name) ||
    canonicalMiddleSchoolKey(naesinMeta.school_name) ||
    canonicalMiddleSchoolKey(parsedLink?.school) ||
    fromFile.schoolKey;
  const schoolInfo = MIDDLE_SCHOOL_TEMPLATE_MAP[schoolKey];
  if (!schoolInfo) return null;

  let grade = 0;
  const rawGradeKey = compact(doc?.grade_key || naesinMeta.grade_key || parsedLink?.gradeKey);
  const gradeKeyMatch = rawGradeKey.match(/^M([123])$/i);
  if (gradeKeyMatch) {
    grade = Number.parseInt(gradeKeyMatch[1], 10);
  }
  if (!grade) {
    const rawGradeLabel = compact(doc?.grade_label || naesinMeta.grade);
    const gradeLabelMatch = rawGradeLabel.match(/([123])/);
    if (gradeLabelMatch) {
      grade = Number.parseInt(gradeLabelMatch[1], 10);
    }
  }
  if (!grade && fromFile.grade) {
    grade = fromFile.grade;
  }
  if (grade < 1 || grade > 3) return null;
  const gradeKey = `M${grade}`;

  let semester = 0;
  const rawCourseKey = compact(doc?.course_key || naesinMeta.course_key || parsedLink?.courseKey);
  const courseKeyMatch = rawCourseKey.match(/^M[123]-([12])$/i);
  if (courseKeyMatch) {
    semester = Number.parseInt(courseKeyMatch[1], 10);
  }
  if (!semester) {
    const rawSem = compact(doc?.semester_label || naesinMeta.semester);
    const semMatch = rawSem.match(/([12])/);
    if (semMatch) {
      semester = Number.parseInt(semMatch[1], 10);
    }
  }
  if (!semester && fromFile.semester) {
    semester = fromFile.semester;
  }
  if (semester !== 1 && semester !== 2) return null;
  const courseKey = `M${grade}-${semester}`;

  let examTerm = '';
  const rawTerm = compact(doc?.exam_term_label || naesinMeta.exam_term || parsedLink?.examTerm);
  if (rawTerm.includes('중간')) examTerm = '중간고사';
  else if (rawTerm.includes('기말')) examTerm = '기말고사';
  else if (fromFile.examTerm) examTerm = fromFile.examTerm;
  if (!examTerm) return null;
  const shortTerm = examTerm.includes('중간') ? '중간' : '기말';

  let examYear =
    Number.parseInt(compact(doc?.exam_year ?? naesinMeta.year ?? parsedLink?.year), 10) ||
    fromFile.examYear;
  if (!Number.isFinite(examYear) || examYear < 2000 || examYear > 2100) {
    return null;
  }

  const curriculumCode =
    compact(doc?.curriculum_code) === 'rev_2015' ? 'rev_2015' : 'rev_2022';

  const canonicalLinkKey = `${gradeKey}|${courseKey}|${examTerm}|${schoolKey}|${examYear}`;
  const effectiveLinkKey =
    parsedLink &&
    normalizeNaesinLinkKeyForCompare(fallbackLinkKey) === canonicalLinkKey
      ? compact(fallbackLinkKey)
      : canonicalLinkKey;

  const displayName = `${examYear} ${schoolKey} ${grade}학년 ${semester}학기 ${shortTerm}`;
  const coverExamTitle = `${examYear}학년도 ${grade}학년 ${semester}학기 ${shortTerm}시험`;
  const headerExamTitle = `제 ${grade} 학년 ${semester} 학기 ${shortTerm}시험`;

  return {
    schoolKey,
    schoolInfo,
    grade,
    gradeKey,
    semester,
    courseKey,
    examTerm,
    shortTerm,
    examYear,
    curriculumCode,
    naesinLinkKey: effectiveLinkKey,
    canonicalLinkKey,
    displayName,
    coverExamTitle,
    headerExamTitle,
  };
}

function originalQuestionModeOfRow(row) {
  const qType = compact(row?.question_type);
  if (qType.includes('서술')) return 'essay';
  if (qType.includes('객관식')) return 'objective';
  if (qType.includes('주관식')) return 'subjective';
  if (row?.allow_objective === true && row?.allow_subjective === false) {
    return 'objective';
  }
  if (row?.allow_objective === false && row?.allow_subjective === true) {
    return 'subjective';
  }
  const choices = Array.isArray(row?.choices) ? row.choices : [];
  return choices.length >= 2 ? 'objective' : 'subjective';
}

function scorePointOfRow(row) {
  const meta = row?.meta && typeof row.meta === 'object' ? row.meta : {};
  if (Array.isArray(meta.score_parts) && meta.score_parts.length > 0) {
    let sum = 0;
    for (const part of meta.score_parts) {
      const val = Number(part?.value ?? part?.score);
      if (Number.isFinite(val) && val > 0) sum += val;
    }
    if (sum > 0) {
      return Math.round(sum * 100) / 100;
    }
  }
  const direct = Number(meta.score_point ?? meta.scorePoint ?? row?.score_point);
  if (Number.isFinite(direct) && direct > 0) {
    return Math.round(direct * 100) / 100;
  }
  return null;
}

export function sortDocumentQuestionsForPreset(rows) {
  return [...(rows || [])].sort((a, b) => {
    const na = Number.parseInt(compact(a?.question_number), 10);
    const nb = Number.parseInt(compact(b?.question_number), 10);
    if (Number.isFinite(na) && Number.isFinite(nb) && na !== nb) {
      return na - nb;
    }
    return Number(a?.source_order || 0) - Number(b?.source_order || 0);
  });
}

export function buildMiddleSchoolPresetPayload({
  academyId,
  sourceDocumentId,
  meta,
  orderedQuestions = [],
  existingPreset = null,
  preserveCustomLayout = true,
}) {
  const existingRc =
    existingPreset?.render_config && typeof existingPreset.render_config === 'object'
      ? existingPreset.render_config
      : {};
  const existingProfile = compact(existingRc.templateProfile).toLowerCase();
  const isAlreadyTargetSchoolProfile =
    existingProfile === meta.schoolInfo.templateProfile;
  const shouldKeepUserCustom = preserveCustomLayout && isAlreadyTargetSchoolProfile;

  const selectedQuestionIds = [];
  const selectedQuestionUids = [];
  const questionModeByQuestionUid = {};
  const questionScoreByQuestionUid = {};

  if (Array.isArray(orderedQuestions) && orderedQuestions.length > 0) {
    for (const row of orderedQuestions) {
      const id = compact(row?.id);
      const uid = compact(row?.question_uid) || id;
      if (!id || !uid) continue;
      selectedQuestionIds.push(id);
      selectedQuestionUids.push(uid);
      questionModeByQuestionUid[uid] = originalQuestionModeOfRow(row);
      const score = scorePointOfRow(row);
      if (score !== null) {
        questionScoreByQuestionUid[uid] = score;
      }
    }
  } else if (existingPreset) {
    const existingUids = Array.isArray(existingPreset.selected_question_uids)
      ? existingPreset.selected_question_uids.map(compact).filter(Boolean)
      : [];
    const existingIds = Array.isArray(existingPreset.selected_question_ids)
      ? existingPreset.selected_question_ids.map(compact).filter(Boolean)
      : existingUids;
    selectedQuestionUids.push(...existingUids);
    selectedQuestionIds.push(...(existingIds.length > 0 ? existingIds : existingUids));
    const existingScores =
      existingRc.questionScoreByQuestionUid ||
      existingRc.questionScoreByQuestionId ||
      {};
    if (existingScores && typeof existingScores === 'object') {
      Object.assign(questionScoreByQuestionUid, existingScores);
    }
  }

  const pageColumnQuestionCounts =
    shouldKeepUserCustom && Array.isArray(existingRc.pageColumnQuestionCounts)
      ? existingRc.pageColumnQuestionCounts
      : [];

  const includeCoverPage = shouldKeepUserCustom && typeof existingRc.includeCoverPage === 'boolean'
    ? existingRc.includeCoverPage
    : meta.schoolInfo.includeCoverPage;

  const includeCoverBlankPage =
    shouldKeepUserCustom && typeof existingRc.includeCoverBlankPage === 'boolean'
      ? existingRc.includeCoverBlankPage
      : meta.schoolInfo.includeCoverBlankPage;

  const existingCoverTexts =
    shouldKeepUserCustom &&
    existingRc.coverPageTexts &&
    typeof existingRc.coverPageTexts === 'object'
      ? existingRc.coverPageTexts
      : {};

  // CSAT 전용 키(organization, electiveItems, subjectGroups, handwritingPhrase 등)는 제거하고
  // 학교 시험지에 쓰이는 표지 키만 유지한다.
  const allowedSchoolCoverKeys = [
    'examDate',
    'coverExamTitle',
    'headerExamTitle',
    'subjectName',
    'objectiveCount',
    'subjectiveCount',
    'essayCount',
    'objectiveScore',
    'essayScore',
    'totalPageCount',
    'footerLabel',
    'pageStartNumber',
    'periodLabel',
    'subjectCode',
    'sheetTypeLabel',
  ];
  const preservedSchoolCoverTexts = {};
  for (const key of allowedSchoolCoverKeys) {
    const val = compact(existingCoverTexts[key]);
    if (val && val !== 'null' && val !== 'undefined') {
      preservedSchoolCoverTexts[key] = val;
    }
  }

  const coverPageTexts = {
    coverExamTitle: meta.coverExamTitle,
    headerExamTitle: meta.headerExamTitle,
    subjectName: '수학',
    ...preservedSchoolCoverTexts,
    includeCoverBlankPage,
  };

  const timeLimitText = compact(existingRc.timeLimitText) || '45';
  const includeAnswerSheet = existingRc.includeAnswerSheet === true;
  const includeExplanation = existingRc.includeExplanation === true;
  const includeQuestionScore =
    typeof existingRc.includeQuestionScore === 'boolean'
      ? existingRc.includeQuestionScore
      : true;

  const renderConfig = {
    renderConfigVersion: 4,
    presetKind: 'settings',
    templateProfile: meta.schoolInfo.templateProfile,
    paperSize: 'B4',
    font: {
      family: 'KoPubWorldBatangPro',
      size: 11.0,
    },
    layoutColumns: 2,
    maxQuestionsPerPage: 4,
    layoutMode: 'custom_columns',
    columnQuestionCounts: [],
    pageColumnQuestionCounts,
    columnLabelAnchors: [],
    titlePageIndices: [1],
    titlePageHeaders: [],
    titlePageTopText: meta.coverExamTitle,
    titlePageGoalText: '다시 풀기',
    subjectTitleText: '수학 영역',
    timeLimitText,
    includeAcademyLogo: false,
    includeCoverPage,
    includeCoverBlankPage,
    coverPageTexts,
    includeAnswerSheet,
    includeExplanation,
    includeQuestionScore,
    alignPolicy: {
      pairAlignment: 'row',
      skipAnchorRows: true,
    },
    questionNumberPlacement: 'inline',
    questionNumberFormat: 'source',
    renumberQuestions: true,
    mathEngine: 'xelatex-v2',
    disableAutoLabels: true,
    previewIndependentSetCommonStem: true,
    questionMode: 'original',
    naesinLinkKey: meta.naesinLinkKey,
    naesinCurriculumCode: meta.curriculumCode,
    naesinOriginalModePolicyVersion: 1,
    selectedQuestionUidsOrdered: selectedQuestionUids,
    selectedQuestionIdsOrdered: selectedQuestionIds,
    questionModeByQuestionUid,
    questionModeByQuestionId: questionModeByQuestionUid,
    questionScoreByQuestionUid,
    questionScoreByQuestionId: questionScoreByQuestionUid,
  };

  const cleanSourceDocId =
    compact(sourceDocumentId) || compact(existingPreset?.source_document_id);

  return {
    academy_id: compact(academyId || existingPreset?.academy_id),
    source_document_id: cleanSourceDocId || null,
    document_id: null,
    source_document_ids: cleanSourceDocId ? [cleanSourceDocId] : [],
    preset_kind: 'settings',
    display_name: meta.displayName,
    render_config: renderConfig,
    selected_question_uids: selectedQuestionUids,
    selected_question_ids: selectedQuestionIds,
    question_mode_by_question_uid: questionModeByQuestionUid,
    question_mode_by_question_id: questionModeByQuestionUid,
  };
}

export async function syncMiddleSchoolPresetForDocument(
  supa,
  documentId,
  { preserveCustomLayout = true } = {},
) {
  const cleanDocId = compact(documentId);
  if (!cleanDocId) return { synced: false, reason: 'missing_document_id' };

  const { data: doc, error: docErr } = await supa
    .from('pb_documents')
    .select(
      [
        'id',
        'academy_id',
        'status',
        'source_filename',
        'source_pdf_filename',
        'curriculum_code',
        'source_type_code',
        'school_level',
        'grade_key',
        'course_key',
        'course_label',
        'grade_label',
        'exam_year',
        'semester_label',
        'exam_term_label',
        'school_name',
        'meta',
      ].join(','),
    )
    .eq('id', cleanDocId)
    .maybeSingle();
  if (docErr) {
    throw new Error(`naesin_preset_doc_fetch_failed:${docErr.message}`);
  }
  if (!doc) return { synced: false, reason: 'document_not_found' };

  const sourceType = compact(doc.source_type_code);
  if (sourceType && sourceType !== 'school_past') {
    return { synced: false, reason: 'not_school_past' };
  }

  const { data: existingRows, error: exErr } = await supa
    .from('pb_export_presets')
    .select('*')
    .eq('academy_id', doc.academy_id)
    .eq('preset_kind', 'settings');
  if (exErr) {
    throw new Error(`naesin_preset_existing_fetch_failed:${exErr.message}`);
  }

  const byDoc = (existingRows || []).find(
    (row) =>
      compact(row?.source_document_id) === cleanDocId ||
      (Array.isArray(row?.source_document_ids) &&
        row.source_document_ids.map(compact).includes(cleanDocId)),
  );

  const meta = resolveMiddleSchoolNaesinMeta(doc, {
    fallbackLinkKey: byDoc?.render_config?.naesinLinkKey || '',
  });
  if (!meta) {
    return { synced: false, reason: 'unrecognized_middle_school_meta' };
  }

  const existing =
    byDoc ||
    (existingRows || []).find(
      (row) =>
        normalizeNaesinLinkKeyForCompare(row?.render_config?.naesinLinkKey) ===
        meta.canonicalLinkKey,
    ) ||
    null;

  if (existing && !byDoc && existing.render_config?.naesinLinkKey) {
    meta.naesinLinkKey = compact(existing.render_config.naesinLinkKey);
  }

  const { data: qRows, error: qErr } = await supa
    .from('pb_questions')
    .select(
      'id, question_uid, document_id, question_number, source_order, question_type, choices, allow_objective, allow_subjective, meta, is_published',
    )
    .eq('academy_id', doc.academy_id)
    .eq('document_id', cleanDocId)
    .eq('is_published', true);
  if (qErr) {
    throw new Error(`naesin_preset_questions_fetch_failed:${qErr.message}`);
  }

  const orderedQuestions = sortDocumentQuestionsForPreset(qRows || []);
  if (orderedQuestions.length === 0) {
    return { synced: false, reason: 'no_published_questions' };
  }

  const payload = buildMiddleSchoolPresetPayload({
    academyId: doc.academy_id,
    sourceDocumentId: cleanDocId,
    meta,
    orderedQuestions,
    existingPreset: existing,
    preserveCustomLayout,
  });

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
      .eq('academy_id', doc.academy_id)
      .eq('id', existing.id)
      .select('id, display_name')
      .single();
    if (upErr) {
      throw new Error(`naesin_preset_update_failed:${upErr.message}`);
    }
    return {
      synced: true,
      mode: 'updated',
      preset: updated,
      templateProfile: meta.schoolInfo.templateProfile,
      naesinLinkKey: meta.naesinLinkKey,
    };
  }

  const { data: inserted, error: inErr } = await supa
    .from('pb_export_presets')
    .insert(payload)
    .select('id, display_name')
    .single();
  if (inErr) {
    throw new Error(`naesin_preset_insert_failed:${inErr.message}`);
  }
  return {
    synced: true,
    mode: 'inserted',
    preset: inserted,
    templateProfile: meta.schoolInfo.templateProfile,
    naesinLinkKey: meta.naesinLinkKey,
  };
}
