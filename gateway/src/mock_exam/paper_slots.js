// 가형·나형 시험지 한 부를 뽑을 때, 다른 구간의 문항을 가리키는 자리(mock_exam_items.merged_at)를
// 그 시험지의 번호·배점·형식·본문·선지 순서로 바꿔 준다.
// 설계: docs/architecture/mock-exam.md "One question, many slots".
//
// 어느 시험지를 뽑는지는 작업 옵션에 없다(앱마다 넘기는 값이 다르다). 그래서 뽑는 문항들로 판단한다:
//   - 모든 문항이 같은 회차의 가형·나형 문항이고
//   - 절반 넘는 문항이 한 구간(그 시험지)의 문항이며
//   - 나머지 문항이 모두 그 구간의 자리로 연결돼 있을 때
// 만 그 시험지로 본다. 여러 회차를 섞은 학습지나 연결이 없는 문항이 낀 묶음은 문항을 그대로 둔다.

import { LEGACY_TYPES } from './mock_pages.js';
import { applySlotValuesToQuestion } from './slot_values.js';

const compact = (v) => String(v ?? '').trim();

const ownSlotOf = (question) => {
  const ref = question?.meta?.mock_exam_item;
  if (!ref || typeof ref !== 'object') return null;
  const examId = compact(ref.exam_id);
  const section = compact(ref.section);
  return examId && section ? { examId, section } : null;
};

/**
 * 문항들이 가형·나형 시험지 한 부(또는 그 일부)인가. 맞으면 { examId, section, slotByQuestionId } 를,
 * 아니면 null 을 돌려준다. mergedSlots 는 그 회차의 merged_at 이 있는 mock_exam_items 행이다.
 */
export function inferMockPaper(questions, mergedSlots) {
  const rows = Array.isArray(questions) ? questions : [];
  if (rows.length === 0) return null;
  const counts = new Map();
  let examId = '';
  for (const q of rows) {
    const own = ownSlotOf(q);
    if (!own || !LEGACY_TYPES.includes(own.section)) return null;
    if (examId && own.examId !== examId) return null;
    examId = own.examId;
    counts.set(own.section, (counts.get(own.section) || 0) + 1);
  }
  if (counts.size < 2) return null;
  const [section, majority] = [...counts.entries()].sort((a, b) => b[1] - a[1])[0];
  if (majority * 2 <= rows.length) return null;

  const slotByQuestionId = new Map();
  for (const slot of mergedSlots || []) {
    if (compact(slot?.exam_id) !== examId || compact(slot?.section) !== section) continue;
    const questionId = compact(slot?.pb_question_id);
    if (questionId) slotByQuestionId.set(questionId, slot);
  }
  const used = new Map();
  for (const q of rows) {
    if (ownSlotOf(q).section === section) continue;
    const slot = slotByQuestionId.get(compact(q?.id));
    if (!slot) return null;
    used.set(compact(q.id), slot);
  }
  return { examId, section, slotByQuestionId: used };
}

/** 자리 한 행 → applySlotValuesToQuestion 에 줄 값. */
export function slotValuesOf(slot) {
  const score = Number(slot?.score);
  return {
    number: compact(slot?.problem_number),
    score: slot?.score !== null && slot?.score !== undefined && Number.isFinite(score) && score > 0 ? score : null,
    stem: compact(slot?.stem_override),
    choiceOrder: Array.isArray(slot?.choice_order) ? slot.choice_order.map((v) => Number(v)) : null,
  };
}

/**
 * 내보낼 문항들에 그 시험지의 자리 값을 입힌다.
 * 돌려주는 값: questions(입힌 문항), scoreByQuestionKey / modeByQuestionKey(작업 옵션의 uid·id 맵에 덮어쓸 값).
 * 가형·나형 문항이 아니거나 한 구간의 문항뿐이면 DB 를 읽지 않고 그대로 돌려준다.
 */
export async function applyMockPaperSlotValues({ supa, academyId, questions }) {
  const rows = Array.isArray(questions) ? questions : [];
  const unchanged = { questions: rows, scoreByQuestionKey: {}, modeByQuestionKey: {}, paper: null };
  const owns = rows.map(ownSlotOf);
  if (owns.length === 0 || owns.some((o) => !o || !LEGACY_TYPES.includes(o.section))) return unchanged;
  if (new Set(owns.map((o) => o.examId)).size !== 1 || new Set(owns.map((o) => o.section)).size < 2) {
    return unchanged;
  }
  const { data, error } = await supa
    .from('mock_exam_items')
    .select('exam_id, section, problem_number, pb_question_id, answer_kind, score, choice_order, stem_override')
    .eq('academy_id', academyId)
    .eq('exam_id', owns[0].examId)
    .not('merged_at', 'is', null);
  if (error) throw new Error(`mock_paper_slots_fetch_failed:${error.message}`);
  const paper = inferMockPaper(rows, data || []);
  if (!paper) return unchanged;

  const scoreByQuestionKey = {};
  const modeByQuestionKey = {};
  const out = rows.map((q) => {
    const slot = paper.slotByQuestionId.get(compact(q?.id));
    if (!slot) return q;
    const values = slotValuesOf(slot);
    const mode = compact(slot.answer_kind) === 'subjective' ? 'subjective' : 'objective';
    for (const key of [compact(q.question_uid), compact(q.id)]) {
      if (!key) continue;
      modeByQuestionKey[key] = mode;
      if (values.score) scoreByQuestionKey[key] = values.score;
    }
    return applySlotValuesToQuestion(q, values);
  });
  return { questions: out, scoreByQuestionKey, modeByQuestionKey, paper: { examId: paper.examId, section: paper.section } };
}
