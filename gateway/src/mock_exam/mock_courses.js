// 모의고사 회차·구간에서 정해지는 값(이름, 교육과정, 검수 과정 라벨). DB·파일을 건드리지 않는다.

export const MOCK_ORG_LABELS = Object.freeze({ edu: '교육청', kice: '평가원', csat: '수능' });

/// "2025 고3 10월 교육청"
export function mockExamTitle(exam) {
  return `${exam.exam_year} 고${exam.grade} ${exam.exam_month}월 ${MOCK_ORG_LABELS[exam.org] || ''}`.trim();
}

/// 시행 연도로 정하는 교육과정(사장님 결정 2026-11-20): 고1은 2025년 시행분부터, 고2는 2026년 시행분부터 2022 개정.
/// 그 밖은 이전 교육과정이다. 고3은 2027년 시행분부터 시험 구성(선택과목)이 바뀌므로 그때 다시 정한다.
export function mockCurriculumCode(grade, examYear) {
  const g = Number(grade);
  const year = Number(examYear);
  if (g === 1 && year >= 2025) return 'rev_2022';
  if (g === 2 && year >= 2026) return 'rev_2022';
  return 'rev_2015';
}

const ELECTIVE_COURSE = Object.freeze({
  probstats: '확률과 통계',
  calculus: '미적분2',
  geometry: '기하',
});

/// 검수 과정 라벨: 개념 태그 후보를 고르는 과정들(concept_sources.grade_label)을 '+' 로 잇는다(사장님 결정 2026-11-20).
///   고3 공통(수학Ⅰ·Ⅱ) → 대수+미적분1, 확률과 통계 → 확률과 통계, 미적분 → 미적분2, 기하 → 기하
///   고2 3월 → 공통수학1+공통수학2, 고2 그 밖 → 대수+미적분1
///   고1 3월 → 중학교 1~3학년 전체, 고1 그 밖 → 공통수학1+공통수학2
/// 이전 교육과정 회차도 2022 개정의 대응 과정 개념을 후보로 쓴다.
export function mockReviewCourseLabel({ grade, examMonth, section }) {
  const g = Number(grade);
  const month = Number(examMonth);
  if (g === 3) return section === 'common' ? '대수+미적분1' : ELECTIVE_COURSE[section] || '';
  if (section !== 'common') return '';
  if (g === 2) return month === 3 ? '공통수학1+공통수학2' : '대수+미적분1';
  if (g === 1) return month === 3 ? '1-1+1-2+2-1+2-2+3-1+3-2' : '공통수학1+공통수학2';
  return '';
}
