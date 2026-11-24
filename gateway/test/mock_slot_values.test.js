import test from 'node:test';
import assert from 'node:assert/strict';

import {
  applySlotValuesToQuestion,
  choiceIndexOf,
  isChoiceOrder,
  remapAnswerKey,
  reorderChoices,
  slotQuestionRow,
} from '../src/mock_exam/slot_values.js';
import { applyMockPaperSlotValues, inferMockPaper } from '../src/mock_exam/paper_slots.js';
import { buildMockExamPresetPayload } from '../src/mock_exam/mock_preset.js';

const EXAM = 'exam-2020-11';
const circled = ['①', '②', '③', '④', '⑤'];
const choices = (texts) => texts.map((text, i) => ({ label: circled[i], text }));

function question(id, section, number, extra = {}) {
  return {
    id,
    question_uid: `uid-${id}`,
    question_number: String(number),
    stem: `${section} ${number}번 본문`,
    choices: choices(['1', '2', '3', '4', '5']),
    objective_answer_key: '②',
    meta: { score_point: 3, mock_exam_item: { exam_id: EXAM, section, item_id: `item-${id}` } },
    ...extra,
  };
}

test('선지 번호 읽기와 선지 순서 검사', () => {
  assert.equal(choiceIndexOf('④'), 4);
  assert.equal(choiceIndexOf('4'), 4);
  assert.equal(choiceIndexOf('36'), 0);
  assert.equal(choiceIndexOf(''), 0);
  assert.equal(isChoiceOrder([5, 4, 3, 2, 1], 5), true);
  assert.equal(isChoiceOrder([5, 4, 3, 2, 2], 5), false);
  assert.equal(isChoiceOrder([1, 2, 3], 5), false);
  assert.equal(isChoiceOrder(null, 5), false);
});

test('선지를 시험지 순서로 놓고 정답 번호를 따라 바꾼다 (가형 6 ② = 나형 11 ④)', () => {
  const ga = choices(['1/6', '1/3', '1/2', '2/3', '5/6']);
  const na = reorderChoices(ga, [5, 4, 3, 2, 1]);
  assert.deepEqual(na.map((c) => c.label), circled);
  assert.deepEqual(na.map((c) => c.text), ['5/6', '2/3', '1/2', '1/3', '1/6']);
  assert.equal(remapAnswerKey('②', [5, 4, 3, 2, 1]), '④');
  assert.equal(remapAnswerKey('2', [5, 4, 3, 2, 1]), '4');
  // 주관식 값과 틀린 순서는 그대로 둔다.
  assert.equal(remapAnswerKey('36', [5, 4, 3, 2, 1]), '36');
  assert.equal(remapAnswerKey('②', [5, 4, 3]), '②');
  assert.equal(reorderChoices(ga, [1, 2, 3]), ga);
});

test('자리 값이 없으면 문항을 그대로, 있으면 번호·배점·본문·선지를 그 시험지 것으로', () => {
  const q = question('g6', 'ga', 6);
  assert.equal(applySlotValuesToQuestion(q, {}), q);
  assert.equal(applySlotValuesToQuestion(q, { choiceOrder: [1, 2, 3, 4, 5] }), q);

  const slot = applySlotValuesToQuestion(q, {
    number: '11',
    score: 4,
    stem: '나형에 인쇄된 본문',
    choiceOrder: [5, 4, 3, 2, 1],
  });
  assert.equal(slot.question_number, '11');
  assert.equal(slot.stem, '나형에 인쇄된 본문');
  assert.equal(slot.meta.score_point, 4);
  assert.deepEqual(slot.choices.map((c) => c.text), ['5', '4', '3', '2', '1']);
  assert.equal(slot.objective_answer_key, '④');
  // 원본 문항은 바뀌지 않는다.
  assert.equal(q.question_number, '6');
  assert.equal(q.meta.score_point, 3);
  assert.equal(q.objective_answer_key, '②');
});

