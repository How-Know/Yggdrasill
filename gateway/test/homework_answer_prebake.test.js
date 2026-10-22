import test from 'node:test';
import assert from 'node:assert/strict';

import {
  answerRenderKindForMode,
  effectiveQuestionMode,
  filterUidsBySnapshot,
  originalQuestionMode,
  presetForcesOriginalMode,
  presetQuestionModeMap,
  presetSelectedQuestionUids,
  textbookAnswerKindNeedsRender,
} from '../src/problem_bank/homework_answer_prebake.js';

test('preset uids come from the column first, then render_config', () => {
  assert.deepEqual(
    presetSelectedQuestionUids({ selected_question_uids: [' a ', '', 'b'] }),
    ['a', 'b'],
  );
  assert.deepEqual(
    presetSelectedQuestionUids({
      selected_question_uids: [],
      render_config: {
        selectedQuestionUidsOrdered: [],
        selectedQuestionIdsOrdered: ['x', 'y'],
      },
    }),
    ['x', 'y'],
  );
  assert.deepEqual(presetSelectedQuestionUids(null), []);
});

test('snapshot narrows the preset unless it looks truncated', () => {
  const preset = ['a', 'b', 'c', 'd'];
  assert.deepEqual(filterUidsBySnapshot(preset, []), preset);
  assert.deepEqual(filterUidsBySnapshot(preset, ['a', 'b', 'c']), ['a', 'b', 'c']);
  assert.deepEqual(filterUidsBySnapshot(preset, ['a', 'b']), preset);
  assert.deepEqual(filterUidsBySnapshot(preset, ['z']), []);
});

test('original mode follows question_type before choices', () => {
  assert.equal(originalQuestionMode({ question_type: '서술형' }), 'essay');
  assert.equal(originalQuestionMode({ question_type: '객관식' }), 'objective');
  assert.equal(
    originalQuestionMode({ question_type: '주관식', objective_choices: [1, 2, 3] }),
    'subjective',
  );
  assert.equal(originalQuestionMode({ choices: [1, 2] }), 'objective');
  assert.equal(originalQuestionMode({}), 'subjective');
});

test('preset mode wins only when the question allows it', () => {
  const objectiveQuestion = {
    id: 'q1',
    question_uid: 'u1',
    question_type: '객관식',
  };
  assert.equal(
    effectiveQuestionMode(objectiveQuestion, {
      modeByQuestionUid: { u1: 'subjective' },
    }),
    'subjective',
  );
  assert.equal(effectiveQuestionMode(objectiveQuestion), 'objective');
  assert.equal(
    effectiveQuestionMode(
      { ...objectiveQuestion, allow_subjective: false },
      { modeByQuestionUid: { u1: 'subjective' } },
    ),
    'objective',
  );
  assert.equal(
    effectiveQuestionMode(objectiveQuestion, {
      modeByQuestionUid: { u1: 'subjective' },
      forceOriginalMode: true,
    }),
    'objective',
  );
});

test('render kind skips objective and maps essay', () => {
  assert.equal(answerRenderKindForMode('objective'), null);
  assert.equal(answerRenderKindForMode('essay'), 'essay');
  assert.equal(answerRenderKindForMode('subjective'), 'subjective');
});

test('textbook objective and image answers are not baked', () => {
  assert.equal(textbookAnswerKindNeedsRender('objective'), false);
  assert.equal(textbookAnswerKindNeedsRender('image'), false);
  assert.equal(textbookAnswerKindNeedsRender('subjective'), true);
  assert.equal(textbookAnswerKindNeedsRender(''), true);
});

test('preset helpers read mode map and naesin link', () => {
  assert.deepEqual(
    presetQuestionModeMap({ question_mode_by_question_uid: { u1: 'essay', u2: '' } }),
    { u1: 'essay' },
  );
  assert.equal(presetForcesOriginalMode({ render_config: { naesinLinkKey: 'k' } }), true);
  assert.equal(presetForcesOriginalMode({ render_config: {} }), false);
});