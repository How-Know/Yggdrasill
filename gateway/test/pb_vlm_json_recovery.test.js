import test from 'node:test';
import assert from 'node:assert/strict';

import {
  closeTruncatedJson,
  dropUnmatchedClosers,
} from '../src/problem_bank/extract_engines/vlm/client.js';

// 실제 실패 응답 꼬리 모양. Gemini 가 questions 배열을 "]" 로 두 번 닫았다.
// finishReason=STOP 이고 절단도 아니라, 재시도해도 같은 응답이 와서 그 지면
// 추출이 영구 실패했다.
const doubledCloser = `{
  "document_meta": {
    "total_questions": 1,
    "page_count": 1,
    "confidence": "high"
  },
  "questions": [
    {
      "question_number": "1",
      "stem": "다음을 구하시오.",
      "answer": { "choice": null, "subjective": "", "parts": [] },
      "score": null,
      "figures": [],
      "tables": [],
      "flags": [],
      "uncertain_fields": ["answer"]
    }
  ]
  ]
}`;

test('doubled array closer breaks JSON.parse and the truncation repair', () => {
  assert.throws(() => JSON.parse(doubledCloser));
  // 스택이 루트까지 잘못 닫혀서 절단 복구는 발동 조건을 잃는다.
  assert.equal(closeTruncatedJson(doubledCloser), null);
});

test('dropUnmatchedClosers recovers a response with a doubled array closer', () => {
  const pruned = dropUnmatchedClosers(doubledCloser);
  assert.ok(pruned);
  const parsed = JSON.parse(pruned);
  assert.equal(parsed.questions.length, 1);
  assert.equal(parsed.questions[0].question_number, '1');
  assert.equal(parsed.document_meta.total_questions, 1);
});

test('dropUnmatchedClosers leaves valid JSON and string contents alone', () => {
  assert.equal(dropUnmatchedClosers('{"a":[1,2],"b":{"c":3}}'), null);
  // 문자열 안의 괄호는 구조가 아니다.
  assert.equal(dropUnmatchedClosers('{"a":"]}]}"}'), null);
  const pruned = dropUnmatchedClosers('{"a":"]"}}');
  assert.ok(pruned);
  assert.deepEqual(JSON.parse(pruned), { a: ']' });
});

test('dropUnmatchedClosers keeps a truncated tail repairable', () => {
  // 여분 괄호와 절단이 함께 온 경우: 괄호를 걷어낸 뒤 절단 복구로 이어진다.
  const both = `{"questions":[{"number":"1"}]],"notes":"부분 응`;
  const pruned = dropUnmatchedClosers(both);
  assert.ok(pruned);
  const parsed = closeTruncatedJson(pruned);
  assert.ok(parsed);
  assert.equal(parsed.questions.length, 1);
});
