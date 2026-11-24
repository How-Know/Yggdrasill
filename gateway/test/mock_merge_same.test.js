import test from 'node:test';
import assert from 'node:assert/strict';

import {
  applyMergePlan,
  choiceOrderBetween,
  collectMergeBackup,
  planSameQuestionMerge,
} from '../src/mock_exam/merge_same.js';

const circled = ['①', '②', '③', '④', '⑤'];
const choices = (texts) => texts.map((text, i) => ({ label: circled[i], text }));

function question(id, documentId, extra = {}) {
  return {
    id,
    question_uid: `uid-${id}`,
    document_id: documentId,
    stem: '함수 $f(x)$ 의 값은?',
    choices: choices(['1', '2', '3', '4', '5']),
    subjective_answer: '2',
    is_published: false,
    meta: { score_point: 3 },
    ...extra,
  };
}

function item(id, section, number, questionId, extra = {}) {
  return {
    id,
    section,
    problem_number: number,
    answer_kind: 'objective',
    answer_text: '②',
    pb_question_id: questionId,
    merged_at: null,
    ...extra,
  };
}

const pending = new Set(['doc-ga', 'doc-na']);
const plan = (a, b, rows, extra = {}) =>
  planSameQuestionMerge({
    a,
    b,
    questions: new Map(rows.map((q) => [q.id, q])),
    pendingDocumentIds: pending,
    cropIdByQuestionId: new Map(rows.map((q) => [q.id, `crop-${q.id}`])),
    ...extra,
  });

test('선지 순서: 같으면 null, 뒤집히면 순서, 짝이 안 맞으면 undefined', () => {
  const ga = { choices: choices(['1/6', '1/3', '1/2', '2/3', '5/6']) };
  assert.equal(choiceOrderBetween(ga, { choices: choices(['1/6', '1/3', '1/2', '2/3', '5/6']) }), null);
  assert.deepEqual(choiceOrderBetween(ga, { choices: choices(['5/6', '2/3', '1/2', '1/3', '1/6']) }), [5, 4, 3, 2, 1]);
  // 전사 차이(띄어쓰기, \dfrac)는 같은 값으로 본다.
  assert.equal(
    choiceOrderBetween({ choices: choices(['$\\dfrac{1}{2}$', '2']) }, { choices: choices(['$\\frac{1}{2} $', '2']) }),
    null,
  );
  assert.equal(choiceOrderBetween(ga, { choices: choices(['1/6', '1/3', '1/2', '2/3', '7/6']) }), undefined);
  assert.equal(choiceOrderBetween(ga, { choices: [] }), undefined);
  assert.equal(choiceOrderBetween({ choices: choices(['1', '1']) }, { choices: choices(['1', '1']) }), undefined);
});

test('형식이 같으면 가형이 문항을 갖고, 다른 값만 자리에 적는다', () => {
  const ga = item('i-ga', 'ga', 13, 'q-ga');
  const na = item('i-na', 'na', 18, 'q-na');
  const p = plan(na, ga, [question('q-ga', 'doc-ga'), question('q-na', 'doc-na', { meta: { score_point: 4 } })]);
  assert.equal(p.status, 'merge');
  assert.equal(p.owner.section, 'ga');
  assert.equal(p.slot.itemId, 'i-na');
  assert.deepEqual(p.duplicate, { questionId: 'q-na', questionUid: 'uid-q-na', cropId: 'crop-q-na' });
  assert.deepEqual(p.set, { pb_question_id: 'q-ga', score: 4, choice_order: null, stem_override: null });
});

test('선지가 뒤집힌 쌍은 선지 순서를 적고 정답 번호가 맞는지 본다', () => {
  const ga = item('i-ga', 'ga', 6, 'q-ga', { answer_text: '②' });
  const na = item('i-na', 'na', 11, 'q-na', { answer_text: '④' });
  const rows = [
    question('q-ga', 'doc-ga'),
    question('q-na', 'doc-na', { choices: choices(['5', '4', '3', '2', '1']) }),
  ];
  const p = plan(na, ga, rows);
  assert.equal(p.status, 'merge');
  assert.deepEqual(p.set.choice_order, [5, 4, 3, 2, 1]);

  const wrong = plan({ ...na, answer_text: '③' }, ga, rows);
  assert.equal(wrong.status, 'refused');
  assert.match(wrong.reasons.join(), /정답 번호/);
});

