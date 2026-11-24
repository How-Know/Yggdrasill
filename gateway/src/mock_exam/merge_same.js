// 가형·나형에 같이 실린 문항을 문항 하나로 합친다 (docs/architecture/mock-exam.md "One question, many slots").
// 한 구간이 문항을 갖고, 다른 구간의 자리(mock_exam_items)는 그 문항을 가리킨다. 가리키는 쪽에 있던
// 중복 문항과 그 검수 기록은 지운다(지우기 전에 파일로 남긴다).
// 여기는 판단(무엇을 어떻게 바꿀지)과 실행을 나눈다. 판단은 DB 를 읽지도 쓰지도 않는다.

import { normalizeForMatch } from './legacy_links.js';
import { choiceIndexOf, isChoiceOrder } from './slot_values.js';

const compact = (v) => String(v ?? '').trim();

/** 중복 문항을 지우기 전에 남겨 둘 표. 문항이나 크롭을 지우면 함께 지워지거나 비워지는 것들이다. */
export const MERGE_BACKUP_BY_QUESTION = [
  ['pb_question_meta', 'question_id'],
  ['pb_question_solutions', 'question_id'],
  ['pb_delivery_units', 'question_id'],
  ['pb_question_revisions', 'question_id'],
  ['pb_figure_jobs', 'question_id'],
  ['pb_question_foundation_links', 'question_id'],
  ['textbook_crop_question_links', 'pb_question_id'],
  ['question_render_assets', 'pb_question_id'],
  ['question_render_jobs', 'pb_question_id'],
];
export const MERGE_BACKUP_BY_CROP = [
  ['textbook_problem_analyses', 'crop_id'],
  ['textbook_problem_answers', 'crop_id'],
  ['textbook_problem_solution_refs', 'crop_id'],
  ['textbook_review_decisions', 'crop_id'],
  ['textbook_review_findings', 'crop_id'],
  ['textbook_answer_render_assets', 'crop_id'],
];

/** 학생·숙제 기록이 있으면 합치지 않는다. [표, 컬럼, 무엇으로 찾는가]. */
export const MERGE_RECORD_CHECKS = [
  ['learning_attempts', 'pb_question_uid', 'uid'],
  ['learning_exposures', 'pb_question_uid', 'uid'],
  ['homework_item_problems', 'pb_question_uid', 'uid'],
  ['homework_assignment_problems', 'pb_question_uid', 'uid'],
  ['homework_test_grading_attempt_items', 'question_uid', 'uid'],
  ['student_foundation_observations', 'question_id', 'id'],
  ['pb_question_set_items', 'question_id', 'id'],
  ['pb_question_issue_reports', 'question_id', 'id'],
  ['learning_problem_bank_question_orders', 'question_id', 'id'],
  ['learning_attempts', 'crop_id', 'crop'],
  ['learning_exposures', 'crop_id', 'crop'],
  ['homework_item_problems', 'crop_id', 'crop'],
  ['homework_assignment_problems', 'crop_id', 'crop'],
  ['student_textbook_answer_records', 'crop_id', 'crop'],
  ['student_problem_rounds', 'crop_id', 'crop'],
  ['student_handwriting_samples', 'crop_id', 'crop'],
  ['student_textbook_problem_reports', 'crop_id', 'crop'],
];

const choiceValues = (question) =>
  (Array.isArray(question?.choices) ? question.choices : []).map((c) => normalizeForMatch(c?.text ?? ''));

/**
 * 자리의 선지 순서. order[i] = 자리의 i 번째 선지가 문항의 몇 번째 선지인가.
 * 순서가 같으면 null, 선지가 서로 짝지어지지 않으면 undefined.
 */
export function choiceOrderBetween(ownerQuestion, slotQuestion) {
  const owner = choiceValues(ownerQuestion);
  const slot = choiceValues(slotQuestion);
  if (owner.length < 2 || owner.length !== slot.length) return undefined;
  if (new Set(owner).size !== owner.length || owner.some((v) => !v)) return undefined;
  const order = slot.map((v) => owner.indexOf(v) + 1);
  if (!isChoiceOrder(order, owner.length)) return undefined;
  return order.every((v, i) => v === i + 1) ? null : order;
}

const scoreOf = (question) => {
  const score = Number(question?.meta?.score_point);
  return Number.isFinite(score) && score > 0 ? score : null;
};

