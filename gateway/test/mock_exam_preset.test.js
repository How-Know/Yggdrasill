import test from 'node:test';
import assert from 'node:assert/strict';
import {
  GRADE3_MOCK_PAGE_COLUMN_COUNTS,
  buildGrade3ColumnLabelAnchors,
  buildMockExamLinkKey,
  buildMockExamPresetDisplayName,
  buildMockExamPresetPayload,
  buildMockExamTitlePageTopText,
  parseMockExamLinkKey,
} from '../src/mock_exam/mock_preset.js';

test('buildMockExamTitlePageTopText matches KICE, CSAT, and Education Office originals', () => {
  assert.equal(
    buildMockExamTitlePageTopText({ grade: 3, exam_year: 2025, school_year: 2026, exam_month: 11, org: 'csat' }),
    '2026학년도 대학수학능력시험 문제지',
  );
  assert.equal(
    buildMockExamTitlePageTopText({ grade: 3, exam_year: 2025, school_year: 2026, exam_month: 6, org: 'kice' }),
    '2026학년도 대학수학능력시험 6월 모의평가 문제지',
  );
  assert.equal(
    buildMockExamTitlePageTopText({ grade: 3, exam_year: 2025, school_year: 2026, exam_month: 9, org: 'kice' }),
    '2026학년도 대학수학능력시험 9월 모의평가 문제지',
  );
  assert.equal(
    buildMockExamTitlePageTopText({ grade: 3, exam_year: 2025, school_year: 2026, exam_month: 3, org: 'edu' }),
    '2025학년도 3월 고3 전국연합학력평가 문제지',
  );
  // 2024년 이후 고3 4월 학평은 원본 지면 상단이 5월 표기
  assert.equal(
    buildMockExamTitlePageTopText({ grade: 3, exam_year: 2025, school_year: 2026, exam_month: 4, org: 'edu' }),
    '2025학년도 5월 고3 전국연합학력평가 문제지',
  );
  // 7월 학평은 DB에 org='kice'로 들어와도 학력평가 양식
  assert.equal(
    buildMockExamTitlePageTopText({ grade: 3, exam_year: 2025, school_year: 2026, exam_month: 7, org: 'kice' }),
    '2025학년도 7월 고3 전국연합학력평가 문제지',
  );
  assert.equal(
    buildMockExamTitlePageTopText({ grade: 3, exam_year: 2025, school_year: 2026, exam_month: 10, org: 'edu' }),
    '2025학년도 10월 고3 전국연합학력평가 문제지',
  );
});

test('GRADE3_MOCK_PAGE_COLUMN_COUNTS sums to 22 common + 8 elective = 30 across 12 pages', () => {
  assert.equal(GRADE3_MOCK_PAGE_COLUMN_COUNTS.length, 12);
  const commonSum = GRADE3_MOCK_PAGE_COLUMN_COUNTS.slice(0, 8).reduce((acc, r) => acc + r.left + r.right, 0);
  const electiveSum = GRADE3_MOCK_PAGE_COLUMN_COUNTS.slice(8, 12).reduce((acc, r) => acc + r.left + r.right, 0);
  assert.equal(commonSum, 22);
  assert.equal(electiveSum, 8);
});

test('buildMockExamPresetPayload builds 30-item combined preset with fixed layout and anchors', () => {
  const exam = {
    id: 'e9297c64-ffd9-44d6-bc7c-d9b00665345a',
    academy_id: '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677',
    grade: 3,
    exam_year: 2025,
    school_year: 2026,
    exam_month: 11,
    org: 'csat',
  };
  const questions = Array.from({ length: 30 }, (_, idx) => {
    const num = idx + 1;
    return {
      id: `00000000-0000-4000-8000-${String(num).padStart(12, '0')}`,
      question_uid: `11111111-1111-4111-8111-${String(num).padStart(12, '0')}`,
      question_number: String(num),
      question_type: num <= 15 || (num >= 23 && num <= 28) ? '객관식' : '주관식',
      meta: { score_point: num === 1 || num === 2 || num === 23 ? 2 : 3 },
    };
  });

  const payload = buildMockExamPresetPayload({
    exam,
    elective: 'calculus',
    orderedQuestions: questions,
    commonDocumentId: '22222222-2222-4222-8222-000000000001',
    electiveDocumentId: '22222222-2222-4222-8222-000000000002',
  });

  assert.equal(payload.display_name, '2025 고3 11월 수능 (미적분)');
  assert.equal(payload.selected_question_uids.length, 30);
  assert.deepEqual(payload.source_document_ids, [
    '22222222-2222-4222-8222-000000000001',
    '22222222-2222-4222-8222-000000000002',
  ]);
  const rc = payload.render_config;
  assert.equal(rc.templateProfile, 'csat');
  assert.equal(rc.paperSize, '8절');
  assert.equal(rc.includeQuestionScore, true);
  assert.equal(rc.mockExamLinkKey, 'H3|2025|11|csat|calculus');
  assert.deepEqual(rc.titlePageIndices, [1, 9]);
  assert.deepEqual(rc.titlePageHeaders, [
    { page: 1, title: '수학 영역', subtitle: '' },
    { page: 9, title: '수학 영역', subtitle: '미적분' },
  ]);
  assert.equal(rc.pageColumnQuestionCounts.length, 12);

  // 15번 객관식, 16번 단답형, 28번 객관식, 29번 단답형 확인
  const uid15 = questions[14].question_uid;
  const uid16 = questions[15].question_uid;
  const uid28 = questions[27].question_uid;
  const uid29 = questions[28].question_uid;
  assert.equal(rc.questionModeByQuestionUid[uid15], 'objective');
  assert.equal(rc.questionModeByQuestionUid[uid16], 'subjective');
  assert.equal(rc.questionModeByQuestionUid[uid28], 'objective');
  assert.equal(rc.questionModeByQuestionUid[uid29], 'subjective');

  const parsedKey = parseMockExamLinkKey(rc.mockExamLinkKey);
  assert.deepEqual(parsedKey, {
    gradeKey: 'H3',
    grade: 3,
    examYear: 2025,
    examMonth: 11,
    org: 'csat',
    elective: 'calculus',
  });
});
