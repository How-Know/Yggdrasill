import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeAnswerResult } from '../src/textbook/vlm_answer_client.js';

function numbersOf(items) {
  return items.map((it) => it.problem_number);
}

function answer(problemNumber, answerText) {
  return { problem_number: problemNumber, kind: 'subjective', answer_text: answerText };
}

// 개념+유형은 필수 문제 "2" 와 따름 문제 "2-1", 쏙쏙 블록 "109-1"~"109-6" 이
// 한 지면에 같이 나온다. 예전 키 정규화는 범위가 아닌 하이픈 번호를 첫 숫자로
// 뭉개서("2-1"→"2", "109-2"→"109") 뒤에 온 정답을 중복으로 버렸다.
test('따름 문제는 대표 문항과 다른 정답으로 남는다', () => {
  const out = normalizeAnswerResult({
    items: [answer('2', 'x=1'), answer('2-1', 'x=2'), answer('3', 'x=3'), answer('3-1', 'x=4')],
  });
  assert.deepEqual(numbersOf(out.items), ['2', '2-1', '3', '3-1']);
  assert.equal(out.items[1].answer_text, 'x=2');
});

test('블록 접두어가 같은 쏙쏙 문항이 하나로 합쳐지지 않는다', () => {
  const out = normalizeAnswerResult({
    items: [
      answer('109-1', 'a'),
      answer('109-2', 'b'),
      answer('109-3', 'c'),
      answer('112-1', 'd'),
    ],
  });
  assert.deepEqual(numbersOf(out.items), ['109-1', '109-2', '109-3', '112-1']);
});

test('한글 코너 접두어가 붙은 번호는 숫자만 남기지 않는다', () => {
  const out = normalizeAnswerResult({
    items: [answer('개념확인105', '<, <'), answer('105', '다른 문항'), answer('예제1', 'p')],
  });
  assert.deepEqual(numbersOf(out.items), ['개념확인105', '105', '예제1']);
});

test('진짜 세트 범위는 여전히 범위 키로 묶인다', () => {
  const out = normalizeAnswerResult({
    items: [answer('48~52', '[image]'), answer('48-52', '중복')],
  });
  assert.deepEqual(numbersOf(out.items), ['48~52']);
});

test('앞자리 0 이 붙은 번호는 예전처럼 같은 문항으로 본다', () => {
  const out = normalizeAnswerResult({
    items: [answer('0013', '①'), answer('13', '중복')],
  });
  assert.deepEqual(numbersOf(out.items), ['0013']);
});
