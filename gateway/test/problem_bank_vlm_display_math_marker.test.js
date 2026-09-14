import test from 'node:test';
import assert from 'node:assert/strict';

import {
  normalizeDisplayMathLineMarkers,
  normalizeMathLabelColonNotation,
  normalizeVlmQuestion,
} from '../src/problem_bank/extract_engines/vlm/writeback.js';
import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

test('joins a standalone display-math marker only to its immediate content line', () => {
  assert.equal(
    normalizeDisplayMathLineMarkers([
      '두 직선',
      '[수식제시]',
      'l: ax-y-2a+1=0,',
      '[수식제시]',
      'm: 3x-ay+2a+3=0',
      '에 대하여',
    ].join('\n')),
    [
      '두 직선',
      '[수식제시]l: ax-y-2a+1=0,',
      '[수식제시]m: 3x-ay+2a+3=0',
      '에 대하여',
    ].join('\n'),
  );
});

test('keeps valid same-line and explicit block display-math syntax unchanged', () => {
  const source = [
    '[수식제시]x+y=1',
    '[수식제시시작]',
    'x+y=1',
    '2x-y=3',
    '[수식제시끝]',
  ].join('\n');
  assert.equal(normalizeDisplayMathLineMarkers(source), source);
});

test('does not extend a standalone display-math marker across a structural boundary', () => {
  assert.equal(
    normalizeDisplayMathLineMarkers([
      '본문',
      '[수식제시]',
      '[문단]',
      'x+y=1',
    ].join('\n')),
    [
      '본문',
      '[문단]',
      'x+y=1',
    ].join('\n'),
  );
});

test('normalizes display-math marker syntax before VLM question writeback', () => {
  const normalized = normalizeVlmQuestion({
    stem: '두 직선\n[수식제시]\nl: x-y=0',
    sub_questions: [{
      label: '(1)',
      text: '[수식제시]\nx+y=1',
    }],
    choices: [],
  });

  assert.equal(normalized.stem, '두 직선\n[수식제시]l: x-y=0');
  assert.equal(normalized.sub_questions[0].text, '[수식제시]x+y=1');
});

test('normalizes equation labels to LaTeX colon notation without changing dialogue', () => {
  assert.equal(
    normalizeMathLabelColonNotation(
      "두 직선 l: 2x-y+6=0, l': 2x-y-9=0이 있다. 민수: 답을 구했다.",
    ),
    "두 직선 l\\colon 2x-y+6=0, l'\\colon 2x-y-9=0이 있다. 민수: 답을 구했다.",
  );
});

test('normalizes math label colons before VLM question writeback', () => {
  const normalized = normalizeVlmQuestion({
    stem: "직선 l: 2x-y=0과 l': 2x-y=1 사이의 거리를 구하시오.",
    choices: [],
  });

  assert.equal(
    normalized.stem,
    "직선 l\\colon 2x-y=0과 l'\\colon 2x-y=1 사이의 거리를 구하시오.",
  );
});

test('renders colon with the text glyph and without dialogue hanging indent', () => {
  const tex = buildDocumentTexSource(
    [{
      id: 'q-label-colon',
      question_uid: 'q-label-colon',
      question_number: '193',
      stem: "두 직선 l\\colon 2x-y+6=0, l'\\colon 2x-y-9=0이 있다.",
      equations: [],
      objective_choices: [],
      allow_objective: false,
      allow_subjective: true,
      export_mode: 'subjective',
    }],
    {
      profile: 'naesin',
      paper: 'A4',
      columns: 1,
      maxQuestionsPerPage: 1,
      hidePreviewHeader: true,
      hideQuestionNumber: true,
    },
  );

  assert.match(
    tex,
    /\\renewcommand\{\\colon\}\{\\mkern2mu\\mathord\{\\textnormal\{:\}\}\\mkern3mu\}/,
  );
  const body = tex.slice(tex.indexOf('\\begin{document}'));
  assert.match(body, /l\\colon/);
  assert.doesNotMatch(body, /\\hangindent=/);
});
