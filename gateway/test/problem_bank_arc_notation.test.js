import test from 'node:test';
import assert from 'node:assert/strict';

import { normalizeVlmQuestion } from '../src/problem_bank/extract_engines/vlm/writeback.js';
import {
  normalizeArcNotation,
  normalizeMathLatex,
} from '../src/problem_bank/render_engine/utils/text.js';
import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

test('arc aliases normalize to the canonical frown notation', () => {
  assert.equal(
    normalizeArcNotation(
      String.raw`\overarc{AB}+\overparen{CD}+\wideparen{A_{1}B_{1}}`,
    ),
    String.raw`\overset{\frown}{AB}+\overset{\frown}{CD}+\overset{\frown}{A_{1}B_{1}}`,
  );
  assert.equal(
    normalizeArcNotation(String.raw`\overset{\frown}{EF}`),
    String.raw`\overset{\frown}{EF}`,
  );
});

test('VLM writeback normalizes arc notation in every question text surface', () => {
  const normalized = normalizeVlmQuestion({
    stem: String.raw`\overarc{AB}의 길이`,
    choices: [{ label: '①', text: String.raw`\overparen{CD}` }],
    sub_questions: [{ label: '(1)', text: String.raw`\wideparen{EF}` }],
    answer: {
      subjective: String.raw`\overarc{GH}`,
      objective_key: '①',
      parts: [{ key: '(1)', value: String.raw`\overparen{IJ}` }],
    },
  });

  assert.equal(normalized.stem, String.raw`\overset{\frown}{AB}의 길이`);
  assert.equal(normalized.choices[0].text, String.raw`\overset{\frown}{CD}`);
  assert.equal(normalized.sub_questions[0].text, String.raw`\overset{\frown}{EF}`);
  assert.equal(normalized.answer.subjective, String.raw`\overset{\frown}{GH}`);
  assert.equal(normalized.answer.parts[0].value, String.raw`\overset{\frown}{IJ}`);
});

test('HTML math and V2 XeLaTeX safety nets accept legacy overarc data', () => {
  assert.equal(
    normalizeMathLatex(String.raw`\overarc{AB}`),
    String.raw`\overset{\frown}{AB}`,
  );

  const tex = buildDocumentTexSource(
    [{
      id: 'q-legacy-overarc',
      question_uid: 'q-legacy-overarc',
      question_number: '1',
      stem: String.raw`\overarc{AB}=\overparen{CD}`,
      equations: [],
      objective_choices: [],
      allow_objective: false,
      allow_subjective: true,
      export_mode: 'subjective',
      meta: {},
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

  assert.doesNotMatch(tex, /\\(?:overarc|overparen|wideparen)\s*\{/);
  assert.match(tex, /\\overset\{\\frown\}\{AB\}/);
  assert.match(tex, /\\overset\{\\frown\}\{CD\}/);
});
