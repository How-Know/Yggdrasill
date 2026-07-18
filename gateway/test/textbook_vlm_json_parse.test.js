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

test('textbook VLM parser repairs unescaped LaTeX backslashes', () => {
  const parsed = parseTextbookVlmJson(
    '{"items":[{"problem_number":"0001","answer_text":"\\frac{1}{2}"}],"notes":""}',
  );
  assert.ok(parsed);
  assert.equal(parsed.items[0].answer_text, '\\frac{1}{2}');
});
