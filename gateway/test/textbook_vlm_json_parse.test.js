import test from 'node:test';
import assert from 'node:assert/strict';

import { parseTextbookVlmJson } from '../src/textbook/vlm_json_parse.js';

test('textbook VLM parser closes truncated answer JSON', () => {
  const parsed = parseTextbookVlmJson(
    '{"items":[{"problem_number":"0001","answer_text":"수렴, 0"}],"notes":""',
  );
  assert.ok(parsed);
  assert.equal(parsed.items[0].problem_number, '0001');
  assert.equal(parsed.items[0].answer_text, '수렴, 0');
});

test('textbook VLM parser ignores trailing model junk', () => {
  const parsed = parseTextbookVlmJson(
    '{"items":[],"notes":"해당 번호 없음"} }"',
  );
  assert.deepEqual(parsed, { items: [], notes: '해당 번호 없음' });
});

// 수력충전 2-1 답지 14쪽. 모델이 정답 13건을 제대로 읽고 STOP 으로 끝냈는데도
// 객체를 배열로 한 겹 감싸 `[{...}]` 로 돌려줘, 판독기가 읽는 entries 가
// undefined 가 되면서 오류 한 줄 없이 0건으로 끝났다.
test('textbook VLM parser unwraps an object wrapped in an array', () => {
  const parsed = parseTextbookVlmJson(
    '[{"leading_continuation":true,"entries":[' +
      '{"kind":"answer","problem_number":"06","answer_text":"48 cm"}]}]',
  );
  assert.ok(parsed);
  assert.equal(parsed.leading_continuation, true);
  assert.equal(parsed.entries.length, 1);
  assert.equal(parsed.entries[0].problem_number, '06');
});

test('textbook VLM parser joins arrays when the wrapper holds several objects', () => {
  const parsed = parseTextbookVlmJson(
    '[{"items":[{"problem_number":"01"}],"notes":"앞"},' +
      '{"items":[{"problem_number":"02"}],"notes":"뒤"}]',
  );
  assert.ok(parsed);
  assert.deepEqual(
    parsed.items.map((i) => i.problem_number),
    ['01', '02'],
  );
  assert.equal(parsed.notes, '앞');
});

// 개념원리 1-2 해설 49쪽. 모델이 껍데기 없이 문항 네 개만 배열로 돌려줬고,
// 껍데기 여러 겹으로 보고 합치자 좌표 16개짜리 가짜 문항 하나가 되어 0건이 됐다.
test('textbook VLM parser treats a bare record array as items', () => {
  const parsed = parseTextbookVlmJson(
    '[{"problem_number":"05","number_region":[64,60,80,84],"rubric_steps":[]},' +
      '{"problem_number":"06","number_region":[203,60,219,84],"rubric_steps":[]}]',
  );
  assert.ok(parsed);
  assert.deepEqual(
    parsed.items.map((i) => [i.problem_number, i.number_region]),
    [
      ['05', [64, 60, 80, 84]],
      ['06', [203, 60, 219, 84]],
    ],
  );
});

test('textbook VLM parser treats a single bare record as items', () => {
  const parsed = parseTextbookVlmJson(
    '[{"problem_number":"05","number_region":[64,60,80,84]}]',
  );
  assert.deepEqual(parsed, {
    items: [{ problem_number: '05', number_region: [64, 60, 80, 84] }],
  });
});

test('textbook VLM parser leaves a plain array alone', () => {
  assert.deepEqual(parseTextbookVlmJson('[1,2,3]'), [1, 2, 3]);
});

test('textbook VLM parser repairs unescaped LaTeX backslashes', () => {
  const parsed = parseTextbookVlmJson(
    '{"items":[{"problem_number":"0001","answer_text":"\\frac{1}{2}"}],"notes":""}',
  );
  assert.ok(parsed);
  assert.equal(parsed.items[0].answer_text, '\\frac{1}{2}');
});