/**
 * 연결된 두 자리(a, b)를 어떻게 합칠지 정한다.
 *   items      mock_exam_items 두 행 (id, section, problem_number, answer_kind, answer_text, pb_question_id, merged_at)
 *   questions  Map(문항 id → pb_questions 행: id, question_uid, document_id, stem, choices, subjective_answer, is_published, meta)
 *   pendingDocumentIds  아직 확정·공개 전인 구간 문서 id 묶음
 *   recordCounts        Map(문항 id → 학생·숙제 기록 수)
 *   cropIdByQuestionId  Map(문항 id → 검수 크롭 id)
 *   stagedStemByQuestionId  Map(문항 id → 검수의 반영 대기 본문). 있으면 문항 본문 대신 쓴다
 * 돌려주는 값: { status: 'merge' | 'done' | 'refused', reasons, notes, owner, slot, duplicate, set }
 */
export function planSameQuestionMerge({
  a,
  b,
  questions,
  pendingDocumentIds,
  recordCounts = new Map(),
  cropIdByQuestionId = new Map(),
  stagedStemByQuestionId = new Map(),
}) {
  // 검수가 고쳐 둔 본문(반영 대기)은 확정 때 문항에 쓰인다. 지워질 문항의 것은 크롭과 함께 사라지므로
  // 자리에 옮길 본문은 반영 대기 값을 먼저 쓴다(2020 수능 가형 26번: 곧은 글자로 고친 본문이 빠졌었다).
  const stemOf = (question) => {
    const staged = stagedStemByQuestionId.get(compact(question?.id));
    return typeof staged === 'string' && staged.trim() ? staged : String(question?.stem ?? '');
  };
  const formDiffers = compact(a?.answer_kind) !== compact(b?.answer_kind);
  // 형식이 다르면 선지가 인쇄된 객관식 쪽이, 같으면 가형이 문항을 갖는다.
  const ownerItem = formDiffers
    ? (compact(a?.answer_kind) === 'objective' ? a : b)
    : (compact(a?.section) === 'ga' ? a : b);
  const slotItem = ownerItem === a ? b : a;
  const describe = (item) => ({
    itemId: compact(item?.id),
    section: compact(item?.section),
    number: Number(item?.problem_number),
    answerKind: compact(item?.answer_kind),
    questionId: compact(item?.pb_question_id),
  });
  const plan = {
    status: 'merge',
    reasons: [],
    notes: [],
    formDiffers,
    owner: describe(ownerItem),
    slot: describe(slotItem),
    duplicate: null,
    set: null,
  };
  const refuse = (reason) => {
    plan.status = 'refused';
    plan.reasons.push(reason);
  };

  if (a?.merged_at || b?.merged_at) {
    plan.status = 'done';
    return plan;
  }
  const owner = questions.get(plan.owner.questionId);
  const duplicate = questions.get(plan.slot.questionId);
  if (!owner || !duplicate) {
    refuse('문항이 없는 자리가 있음');
    return plan;
  }
  if (owner.id === duplicate.id) {
    refuse('두 자리가 이미 같은 문항을 가리키는데 합친 표시가 없음');
    return plan;
  }
  plan.duplicate = {
    questionId: compact(duplicate.id),
    questionUid: compact(duplicate.question_uid),
    cropId: compact(cropIdByQuestionId.get(compact(duplicate.id))),
  };

  for (const q of [owner, duplicate]) {
    if (q.is_published === true || !pendingDocumentIds.has(compact(q.document_id))) {
      refuse('확정·공개된 구간이 있음');
      break;
    }
  }
  const records = Number(recordCounts.get(compact(duplicate.id)) || 0);
  if (records > 0) refuse(`지워질 문항에 학생·숙제 기록 ${records}건이 있음`);

  let choiceOrder = null;
  if (plan.slot.answerKind === 'objective') {
    const order = choiceOrderBetween(owner, duplicate);
    if (order === undefined) {
      refuse('두 시험지의 선지가 서로 짝지어지지 않음');
    } else {
      choiceOrder = order;
      const ownerAnswer = choiceIndexOf(ownerItem.answer_text);
      const slotAnswer = choiceIndexOf(slotItem.answer_text);
      const expected = order ? order[slotAnswer - 1] : slotAnswer;
      if (!ownerAnswer || !slotAnswer || expected !== ownerAnswer) {
        refuse('선지 순서로 옮긴 정답 번호가 그 시험지의 정답과 다름');
      }
    }
  } else if (plan.owner.answerKind === 'objective') {
    // 객관식 문항을 단답형 자리가 가리킨다: 문항의 주관식 답이 그 시험지의 답과 같아야 한다.
    const slotAnswer = normalizeForMatch(slotItem.answer_text);
    const ownerSubjective = normalizeForMatch(owner.subjective_answer);
    if (!ownerSubjective) plan.notes.push('문항에 주관식 답이 비어 있음(단답형으로 낼 때 자리의 답을 써야 함)');
    else if (ownerSubjective !== slotAnswer) refuse('문항의 주관식 답이 단답형 시험지의 답과 다름');
  }

  const stemDiffers = normalizeForMatch(stemOf(owner)) !== normalizeForMatch(stemOf(duplicate));
  // 자리에 둔 본문의 [그림] 은 문항의 그림으로 찍힌다. 그림 표시 수가 다르면 그림이 어긋난다.
  const figureMarks = (stem) => (String(stem ?? '').match(/\[그림[^\]\n]*\]/g) || []).length;
  if (stemDiffers && figureMarks(stemOf(owner)) !== figureMarks(stemOf(duplicate))) {
    refuse('두 시험지 본문의 그림 표시 수가 다름');
  }
  const ownerScore = scoreOf(owner);
  const slotScore = scoreOf(duplicate);
  if (slotScore === null) plan.notes.push('지워질 문항에 배점이 없어 문항의 배점을 따름');
  plan.set = {
    pb_question_id: compact(owner.id),
    score: slotScore !== null && slotScore !== ownerScore ? slotScore : null,
    choice_order: choiceOrder,
    stem_override: stemDiffers ? stemOf(duplicate) : null,
  };
  plan.scores = { owner: ownerScore, slot: slotScore };
  return plan;
}

