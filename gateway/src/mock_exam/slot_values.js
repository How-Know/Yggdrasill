// 같은 문항은 문제은행 문항 하나로 두고, 시험지마다 다른 값은 실린 자리(mock_exam_items)에 둔다.
// 이 파일은 자리 값을 문항에 입혀 "그 시험지에 인쇄된 모습"을 만드는 순수 함수들이다.
// 설계: docs/architecture/mock-exam.md "One question, many slots".
//
// 자리 값은 문항과 다를 때만 있다. 값이 없으면 문항을 그대로 돌려준다.
//   number      : 이 시험지의 문항 번호
//   score       : 이 시험지의 배점
//   stem        : 이 시험지에 인쇄된 본문
//   choiceOrder : 이 시험지의 선지 순서. choiceOrder[i] = "이 시험지의 (i+1)번 선지는 문항의 몇 번 선지인가"

const CIRCLED = '\u2460\u2461\u2462\u2463\u2464\u2465\u2466\u2467\u2468\u2469';

const compact = (v) => String(v ?? '').trim();

/** "④", "4", "(4)" → 4. 선지 번호가 아니면 0. */
export function choiceIndexOf(label) {
  const src = compact(label);
  if (!src) return 0;
  const circled = CIRCLED.indexOf(src[0]);
  if (circled >= 0 && src.length === 1) return circled + 1;
  const m = /^\(?([1-9])\)?$/.exec(src);
  return m ? Number(m[1]) : 0;
}

/** 선지 순서로 쓸 수 있는가: 1..n 을 한 번씩 담은 배열. */
export function isChoiceOrder(order, count) {
  if (!Array.isArray(order) || order.length < 2) return false;
  if (Number.isFinite(count) && order.length !== count) return false;
  const seen = new Set(order.map((v) => Number(v)));
  if (seen.size !== order.length) return false;
  for (let i = 1; i <= order.length; i += 1) {
    if (!seen.has(i)) return false;
  }
  return true;
}

const isIdentityOrder = (order) => order.every((v, i) => Number(v) === i + 1);

/**
 * 문항의 선지를 이 시험지의 순서로 놓는다. 번호(①②…)는 자리에 남고 내용만 옮긴다.
 * 순서가 선지 수와 맞지 않으면 문항의 선지를 그대로 돌려준다.
 */
export function reorderChoices(choices, order) {
  const rows = Array.isArray(choices) ? choices : [];
  if (!isChoiceOrder(order, rows.length) || isIdentityOrder(order)) return rows;
  return rows.map((row, i) => ({ ...rows[Number(order[i]) - 1], label: row?.label }));
}

/**
 * 문항의 정답 번호를 이 시험지의 번호로 바꾼다("②" + [5,4,3,2,1] → "④").
 * 표기 모양(동그라미 숫자 / 숫자)은 그대로 둔다. 선지 번호가 아닌 답(주관식 값)은 그대로 돌려준다.
 */
export function remapAnswerKey(answerKey, order) {
  const src = compact(answerKey);
  if (!Array.isArray(order) || !isChoiceOrder(order) || isIdentityOrder(order)) return src;
  const original = choiceIndexOf(src);
  if (!original) return src;
  const slotIndex = order.findIndex((v) => Number(v) === original) + 1;
  if (!slotIndex) return src;
  if (CIRCLED.includes(src[0])) return CIRCLED[slotIndex - 1];
  return src.replace(/[1-9]/, String(slotIndex));
}

/** 자리 값을 문항 한 건에 입힌다. 원본 객체는 바꾸지 않는다. */
export function applySlotValuesToQuestion(question, slot = {}) {
  if (!question || typeof question !== 'object') return question;
  const number = compact(slot.number);
  const stem = compact(slot.stem);
  const score = Number(slot.score);
  const hasScore = slot.score !== null && slot.score !== undefined && Number.isFinite(score) && score > 0;
  const order = Array.isArray(slot.choiceOrder) ? slot.choiceOrder.map((v) => Number(v)) : null;
  const choiceCount = Array.isArray(question.choices) ? question.choices.length : 0;
  const useOrder = Boolean(order) && isChoiceOrder(order, choiceCount) && !isIdentityOrder(order);
  if (!number && !stem && !hasScore && !useOrder) return question;

  const out = { ...question };
  if (number) out.question_number = number;
  if (stem) out.stem = stem;
  const meta = question.meta && typeof question.meta === 'object' ? { ...question.meta } : {};
  if (hasScore) meta.score_point = score;
  if (useOrder) {
    out.choices = reorderChoices(question.choices, order);
    if (Array.isArray(question.objective_choices) && question.objective_choices.length === choiceCount) {
      out.objective_choices = reorderChoices(question.objective_choices, order);
    }
    if (question.objective_answer_key !== undefined) {
      out.objective_answer_key = remapAnswerKey(question.objective_answer_key, order);
    }
    for (const key of ['objective_answer_key', 'answer_key']) {
      if (typeof meta[key] === 'string') meta[key] = remapAnswerKey(meta[key], order);
    }
  }
  out.meta = meta;
  return out;
}

/**
 * 다른 구간의 문항을 가리키는 자리(merged_at 이 있는 mock_exam_items 행)를
 * 그 시험지의 문항 목록에 넣을 행으로 만든다. 자리 번호를 question_number 로 싣고 자리 값을 __slot 에 둔다.
 */
export function slotQuestionRow(item, question) {
  if (!item || !question) return null;
  const number = Number(item.problem_number);
  if (!Number.isFinite(number) || number <= 0) return null;
  const order = Array.isArray(item.choice_order) ? item.choice_order.map((v) => Number(v)) : null;
  const score = Number(item.score);
  return {
    ...question,
    question_number: String(number),
    __slot: {
      number: String(number),
      score: item.score !== null && item.score !== undefined && Number.isFinite(score) && score > 0 ? score : null,
      stem: compact(item.stem_override) || null,
      choiceOrder: order && order.length >= 2 ? order : null,
    },
  };
}
