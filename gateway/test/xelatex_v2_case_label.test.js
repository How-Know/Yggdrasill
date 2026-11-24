import test from 'node:test';
import assert from 'node:assert/strict';

import { buildTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

// 2026-11-21 까지는 "A⏎i B" 를 줄바꿈에 잘린 \ni 로 보고 되살렸다. 줄 첫머리의 i 와 구분할 수 없어
// 한 글자만 남는 \ne·\ni·\nu 복구를 껐다(저장된 본문 28개가 ∋·≠ 로 찍혔고, 복구가 맞았던 문항은 없었다).
test('줄 첫머리 경우 번호 i) 도, 줄 첫머리의 i 도 \\ni(∋) 로 바뀌지 않는다', () => {
  const tex = buildTexSource({
    stem: '따라서 y<0이다.\n[문단]\ni) x>0, y>0인 경우\n[문단]\nii) x<0인 경우 A\ni B',
    choices: [],
    question_type: '주관식',
    meta: {},
  }, {});
  assert.doesNotMatch(tex, /\\ni\)/);
  assert.match(tex, /i\) x>0/);
  assert.doesNotMatch(tex, /\\ni(?![A-Za-z])/);
});
