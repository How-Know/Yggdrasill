import test from 'node:test';
import assert from 'node:assert/strict';

import {
  applyQuestionModesForExport,
  buildRenderConfigFromJob,
  computeRenderHash,
} from '../src/problem_bank_export_worker.js';

function makeQuestion(overrides = {}) {
  return {
    id: 'q-1',
    question_number: '1',
    question_type: '?????,
    stem: '??',
    choices: [
      { label: '??, text: '?' },
      { label: '??, text: '?? },
    ],
    objective_choices: [],
    allow_objective: true,
    allow_subjective: true,
    objective_answer_key: '??,
    subjective_answer: '??,
    reviewer_notes: '',
    figure_refs: [],
    equations: [],
    meta: {},
    ...overrides,
  };
}

test('render config: legacy key alias and ordered ids', () => {
  const job = {
    template_profile: 'naesin',
    paper_size: 'A4',
    include_answer_sheet: true,
    include_explanation: false,
    selected_question_ids: ['q-2', 'q-1', 'q-3'],
    options: {
      layout_columns: '2??,
      perPage: '6',
      mode: '?????,
      selectedQuestionIdsOrdered: ['q-3', 'q-1', 'q-2'],
      questionModeByQuestionId: {
        'q-1': 'objective',
      },
      targetDpi: 500,
      pageMargin: 52,
    },
  };
  const config = buildRenderConfigFromJob(job);
  assert.equal(config.layoutColumns, 2);
  assert.equal(config.maxQuestionsPerPage, 6);
  assert.equal(config.questionMode, 'subjective');
  assert.deepEqual(config.selectedQuestionIdsOrdered, ['q-3', 'q-1', 'q-2']);
  assert.equal(config.figureQuality.targetDpi, 500);
  assert.equal(config.layoutTuning.pageMargin, 52);
  assert.equal(config.questionModeByQuestionId['q-1'], 'objective');
  assert.equal(config.questionModeByQuestionId['q-2'], 'subjective');
});

test('render hash: deterministic for same semantic payload', () => {
  const configA = {
    renderConfigVersion: 'pb_render_v26h_overlay_center_gap',
    templateProfile: 'naesin',
    paperSize: 'A4',
    includeAnswerSheet: true,
    includeExplanation: false,
    layoutColumns: 2,
    maxQuestionsPerPage: 4,
    questionMode: 'original',
    layoutTuning: { pageMargin: 46, columnGap: 18 },
    figureQuality: { targetDpi: 450, minDpi: 300 },
    selectedQuestionIdsOrdered: ['q-1', 'q-2'],
    questionModeByQuestionId: { 'q-2': 'subjective', 'q-1': 'objective' },
    font: { family: 'HCRBatang', size: 11.3 },
  };
  const configB = {
    ...configA,
    questionModeByQuestionId: { 'q-1': 'objective', 'q-2': 'subjective' },
  };
  assert.equal(computeRenderHash(configA), computeRenderHash(configB));
});

test('question mode map: per-question override is applied', () => {
  const q1 = makeQuestion({ id: 'q-1', question_type: '????? });
  const q2 = makeQuestion({
    id: 'q-2',
    question_type: '?????,
    choices: [],
    objective_choices: [],
    allow_objective: false,
    allow_subjective: true,
    subjective_answer: '??,
  });
  const applied = applyQuestionModesForExport(
    [q1, q2],
    { 'q-1': 'objective', 'q-2': 'subjective' },
    'original',
  );
  assert.equal(applied.modeByQuestionId['q-1'], 'objective');
  assert.equal(applied.modeByQuestionId['q-2'], 'subjective');
  assert.equal(applied.questions[0].question_type, '?????);
  assert.equal(applied.questions[0].choices.length >= 2, true);
  assert.equal(applied.questions[1].question_type, '?????);
  assert.equal(applied.questions[1].choices.length, 0);
});