test('형식이 다르면 객관식 쪽이 문항을 갖고, 다른 본문은 자리에 둔다', () => {
  const na = item('i-na', 'na', 15, 'q-na', { answer_text: '②' });
  const ga = item('i-ga', 'ga', 26, 'q-ga', { answer_kind: 'subjective', answer_text: '2' });
  const rows = [
    question('q-na', 'doc-na', { meta: { score_point: 4 } }),
    question('q-ga', 'doc-ga', { stem: '함수 $f(x)$ 의 값을 구하시오.', choices: [], meta: { score_point: 4 } }),
  ];
  const p = plan(na, ga, rows);
  assert.equal(p.status, 'merge');
  assert.equal(p.formDiffers, true);
  assert.equal(p.owner.section, 'na');
  assert.equal(p.slot.section, 'ga');
  assert.deepEqual(p.set, {
    pb_question_id: 'q-na',
    score: null,
    choice_order: null,
    stem_override: '함수 $f(x)$ 의 값을 구하시오.',
  });

  const differs = plan(na, { ...ga, answer_text: '7' }, rows);
  assert.equal(differs.status, 'refused');
  // 자리에 둘 본문의 그림 표시 수가 문항과 다르면 합치지 않는다.
  const figure = plan(na, ga, [rows[0], { ...rows[1], stem: `${rows[1].stem}\n[그림]` }]);
  assert.equal(figure.status, 'refused');
  assert.match(figure.reasons.join(), /그림 표시/);
  const empty = plan(na, ga, [{ ...rows[0], subjective_answer: '' }, rows[1]]);
  assert.equal(empty.status, 'merge');
  assert.equal(empty.notes.length, 1);
});

test('자리에 옮기는 본문은 검수가 고쳐 둔 반영 대기 본문을 먼저 쓴다', () => {
  const na = item('i-na', 'na', 15, 'q-na', { answer_text: '②' });
  const ga = item('i-ga', 'ga', 26, 'q-ga', { answer_kind: 'subjective', answer_text: '2' });
  const rows = [
    question('q-na', 'doc-na', { stem: '세 학생 A, B의 경우의 수는?' }),
    question('q-ga', 'doc-ga', { stem: '세 학생 A, B의 경우의 수를 구하시오.', choices: [] }),
  ];
  const staged = plan(na, ga, rows, {
    stagedStemByQuestionId: new Map([['q-ga', '세 학생 \\text{A}, \\text{B}의 경우의 수를 구하시오.']]),
  });
  assert.equal(staged.set.stem_override, '세 학생 \\text{A}, \\text{B}의 경우의 수를 구하시오.');

  // 한쪽만 곧은 글자로 고쳐져 있어도(글꼴 명령만 다름) 같은 본문으로 본다.
  const same = [rows[0], { ...rows[1], stem: rows[0].stem }];
  const fontOnly = plan(na, ga, same, {
    stagedStemByQuestionId: new Map([['q-na', '세 학생 \\text{A}, \\text{B}의 경우의 수는?']]),
  });
  assert.equal(fontOnly.set.stem_override, null);
});

test('합치지 않는 경우: 이미 합침, 공개된 구간, 학생 기록, 문항 없음', () => {
  const ga = item('i-ga', 'ga', 5, 'q-ga');
  const na = item('i-na', 'na', 7, 'q-na');
  const rows = [question('q-ga', 'doc-ga'), question('q-na', 'doc-na')];

  assert.equal(plan({ ...na, merged_at: '2026-11-24T00:00:00Z' }, ga, rows).status, 'done');
  assert.equal(plan(na, ga, rows, { pendingDocumentIds: new Set(['doc-na']) }).status, 'refused');
  assert.equal(plan(na, ga, [{ ...rows[0], is_published: true }, rows[1]]).status, 'refused');
  const recorded = plan(na, ga, rows, { recordCounts: new Map([['q-na', 2]]) });
  assert.equal(recorded.status, 'refused');
  assert.match(recorded.reasons.join(), /기록 2건/);
  // 문항을 가진 쪽(가형)의 기록은 지워지지 않으므로 막지 않는다.
  assert.equal(plan(na, ga, rows, { recordCounts: new Map([['q-ga', 2]]) }).status, 'merge');
  assert.equal(plan(na, ga, [rows[0]]).status, 'refused');
  assert.equal(plan({ ...na, pb_question_id: 'q-ga' }, ga, rows).status, 'refused');
});

