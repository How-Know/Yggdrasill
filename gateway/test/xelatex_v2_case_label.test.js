import test from 'node:test';
import assert from 'node:assert/strict';

import { buildTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

test('줄 첫머리 경우 번호 i) 는 \\ni(∋) 로 바뀌지 않고, 줄바꿈에 잘린 \\ni 는 되살린다', () => {
  const tex = buildTexSource({
    stem: '따라서 y<0이다.\n[문단]\ni) x>0, y>0인 경우\n[문단]\nii) x<0인 경우 A\ni B',
    choices: [],
    question_type: '주관식',
    meta: {},
  }, {});
  assert.doesNotMatch(tex, /\\ni\)/);
  assert.match(tex, /i\) x>0/);
  assert.match(tex, /A\\ni B/);
});
