import test from 'node:test';
import assert from 'node:assert/strict';

import { applyQuestionOverride, overridePreviewKey } from '../src/problem_bank/preview_overrides.js';

const row = {
  id: 'q1',
  stem: '옛 본문[그림]',
  choices: [],
  question_type: '주관식',
  allow_objective: false,
  allow_subjective: true,
  figure_refs: ['[그림]'],
  meta: { figure_assets: [{ figure_index: 1, path: 'a.png' }], set_model: { commonStem: '옛 지시문', set_type: 'independent_set' } },
};

test('반영 대기 값이 없으면 문항 행을 그대로 쓴다', () => {
  assert.equal(applyQuestionOverride(row, undefined), row);
});

test('반영 대기 본문·그림·공통 발문·유형을 덮어 그리고 원래 행은 바꾸지 않는다', () => {
  const out = applyQuestionOverride(row, {
    stem: '새 본문[그림]\n[그림]',
    common_stem: '새 지시문',
    figure_assets: [{ figure_index: 1, path: 'a.png' }, { figure_index: 2, path: 'b.png' }],
    figure_layout: { items: [{ assetKey: 'idx:1', widthEm: 12 }] },
    question_type: '객관식',
    allow_objective: true,
  });
  assert.equal(out.stem, '새 본문[그림]\n[그림]');
  assert.equal(out.question_type, '객관식');
  assert.equal(out.allow_objective, true);
  assert.equal(out.meta.figure_count, 2);
  assert.deepEqual(out.figure_refs, ['[그림]', '[그림]']);
  assert.equal(out.meta.set_model.common_stem, '새 지시문');
  assert.equal(out.meta.set_model.commonStem, undefined);
  assert.equal(out.meta.set_model.set_type, 'independent_set');
  assert.equal(row.stem, '옛 본문[그림]');
  assert.equal(row.meta.set_model.commonStem, '옛 지시문');
});

test('덮어쓴 카드 경로는 내용이 바뀌면 달라진다', () => {
  assert.notEqual(overridePreviewKey('q1', { stem: 'a' }), overridePreviewKey('q1', { stem: 'b' }));
  assert.equal(overridePreviewKey('q1', { stem: 'a' }), overridePreviewKey('q1', { stem: 'a' }));
});
