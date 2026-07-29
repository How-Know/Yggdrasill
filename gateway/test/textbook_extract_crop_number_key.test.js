import test from 'node:test';
import assert from 'node:assert/strict';

import {
  alignUniquePrefixedQuestionNumbers,
  expectedQuestionNumbersForInput,
  fetchTextbookCropPages,
  normalizeIndependentSetPayloadQuestions,
  selectExpectedQuestions,
} from '../src/problem_bank/extract_engines/vlm/runner.js';
import { normalizeProblemNumberKey } from '../src/textbook/problem_number_key.js';
import { buildPrompt } from '../src/problem_bank/extract_engines/vlm/prompt.js';

function cropClient(rows) {
  return {
    from() {
      const builder = {
        select() { return builder; },
        eq() { return builder; },
        gte() { return builder; },
        lte() { return builder; },
        then(resolve, reject) {
          return Promise.resolve({ data: rows, error: null }).then(resolve, reject);
        },
      };
      return builder;
    },
  };
}

const scope = {
  book_id: 'book-1',
  grade_label: '1-1',
  big_order: 0,
  mid_order: 0,
  sub_key: 'A',
  raw_page_from: 8,
  raw_page_to: 13,
};

// 개념+유형의 개념확인은 지면에 번호가 없어 "개념확인8" 처럼 본문 페이지를
// 번호에 넣는다. 예전 키 정규화는 정수 파싱이라 이 번호가 전부 빈 키가 됐고,
// 기대 목록이 비면서 추출 런이 vlm_textbook_crop_scope_empty 로 죽었다.
test('한글 접두어가 붙은 번호도 기대 목록에 남는다', async () => {
  const index = await fetchTextbookCropPages({
    supa: cropClient([
      { id: 'c1', problem_number: '개념확인8', raw_page: 8, item_region_1k: [100, 60, 300, 940] },
      { id: 'c2', problem_number: '개념확인9', raw_page: 9, item_region_1k: [120, 60, 320, 940] },
      { id: 'c3', problem_number: '개념확인10', raw_page: 10, item_region_1k: [90, 60, 280, 940] },
    ]),
    academyId: 'academy-1',
    textbookScope: scope,
  });

  assert.equal(index.byNumber.size, 3);
  assert.deepEqual(
    expectedQuestionNumbersForInput(index.byNumber, {
      pageRange: { start: 8, end: 13 },
    }),
    ['개념확인8', '개념확인9', '개념확인10'],
  );
});

test('번호 없는 개념확인 배지는 유일한 페이지 접미사 기대 번호에 연결한다', () => {
  const rows = alignUniquePrefixedQuestionNumbers(
    [
      { question_number: '1', stem_latex: '필수 문제' },
      { question_number: '개념확인', stem_latex: '개념확인 문항' },
      { question_number: '2', stem_latex: '필수 문제' },
    ],
    ['개념확인89'],
  );

  assert.equal(rows[1].question_number, '개념확인89');
  assert.equal(rows[1].original_question_number, '개념확인');
  assert.deepEqual(selectExpectedQuestions(rows, ['개념확인89']), [rows[1]]);
});

test('같은 접두어 기대 번호가 여러 개면 번호 없는 배지를 추측하지 않는다', () => {
  const original = [{ question_number: '개념확인' }];
  const rows = alignUniquePrefixedQuestionNumbers(original, [
    '개념확인89',
    '개념확인90',
  ]);

  assert.equal(rows, original);
});

test('따름 문제는 대표 문항 키에 덮이지 않는다', async () => {
  const index = await fetchTextbookCropPages({
    supa: cropClient([
      { id: 'c1', problem_number: '1', raw_page: 8, item_region_1k: [100, 60, 300, 480] },
      { id: 'c2', problem_number: '1-1', raw_page: 8, item_region_1k: [320, 60, 420, 480] },
      { id: 'c3', problem_number: '1-2', raw_page: 8, item_region_1k: [440, 60, 540, 480] },
      { id: 'c4', problem_number: '2', raw_page: 8, item_region_1k: [100, 520, 300, 940] },
    ]),
    academyId: 'academy-1',
    textbookScope: { ...scope, sub_key: 'B' },
  });

  assert.deepEqual([...index.byNumber.keys()], ['1', '1-1', '1-2', '2']);
  assert.equal(index.byNumber.get('1-2').cropId, 'c3');
});