function fakeSupa(tables) {
  const log = [];
  class Query {
    constructor(name) {
      this.name = name;
      this.filters = [];
      this.op = 'select';
    }
    select() { return this; }
    eq(col, value) {
      this.filters.push((r) => String(r[col]) === String(value));
      return this;
    }
    update(values) {
      this.op = 'update';
      this.values = values;
      return this;
    }
    delete() {
      this.op = 'delete';
      return this;
    }
    then(resolve) {
      const rows = tables[this.name] || (tables[this.name] = []);
      const hit = rows.filter((r) => this.filters.every((f) => f(r)));
      if (this.op === 'update') {
        hit.forEach((r) => Object.assign(r, this.values));
        log.push(`update ${this.name}`);
      } else if (this.op === 'delete') {
        tables[this.name] = rows.filter((r) => !hit.includes(r));
        log.push(`delete ${this.name}`);
      }
      resolve({ data: hit, error: null });
    }
  }
  return { from: (name) => new Query(name), log };
}

test('실행: 기록을 남기고, 자리를 돌린 뒤 중복 크롭과 문항을 지운다', async () => {
  const ga = item('i-ga', 'ga', 13, 'q-ga');
  const na = item('i-na', 'na', 18, 'q-na');
  const rows = [question('q-ga', 'doc-ga'), question('q-na', 'doc-na', { meta: { score_point: 4 } })];
  const tables = {
    mock_exam_items: [{ ...ga }, { ...na }],
    pb_questions: rows.map((q) => ({ ...q })),
    textbook_problem_crops: [{ id: 'crop-q-ga' }, { id: 'crop-q-na' }],
    textbook_problem_analyses: [{ crop_id: 'crop-q-na', solution_transcribed: '풀이' }],
    textbook_crop_question_links: [{ crop_id: 'crop-q-na', pb_question_id: 'q-na' }],
  };
  const supa = fakeSupa(tables);
  const p = plan(na, ga, rows);

  const backup = await collectMergeBackup(supa, p);
  assert.equal(backup.tables.pb_questions[0].id, 'q-na');
  assert.equal(backup.tables.mock_exam_items[0].pb_question_id, 'q-na');
  assert.equal(backup.tables.textbook_problem_analyses[0].solution_transcribed, '풀이');
  assert.equal(backup.tables.textbook_problem_crops[0].id, 'crop-q-na');
  assert.equal(supa.log.length, 0);

  await applyMergePlan(supa, p, { now: () => '2026-11-24T00:00:00Z' });
  assert.deepEqual(supa.log, ['update mock_exam_items', 'delete textbook_problem_crops', 'delete pb_questions']);
  const slot = tables.mock_exam_items.find((r) => r.id === 'i-na');
  assert.equal(slot.pb_question_id, 'q-ga');
  assert.equal(slot.score, 4);
  assert.equal(slot.merged_at, '2026-11-24T00:00:00Z');
  assert.deepEqual(tables.pb_questions.map((q) => q.id), ['q-ga']);
  assert.deepEqual(tables.textbook_problem_crops.map((c) => c.id), ['crop-q-ga']);
  // 가형 자리는 건드리지 않는다.
  assert.equal(tables.mock_exam_items.find((r) => r.id === 'i-ga').merged_at, null);

  // 자리가 그 사이 바뀌었으면 아무것도 지우지 않는다.
  await assert.rejects(() => applyMergePlan(supa, p), /merge_slot_changed_since_plan/);
  await assert.rejects(() => applyMergePlan(supa, { status: 'refused' }), /merge_plan_not_applicable/);
});
