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
