import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeBlankChoiceTableStem } from '../src/problem_bank/extract_engines/vlm/writeback.js';
import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

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

const circled = ['①', '②', '③', '④', '⑤'];

test('표 제목의 수식 명령은 중괄호를 지우지 않는다', () => {
  const stem = [
    '옳은 것은?',
    '[표시작]',
    '\\begin{tabular}{|c|c|c|c|}',
    ' & \\text{닮은 도형} & \\text{닮음조건} & \\overline{\\text{DC}}의 길이 \\\\',
    ...circled.map((c) => `${c} & a & b & c \\\\`),
    '\\end{tabular}',
    '[표끝]',
  ].join('\n');
  const result = normalizeBlankChoiceTableStem(stem, circled.map((label) => ({ label, text: '' })));
  assert.equal(result.isBlankChoice, true);
  assert.deepEqual(result.labels, ['닮은 도형', '닮음조건', '\\overline{DC}의 길이']);
});

test('표 모양 선지: 제목의 수식을 조판하고, 열 폭을 칸 내용에 맞춰 재서 넓힌다', () => {
  const tex = buildDocumentTexSource([{
    id: 'q-1',
    question_uid: 'q-1',
    question_number: '1',
    question_type: '객관식',
    stem: '옳은 것은?',
    equations: [],
    choices: circled.map((label) => ({ label, text: '\\triangle ABC\\sim\\triangle ACD, SAS닮음, \\frac{15}{4}\\text{ cm}' })),
    allow_objective: true,
    allow_subjective: false,
    mode: 'objective',
    questionMode: 'objective',
    export_mode: 'objective',
    meta: { choice_layout: 'blank_table', blank_choice_labels: ['닮은 도형', '닮음조건', '\\overline{DC}의 길이'] },
  }], {});
  assert.ok(tex.includes('\\overline{DC}'), '제목 수식이 그대로 수식으로 들어간다');
  assert.ok(!tex.includes('textbackslash{}overline'), '제목 수식을 글자로 찍지 않는다');
  assert.ok(tex.includes('m{\\YggBlankColA}') && tex.includes('m{\\YggBlankColC}'), '열 폭은 잰 값을 쓴다');
  assert.ok(/\\setbox\\YggBlankMeasureBox=\\hbox\{[^\n]*triangle/.test(tex), '칸 내용을 재서 열 폭을 정한다');
  assert.ok(tex.includes('\\rule[-1.05em]{0pt}{2.8em}'), '분수가 든 줄은 줄 높이를 늘린다');
});