// 쓱쓱 서술형은 한 지면에 예제·유제가 섞여 있고 번호는 갈래마다 1번부터다.
// 실제 지면은 예제1·유제1 을 한 줄에 나란히 싣고 그 아래에 예제2·유제2 가 온다.
// 순번을 먼저 보고 갈래를 나중에 보면 그 순서가 그대로 나온다.
test('갈래가 섞인 코너는 순번 먼저 정렬한다', async () => {
  const index = await fetchTextbookCropPages({
    supa: cropClient([
      { id: 'c2', problem_number: '유제1', raw_page: 24 },
      { id: 'c1', problem_number: '예제1', raw_page: 24 },
      { id: 'c4', problem_number: '유제2', raw_page: 24 },
      { id: 'c3', problem_number: '예제2', raw_page: 24 },
      { id: 'c5', problem_number: '연습3', raw_page: 25 },
      { id: 'c6', problem_number: '연습1', raw_page: 25 },
    ]),
    academyId: 'academy-1',
    textbookScope: { ...scope, sub_key: 'E', raw_page_from: 24, raw_page_to: 25 },
  });

  assert.deepEqual(
    expectedQuestionNumbersForInput(index.byNumber, {
      pageRange: { start: 24, end: 25 },
    }),
    ['예제1', '유제1', '예제2', '유제2', '연습1', '연습3'],
  );
});

test('따름 문제는 대표 문항 바로 뒤에 줄 세운다', async () => {
  const index = await fetchTextbookCropPages({
    supa: cropClient([
      { id: 'c4', problem_number: '2', raw_page: 8 },
      { id: 'c2', problem_number: '1-1', raw_page: 8 },
      { id: 'c1', problem_number: '1', raw_page: 8 },
      { id: 'c3', problem_number: '1-2', raw_page: 8 },
      { id: 'c5', problem_number: '10', raw_page: 8 },
    ]),
    academyId: 'academy-1',
    textbookScope: { ...scope, sub_key: 'B' },
  });

  assert.deepEqual(
    expectedQuestionNumbersForInput(index.byNumber, {
      pageRange: { start: 8, end: 13 },
    }),
    ['1', '1-1', '1-2', '2', '10'],
  );
});

test('VLM 이 매긴 순번을 기대 번호로 되돌릴 때 코너 번호가 유지된다', () => {
  const rows = selectExpectedQuestions(
    [
      { question_number: '1', stem: 'a' },
      { question_number: '2', stem: 'b' },
    ],
    ['1', '1-1'],
  );
  assert.deepEqual(rows.map((r) => r.question_number), ['1']);
});

test('개념+유형 프롬프트가 번호 규칙과 코너를 설명한다', () => {
  const prompt = buildPrompt({
    textbookScope: { series: 'gaeyu', sub_key: 'E', big_order: 0, mid_order: 0 },
    expectedQuestionNumbers: ['예제1', '유제1'],
  });
  assert.match(prompt, /개념\+유형 교재 전용 규칙/);
  assert.match(prompt, /목록에 적힌 번호를 그대로/);
  assert.match(prompt, /쓱쓱 서술형 완성하기/);
  assert.match(prompt, /교과서 \+α/);

  const other = buildPrompt({
    textbookScope: { series: 'ssen', sub_key: 'B', big_order: 0, mid_order: 0 },
  });
  assert.equal(/개념\+유형 교재 전용 규칙/.test(other), false);
});

test('개념+유형의 번호 없는 소문항 묶음은 종속형 세트로 고정한다', () => {
  const rows = normalizeIndependentSetPayloadQuestions(
    [{
      question_number: '1',
      is_set_question: true,
      set_type: 'independent_set',
      sub_questions: [
        { label: '(1)', text: '첫째 물음' },
        { label: '(2)', text: '둘째 물음' },
      ],
    }],
    {
      series: 'gaeyu',
      book_id: 'book',
      grade_label: '1-2',
      big_order: 2,
      mid_order: 0,
      sub_key: 'B',
      sub_index: 1,
    },
  );

  assert.equal(rows[0].set_type, 'dependent_set');
  assert.equal(rows[0].meta.set_model.set_type, 'dependent_set');
  assert.equal(
    rows[0].meta.set_model.delivery_policy,
    'bundled_dependent_subquestions',
  );
});

test('키 정규화 규칙', () => {
  assert.equal(normalizeProblemNumberKey('0012'), '12');
  assert.equal(normalizeProblemNumberKey('개념확인8'), '개념확인8');
  assert.equal(normalizeProblemNumberKey('예제1'), '예제1');
  assert.equal(normalizeProblemNumberKey('1-1'), '1-1');
  assert.equal(normalizeProblemNumberKey('109-2'), '109-2');
  assert.equal(normalizeProblemNumberKey('0113~0116'), '113-116');
  assert.equal(normalizeProblemNumberKey(''), '');
});