test('자리로 채운 문항은 프리셋에서 자리 번호의 형식과 자리 배점을 쓴다', () => {
  const exam = { id: EXAM, academy_id: 'a', grade: 3, exam_year: 2020, school_year: 2021, exam_month: 11, org: 'csat' };
  // 나형 15(객관식) 문항을 가형 26번 자리가 가리킨다.
  const owner = question('n15', 'na', 15, { meta: { score_point: 4 } });
  const row = slotQuestionRow({ problem_number: 26, score: 4, choice_order: null, stem_override: '…를 구하시오.' }, owner);
  assert.equal(row.question_number, '26');
  assert.equal(row.__slot.stem, '…를 구하시오.');
  assert.equal(slotQuestionRow({ problem_number: 26 }, null), null);

  const own = question('g13', 'ga', 13);
  const payload = buildMockExamPresetPayload({
    exam,
    elective: 'ga',
    orderedQuestions: [own, row],
    commonDocumentId: '',
    electiveDocumentId: 'doc-ga',
  });
  const rc = payload.render_config;
  assert.equal(rc.questionModeByQuestionUid[own.question_uid], 'objective');
  assert.equal(rc.questionModeByQuestionUid[owner.question_uid], 'subjective');
  assert.equal(rc.questionScoreByQuestionUid[owner.question_uid], 4);
  assert.deepEqual(payload.selected_question_ids, ['g13', 'n15']);
});

test('뽑는 문항으로 가형·나형 시험지를 알아본다', () => {
  const naOwn = [1, 2, 3].map((n) => question(`n${n}`, 'na', n));
  const gaShared = question('g6', 'ga', 6);
  const slots = [{ exam_id: EXAM, section: 'na', problem_number: 11, pb_question_id: 'g6' }];

  const paper = inferMockPaper([...naOwn, gaShared], slots);
  assert.equal(paper.section, 'na');
  assert.equal(paper.slotByQuestionId.get('g6').problem_number, 11);

  // 한 구간의 문항뿐이면 바꿀 것이 없다.
  assert.equal(inferMockPaper(naOwn, slots), null);
  // 연결이 없는 다른 구간 문항이 끼면 시험지로 보지 않는다.
  assert.equal(inferMockPaper([...naOwn, question('g9', 'ga', 9)], slots), null);
  // 과반 구간이 없으면 시험지로 보지 않는다.
  assert.equal(inferMockPaper([naOwn[0], gaShared], slots), null);
  // 다른 회차나 가형·나형이 아닌 문항이 끼면 시험지로 보지 않는다.
  const other = question('x1', 'na', 4);
  other.meta.mock_exam_item.exam_id = 'other-exam';
  assert.equal(inferMockPaper([...naOwn, gaShared, other], slots), null);
  assert.equal(inferMockPaper([...naOwn, gaShared, question('c1', 'common', 5)], slots), null);
  assert.equal(inferMockPaper([...naOwn, gaShared, { id: 'book', meta: {} }], slots), null);
});

function fakeSupa(rows, calls) {
  const builder = {
    select() { return builder; },
    eq() { return builder; },
    not() { return builder; },
    then(resolve) {
      calls.count += 1;
      return Promise.resolve({ data: rows, error: null }).then(resolve);
    },
  };
  return { from() { return builder; } };
}

test('시험지 한 부를 뽑을 때 참조 자리만 그 시험지 값으로 바뀐다', async () => {
  const naOwn = [1, 2, 3].map((n) => question(`n${n}`, 'na', n));
  const gaShared = question('g6', 'ga', 6);
  const calls = { count: 0 };
  const supa = fakeSupa([
    { exam_id: EXAM, section: 'na', problem_number: 11, pb_question_id: 'g6', answer_kind: 'objective', score: 4, choice_order: [5, 4, 3, 2, 1], stem_override: null },
  ], calls);

  const result = await applyMockPaperSlotValues({ supa, academyId: 'a', questions: [...naOwn, gaShared] });
  assert.deepEqual(result.paper, { examId: EXAM, section: 'na' });
  assert.equal(result.questions[0], naOwn[0]);
  const shared = result.questions[3];
  assert.equal(shared.question_number, '11');
  assert.equal(shared.objective_answer_key, '④');
  assert.equal(shared.stem, gaShared.stem);
  assert.equal(result.scoreByQuestionKey['uid-g6'], 4);
  assert.equal(result.scoreByQuestionKey.g6, 4);
  assert.equal(result.modeByQuestionKey['uid-g6'], 'objective');
  assert.equal(calls.count, 1);
});

test('가형·나형이 아닌 작업과 한 구간뿐인 작업은 DB 를 읽지 않고 그대로 둔다', async () => {
  const calls = { count: 0 };
  const supa = fakeSupa([], calls);
  const common = [question('c1', 'common', 1), question('p23', 'probstats', 23)];
  const textbook = [{ id: 't1', meta: {} }];
  const naOnly = [question('n1', 'na', 1), question('n2', 'na', 2)];
  for (const rows of [common, textbook, naOnly, []]) {
    const result = await applyMockPaperSlotValues({ supa, academyId: 'a', questions: rows });
    assert.equal(result.questions, rows);
    assert.equal(result.paper, null);
  }
  assert.equal(calls.count, 0);
});