async function rowsOf(supa, table, column, value) {
  const { data, error } = await supa.from(table).select('*').eq(column, value);
  if (error) throw new Error(`merge_backup_failed:${table}:${error.message}`);
  return data || [];
}

/** 합치기 전에 남길 기록: 자리의 이전 값, 중복 문항과 크롭, 함께 지워질 행들. */
export async function collectMergeBackup(supa, plan) {
  const backup = { plan, takenAt: new Date().toISOString(), tables: {} };
  const put = (table, rows) => {
    if (rows.length > 0) backup.tables[table] = [...(backup.tables[table] || []), ...rows];
  };
  put('mock_exam_items', await rowsOf(supa, 'mock_exam_items', 'id', plan.slot.itemId));
  put('pb_questions', await rowsOf(supa, 'pb_questions', 'id', plan.duplicate.questionId));
  for (const [table, column] of MERGE_BACKUP_BY_QUESTION) {
    put(table, await rowsOf(supa, table, column, plan.duplicate.questionId));
  }
  if (plan.duplicate.cropId) {
    put('textbook_problem_crops', await rowsOf(supa, 'textbook_problem_crops', 'id', plan.duplicate.cropId));
    for (const [table, column] of MERGE_BACKUP_BY_CROP) {
      put(table, await rowsOf(supa, table, column, plan.duplicate.cropId));
    }
  }
  return backup;
}

/**
 * 계획 하나를 실행한다. 순서: 자리를 문항으로 돌린다 → 중복 크롭을 지운다 → 중복 문항을 지운다.
 * 중간에 멈추면 자리는 이미 맞는 문항을 가리키고 중복 문항만 남는다. 남은 중복은
 * scripts/mock_exam_merge_same.mjs 가 찾아 알려 주고, --apply 로 다시 실행하면 지운다(removeDuplicate).
 */
export async function applyMergePlan(supa, plan, { now = () => new Date().toISOString() } = {}) {
  if (plan?.status !== 'merge' || !plan.set || !plan.duplicate?.questionId) {
    throw new Error('merge_plan_not_applicable');
  }
  const { data: updated, error: slotErr } = await supa
    .from('mock_exam_items')
    .update({ ...plan.set, merged_at: now() })
    .eq('id', plan.slot.itemId)
    .eq('pb_question_id', plan.duplicate.questionId)
    .select('id');
  if (slotErr) throw new Error(`merge_slot_update_failed:${slotErr.message}`);
  if (!updated || updated.length !== 1) throw new Error('merge_slot_changed_since_plan');
  await removeDuplicate(supa, plan.duplicate);
  return { slotItemId: plan.slot.itemId, removedQuestionId: plan.duplicate.questionId };
}

