import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeBlankChoiceTableStem } from '../src/problem_bank/extract_engines/vlm/writeback.js';

test('comma-separated 4-column choices with (가)~(라) become blank_table', () => {
  const stem = [
    'box{~~} 안에 들어갈 내용이 모두 옳은 것은?',
    '[박스시작]',
    '두 삼각형 \\triangle OPA와 (가) 에서 (나) 이고',
    '\\angle OAP = (다) (엇각)',
    '\\angle AOP = (라) (맞꼭지각)',
    '[박스끝]',
  ].join('\n');
  const choices = [
    { label: '①', text: '\\triangle OQC, \\overline{PA} = \\overline{QC}, \\angle OCQ, \\angle COQ' },
    { label: '②', text: '\\triangle OQC, \\overline{OA} = \\overline{OC}, \\angle OCQ, \\angle COQ' },
    { label: '③', text: '\\triangle OQC, \\overline{OA} = \\overline{OC}, \\angle OAB, \\angle AOB' },
    { label: '④', text: '\\triangle OPD, \\overline{OA} = \\overline{OD}, \\angle OPA, \\angle ODP' },
    { label: '⑤', text: '\\triangle OPD, \\overline{OA} = \\overline{OD}, \\angle OPA, \\angle ODP' },
  ];
  const result = normalizeBlankChoiceTableStem(stem, choices);
  assert.equal(result.isBlankChoice, true);
  assert.deepEqual(result.labels, ['(가)', '(나)', '(다)', '(라)']);
  assert.equal(result.stem, stem);
});
