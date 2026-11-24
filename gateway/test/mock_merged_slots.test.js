import test from 'node:test';
import assert from 'node:assert/strict';

import { dropMergedSlotQuestions, relinkMergedSlots } from '../src/mock_exam/merged_slots.js';
import {
  applyMergePlan,
  checkMergeRestore,
  collectMergeBackup,
  planSameQuestionMerge,
  restoreMergeBackup,
} from '../src/mock_exam/merge_same.js';

const ACADEMY = 'academy-1';
const EXAM = 'exam-2020-11';

// 기본 키가 겹치면 23505 를 돌려주는 가짜 클라이언트. 문항·크롭을 지우면 딸린 행도 지운다(DB 의 cascade).
const PRIMARY = { pb_delivery_units: 'question_id' };
const CASCADE = {
  pb_questions: [['pb_delivery_units', 'question_id'], ['textbook_crop_question_links', 'pb_question_id']],
  textbook_problem_crops: [['textbook_problem_analyses', 'crop_id'], ['textbook_crop_question_links', 'crop_id']],
};
function fakeSupa(tables) {
  const table = (name) => tables[name] || (tables[name] = []);
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
    in(col, values) {
      const set = new Set(values.map(String));
      this.filters.push((r) => set.has(String(r[col])));
      return this;
    }
    not(col, op, value) {
      assert.equal(op, 'is');
      assert.equal(value, null);
      this.filters.push((r) => r[col] !== null && r[col] !== undefined);
      return this;
    }
    update(values) {
      this.op = 'update';
      this.values = values;
      return this;
    }
    insert(row) {
      this.op = 'insert';
      this.row = row;
      return this;
    }
    delete() {
      this.op = 'delete';
      return this;
    }
    then(resolve) {
      const rows = table(this.name);
      if (this.op === 'insert') {
        const key = PRIMARY[this.name] || 'id';
        if (this.row[key] !== undefined && rows.some((r) => r[key] === this.row[key])) {
          resolve({ data: null, error: { code: '23505', message: 'duplicate key' } });
          return;
        }
        rows.push({ ...this.row });
        resolve({ data: null, error: null });
        return;
      }
      const hit = rows.filter((r) => this.filters.every((f) => f(r)));
      if (this.op === 'update') hit.forEach((r) => Object.assign(r, this.values));
      if (this.op === 'delete') {
        tables[this.name] = rows.filter((r) => !hit.includes(r));
        for (const [child, column] of CASCADE[this.name] || []) {
          tables[child] = table(child).filter((r) => !hit.some((h) => h.id === r[column]));
        }
        if (this.name === 'pb_questions') {
          for (const it of table('mock_exam_items')) {
            if (hit.some((h) => h.id === it.pb_question_id)) it.pb_question_id = null;
          }
        }
      }
      resolve({ data: hit, error: null });
    }
  }
  return { from: (name) => new Query(name) };
}

const slotQuestion = (number, itemId) => ({
  question_number: String(number),
  meta: itemId ? { mock_exam_item: { item_id: itemId, exam_id: EXAM, section: 'na' } } : {},
});

test('재추출 결과에서 합친 자리의 문항을 뺀다', async () => {
  const tables = {
    mock_exam_items: [
      { id: 'na-7', exam_id: EXAM, section: 'na', problem_number: 7, merged_at: '2026-11-24T00:00:00Z' },
      { id: 'na-8', exam_id: EXAM, section: 'na', problem_number: 8, merged_at: null },
      { id: 'na-11', exam_id: EXAM, section: 'na', problem_number: 11, merged_at: '2026-11-24T00:00:00Z' },
      // 가형 7번은 합친 자리가 아니다. 구간이 다르면 번호가 같아도 빼지 않는다.
      { id: 'ga-26', exam_id: EXAM, section: 'ga', problem_number: 26, merged_at: '2026-11-24T00:00:00Z' },
    ],
  };
  const supa = fakeSupa(tables);
  const questions = [
    slotQuestion(7, 'na-7'),
    slotQuestion(8, 'na-8'),
    // 자리 표시 없이 읽힌 문항은 번호로 가려낸다.
    slotQuestion(11, ''),
    slotQuestion(26, ''),
  ];
  const dropped = await dropMergedSlotQuestions(supa, questions, { exam_id: EXAM, section: 'na' });
  assert.deepEqual(dropped, ['7', '11']);
  assert.deepEqual(questions.map((q) => q.question_number), ['8', '26']);

  // 합친 자리가 없는 구간과 모의고사가 아닌 문서는 그대로 둔다.
  const common = [slotQuestion(7, 'c-7')];
  assert.deepEqual(await dropMergedSlotQuestions(supa, common, { exam_id: EXAM, section: 'common' }), []);
  assert.deepEqual(await dropMergedSlotQuestions(supa, common, null), []);
  assert.equal(common.length, 1);
});