/** 되돌릴 때 넣는 순서: 문항과 크롭 먼저, 그 뒤 그것을 가리키는 행. */
export const MERGE_RESTORE_ORDER = [
  'pb_questions',
  'textbook_problem_crops',
  'pb_question_meta',
  'pb_question_solutions',
  'pb_delivery_units',
  'pb_question_revisions',
  'pb_figure_jobs',
  'pb_question_foundation_links',
  'textbook_crop_question_links',
  'textbook_problem_analyses',
  'textbook_problem_answers',
  'textbook_problem_solution_refs',
  'textbook_review_findings',
  'textbook_review_decisions',
  'textbook_answer_render_assets',
  'question_render_jobs',
  'question_render_assets',
];

/** 기록 파일로 되돌릴 수 있는지 본다. 되돌릴 수 없으면 이유를 돌려준다. */
export async function checkMergeRestore(supa, backup) {
  const slotBefore = backup?.tables?.mock_exam_items?.[0];
  const question = backup?.tables?.pb_questions?.[0];
  if (!slotBefore || !question || !backup?.plan?.set) return '기록 파일에 자리나 문항이 없음';
  const { data: slots, error: slotErr } = await supa
    .from('mock_exam_items')
    .select('id, pb_question_id, merged_at')
    .eq('id', slotBefore.id);
  if (slotErr) throw new Error(`merge_restore_slot_fetch_failed:${slotErr.message}`);
  const slot = slots?.[0];
  if (!slot) return '자리가 없음';
  if (!slot.merged_at) return '자리가 합친 상태가 아님(이미 되돌렸거나 합친 적이 없음)';
  if (compact(slot.pb_question_id) !== compact(backup.plan.set.pb_question_id)) {
    return '자리가 합친 뒤에 다른 문항으로 바뀜';
  }
  const { data: existing, error: questionErr } = await supa.from('pb_questions').select('id').eq('id', question.id);
  if (questionErr) throw new Error(`merge_restore_question_fetch_failed:${questionErr.message}`);
  if ((existing || []).length > 0) return '지웠던 문항이 이미 있음';
  return '';
}

/**
 * 기록 파일로 합치기 전으로 되돌린다: 지운 문항·크롭·검수 기록을 다시 넣고, 자리를 예전 값으로 돌린다.
 * 문항을 넣을 때 DB 가 스스로 만드는 행(예: 배포 단위)과 겹치면 그 행은 건너뛰고 skipped 에 적는다.
 */
export async function restoreMergeBackup(supa, backup) {
  const reason = await checkMergeRestore(supa, backup);
  if (reason) throw new Error(`merge_restore_refused:${reason}`);
  const inserted = {};
  const skipped = {};
  for (const table of MERGE_RESTORE_ORDER) {
    const rows = backup.tables[table] || [];
    for (const row of rows) {
      const { error } = await supa.from(table).insert(row);
      if (!error) {
        inserted[table] = (inserted[table] || 0) + 1;
      } else if (compact(error.code) === '23505' && table !== 'pb_questions' && table !== 'textbook_problem_crops') {
        skipped[table] = (skipped[table] || 0) + 1;
      } else {
        throw new Error(`merge_restore_insert_failed:${table}:${error.message}`);
      }
    }
  }
  const before = backup.tables.mock_exam_items[0];
  const { error: slotErr } = await supa
    .from('mock_exam_items')
    .update({
      pb_question_id: before.pb_question_id,
      score: before.score ?? null,
      choice_order: before.choice_order ?? null,
      stem_override: before.stem_override ?? null,
      merged_at: null,
    })
    .eq('id', before.id);
  if (slotErr) throw new Error(`merge_restore_slot_update_failed:${slotErr.message}`);
  return { inserted, skipped };
}

/** 중복 문항과 그 검수 크롭을 지운다. 딸린 검수 기록은 DB 가 함께 지운다. */
export async function removeDuplicate(supa, duplicate) {
  if (duplicate?.cropId) {
    const { error: cropErr } = await supa.from('textbook_problem_crops').delete().eq('id', duplicate.cropId);
    if (cropErr) throw new Error(`merge_crop_delete_failed:${cropErr.message}`);
  }
  const { error: questionErr } = await supa.from('pb_questions').delete().eq('id', duplicate.questionId);
  if (questionErr) throw new Error(`merge_question_delete_failed:${questionErr.message}`);
}
