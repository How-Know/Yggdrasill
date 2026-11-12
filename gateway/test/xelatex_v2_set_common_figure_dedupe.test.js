import test from 'node:test';
import assert from 'node:assert/strict';

import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

const SHARED = 'academy/figures/book/p11_shared_cube.png';

function setItem(n, itemStoragePath, stemMarker = false) {
  return {
    id: `q-set-${n}`,
    question_uid: `q-set-${n}`,
    question_number: `0${n}`,
    stem: `${stemMarker ? '[그림]\n[문단]\n' : ''}${n === 1 ? '모서리 AB와 모서리 AE가 만나서 생기는 교점' : '면 ABCD와 평행한 면'}`,
    equations: [],
    objective_choices: [],
    allow_objective: false,
    allow_subjective: true,
    export_mode: 'subjective',
    figure_local_paths: [`C:/work/fig-q-set-${n}-1.png`],
    figure_local_infos: [{ path: `C:/work/fig-q-set-${n}-1.png`, storagePath: itemStoragePath, figureIndex: 1 }],
    common_figure_local_paths: ['C:/work/common-fig-1.png'],
    common_figure_local_infos: [{ path: 'C:/work/common-fig-1.png', storagePath: SHARED, figureIndex: 1 }],
    meta: {
      set_model: {
        version: 1,
        set_type: 'independent_set',
        set_key: 'p11-01-06',
        common_stem: '그림과 같은 입체도형에 대하여 다음을 구하여라.[문단][그림]',
      },
    },
  };
}

function build(itemStoragePath, stemMarker = false) {
  return buildDocumentTexSource(
    [setItem(1, itemStoragePath, stemMarker), setItem(2, itemStoragePath, stemMarker)],
    { profile: 'naesin', paper: 'A4', columns: 1, hidePreviewHeader: true },
  );
}

test('V2 renderer draws the common figure once when set items carry their own copy of it', () => {
  for (const itemPath of [SHARED, 'academy/figures/book/item_copy.png']) {
    const tex = build(itemPath);
    assert.equal((tex.match(/common-fig-1\.png/g) || []).length, 1);
    assert.equal((tex.match(/fig-q-set-\d-1\.png/g) || []).length, 0);
  }
});

test('V2 renderer keeps a set item figure that has its own figure slot in the stem', () => {
  const tex = build('academy/figures/book/other.png', true);
  assert.equal((tex.match(/common-fig-1\.png/g) || []).length, 1);
  assert.equal((tex.match(/fig-q-set-\d-1\.png/g) || []).length, 2);
});
