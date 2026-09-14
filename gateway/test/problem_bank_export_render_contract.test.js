import test from 'node:test';
import assert from 'node:assert/strict';

import {
  applyPublishedQuestionFilter,
  applyQuestionModesForExport,
  buildRenderConfigFromJob,
  computeRenderHash,
} from '../src/problem_bank_export_worker.js';

test('export queries only published questions', () => {
  const calls = [];
  const query = {
    eq(column, value) {
      calls.push([column, value]);
      return this;
    },
  };
  assert.equal(applyPublishedQuestionFilter(query), query);
  assert.deepEqual(calls, [['is_published', true]]);
});

function makeQuestion(overrides = {}) {
  return {
    id: 'q-1',
    question_number: '1',
    question_type: '\uAC1D\uAD00\uC2DD',
    stem: '\uBCF8\uBB38',
    choices: [
      { label: '\u2460', text: '1' },
      { label: '\u2461', text: '2' },
    ],
    objective_choices: [],
    allow_objective: true,
    allow_subjective: true,
    objective_answer_key: '\u2460',
    subjective_answer: '\uC815\uB2F5',
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
      layout_columns: '2\uB2E8',
      perPage: '6',
      mode: '\uC8FC\uAD00\uC2DD',
      selectedQuestionIdsOrdered: ['q-3', 'q-1', 'q-2'],
      questionModeByQuestionId: {
        'q-1': 'objective',
      },
      naesinLinkKey: 'naesin|school|2026',
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
  assert.equal(config.naesinLinkKey, 'naesin|school|2026');
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
  const q1 = makeQuestion({ id: 'q-1', question_type: '\uAC1D\uAD00\uC2DD' });
  const q2 = makeQuestion({
    id: 'q-2',
    question_type: '\uC8FC\uAD00\uC2DD',
    choices: [],
    objective_choices: [],
    allow_objective: false,
    allow_subjective: true,
    subjective_answer: '\uC815\uB2F5',
  });
  const applied = applyQuestionModesForExport(
    [q1, q2],
    { 'q-1': 'objective', 'q-2': 'subjective' },
    'original',
  );
  assert.equal(applied.modeByQuestionUid['q-1'], 'objective');
  assert.equal(applied.modeByQuestionUid['q-2'], 'subjective');
  assert.equal(applied.questions[0].question_type, '\uAC1D\uAD00\uC2DD');
  assert.equal(applied.questions[0].choices.length >= 2, true);
  assert.equal(applied.questions[1].question_type, '\uC8FC\uAD00\uC2DD');
  assert.equal(applied.questions[1].choices.length, 0);
});

test('original subjective stays subjective when AI objective choices exist', () => {
  const question = makeQuestion({
    question_type: '\uC8FC\uAD00\uC2DD',
    choices: [],
    objective_choices: [
      { label: '\u2460', text: '\uC624\uB2F5' },
      { label: '\u2461', text: '\uC815\uB2F5' },
    ],
    objective_answer_key: '\u2461',
    subjective_answer: '42',
  });
  const applied = applyQuestionModesForExport(
    [question],
    { 'q-1': 'objective' },
    'original',
    { forceOriginalMode: true },
  );
  assert.equal(applied.modeByQuestionUid['q-1'], 'subjective');
  assert.equal(applied.questions[0].question_type, '\uC8FC\uAD00\uC2DD');
  assert.equal(applied.questions[0].choices.length, 0);
  assert.equal(applied.questions[0].export_answer, '42');
});

test('regular assignment keeps explicit objective selection', () => {
  const question = makeQuestion({
    question_type: '\uC8FC\uAD00\uC2DD',
    choices: [],
    objective_choices: [
      { label: '\u2460', text: '\uC624\uB2F5' },
      { label: '\u2461', text: '\uC815\uB2F5' },
    ],
    objective_answer_key: '\u2461',
    subjective_answer: '42',
  });
  const applied = applyQuestionModesForExport(
    [question],
    { 'q-1': 'objective' },
    'original',
  );
  assert.equal(applied.modeByQuestionUid['q-1'], 'objective');
  assert.equal(applied.questions[0].question_type, '\uAC1D\uAD00\uC2DD');
  assert.equal(applied.questions[0].export_answer, '\u2461');
});