test('문항을 가진 구간을 다시 추출하면 합친 자리를 새 문항으로 이어 준다', async () => {
  const tables = {
    mock_exam_items: [
      // 나형 7번 자리 → 가형 5번 문항(연결은 나형 쪽에 적혀 있다). 가형 재추출로 자리가 비었다.
      { id: 'ga-5', academy_id: ACADEMY, exam_id: EXAM, pb_question_id: 'q-ga-5-new', same_as_item_id: null, merged_at: null },
      { id: 'na-7', academy_id: ACADEMY, exam_id: EXAM, pb_question_id: null, same_as_item_id: 'ga-5', merged_at: '2026-11-24T00:00:00Z' },
      // 가형 26번 자리 → 나형 15번 문항(연결은 문항을 가진 나형 쪽에 적혀 있다). 문항 id 가 바뀌었다.
      { id: 'na-15', academy_id: ACADEMY, exam_id: EXAM, pb_question_id: 'q-na-15-new', same_as_item_id: 'ga-26', merged_at: null },
      { id: 'ga-26', academy_id: ACADEMY, exam_id: EXAM, pb_question_id: 'q-na-15-old', same_as_item_id: null, merged_at: '2026-11-24T00:00:00Z' },
      // 이미 맞는 자리와 합치지 않은 자리는 그대로 둔다.
      { id: 'ga-6', academy_id: ACADEMY, exam_id: EXAM, pb_question_id: 'q-ga-6', same_as_item_id: null, merged_at: null },
      { id: 'na-11', academy_id: ACADEMY, exam_id: EXAM, pb_question_id: 'q-ga-6', same_as_item_id: 'ga-6', merged_at: '2026-11-24T00:00:00Z' },
      { id: 'na-21', academy_id: ACADEMY, exam_id: EXAM, pb_question_id: 'q-na-21', same_as_item_id: null, merged_at: null },
      // 짝의 문항이 아직 없으면(추출 전) 풀지 못한 자리로 알린다.
      { id: 'ga-12', academy_id: ACADEMY, exam_id: EXAM, pb_question_id: null, same_as_item_id: null, merged_at: null },
      { id: 'na-19', academy_id: ACADEMY, exam_id: EXAM, pb_question_id: null, same_as_item_id: 'ga-12', merged_at: '2026-11-24T00:00:00Z' },
    ],
  };
  const result = await relinkMergedSlots(fakeSupa(tables), { academyId: ACADEMY, examId: EXAM });
  assert.deepEqual(result, { relinked: 2, unresolved: ['na-19'] });
  const questionOf = (id) => tables.mock_exam_items.find((it) => it.id === id).pb_question_id;
  assert.equal(questionOf('na-7'), 'q-ga-5-new');
  assert.equal(questionOf('ga-26'), 'q-na-15-new');
  assert.equal(questionOf('na-11'), 'q-ga-6');
  assert.equal(questionOf('na-21'), 'q-na-21');
});

test('합친 것을 기록 파일로 되돌린다', async () => {
  const choices = ['①', '②', '③', '④', '⑤'].map((label, i) => ({ label, text: String(i + 1) }));
  const question = (id, documentId, score) => ({
    id,
    question_uid: `uid-${id}`,
    document_id: documentId,
    stem: '값은?',
    choices,
    subjective_answer: '2',
    is_published: false,
    meta: { score_point: score },
  });
  const item = (id, section, number, questionId) => ({
    id,
    section,
    problem_number: number,
    answer_kind: 'objective',
    answer_text: '②',
    pb_question_id: questionId,
    score: null,
    choice_order: null,
    stem_override: null,
    merged_at: null,
  });
  const tables = {
    mock_exam_items: [item('i-ga', 'ga', 13, 'q-ga'), item('i-na', 'na', 18, 'q-na')],
    pb_questions: [question('q-ga', 'doc-ga', 3), question('q-na', 'doc-na', 4)],
    textbook_problem_crops: [{ id: 'crop-ga' }, { id: 'crop-na' }],
    textbook_crop_question_links: [{ id: 'l-na', crop_id: 'crop-na', pb_question_id: 'q-na' }],
    textbook_problem_analyses: [{ id: 'a-na', crop_id: 'crop-na', solution_transcribed: '풀이' }],
    pb_delivery_units: [{ question_id: 'q-na', title: '나형 18' }],
  };
  const supa = fakeSupa(tables);
  const plan = planSameQuestionMerge({
    a: tables.mock_exam_items[1],
    b: tables.mock_exam_items[0],
    questions: new Map(tables.pb_questions.map((q) => [q.id, q])),
    pendingDocumentIds: new Set(['doc-ga', 'doc-na']),
    cropIdByQuestionId: new Map([['q-ga', 'crop-ga'], ['q-na', 'crop-na']]),
  });
  // 파일에 쓰고 다시 읽는 것과 같게 한다.
  const backup = JSON.parse(JSON.stringify(await collectMergeBackup(supa, plan)));

  assert.match(await checkMergeRestore(supa, backup), /합친 상태가 아님/);
  await applyMergePlan(supa, plan);
  assert.equal(tables.pb_questions.length, 1);
  assert.equal(tables.textbook_problem_analyses.length, 0);
  assert.equal(await checkMergeRestore(supa, backup), '');

  // 문항을 넣을 때 DB 가 배포 단위를 스스로 만들었다고 치면, 그 행은 건너뛴다.
  tables.pb_delivery_units.push({ question_id: 'q-na', title: '자동 생성' });
  const result = await restoreMergeBackup(supa, backup);
  assert.deepEqual(result.skipped, { pb_delivery_units: 1 });
  assert.equal(result.inserted.pb_questions, 1);
  assert.equal(result.inserted.textbook_problem_crops, 1);
  assert.equal(result.inserted.textbook_problem_analyses, 1);
  assert.equal(result.inserted.textbook_crop_question_links, 1);
  const slot = tables.mock_exam_items.find((it) => it.id === 'i-na');
  assert.deepEqual(
    [slot.pb_question_id, slot.score, slot.choice_order, slot.stem_override, slot.merged_at],
    ['q-na', null, null, null, null],
  );
  assert.deepEqual(tables.pb_questions.map((q) => q.id).sort(), ['q-ga', 'q-na']);

  // 두 번 되돌리지 않는다.
  await assert.rejects(() => restoreMergeBackup(supa, backup), /merge_restore_refused/);
});
