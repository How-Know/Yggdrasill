import assert from 'node:assert/strict';
import test from 'node:test';

import { approvedEngineFigureFor, parseEngineFigures, pickEngineFigureVariant } from '../src/problem_bank/engine_figures.js';
import {
  bundleContentHash,
  bundleFileNames,
  originalStillThere,
  planEngineFigurePublish,
} from '../src/problem_bank/engine_figure_publish.js';

const ACADEMY = '3ff51b8d-3cfb-4a36-a1a1-b63aebbde677';
const QUESTION = '88365d36-8ff6-43a8-a2bf-0ecf58620192';
const ORIGINAL = `${ACADEMY}/doc/pdf-figures/run/18_3.png`;
const TIKZ = [
  '% ygg-figure engine=0.1.0 style=csat-2026.2',
  '\\begin{tikzpicture}[x=1mm,y=-1mm,line join=round]',
  '\\path[draw,line width=0.285mm] (1,1) -- (40,1);',
  '\\end{tikzpicture}%',
  '',
].join('\n');

// 엔진이 내보낸 묶음(asset.json)의 모양. 본문 아래와 선지 아래는 같은 파일을 쓴다.
const BUNDLE = {
  format: 'ygg-figure-asset/1',
  id: 'csat-2019-na-18-3',
  kind: 'plane',
  tags: ['series-repeat', 'sector'],
  elements: ['quadrilateral', 'arc'],
  size_class: 'large',
  engine: '0.1.0',
  style: 'csat-2026.2',
  body_pt: 11.3,
  width_mm: 104.35,
  height_mm: 66.72,
  width_px: 2465,
  height_px: 1577,
  files: { pdf: 'figure.pdf', png: 'figure.png', source: 'figure.json', tikz: 'figure.tikz' },
  variants: [
    { format: 'assignment', position: 'below-stem', source: 'figure', note: '본문 너비 전체', scale: 0.96, width_em: 25.037, height_em: 15.667, pdf: 'figure@assignment.below-stem.pdf', tikz: 'figure@assignment.below-stem.tikz' },
    { format: 'assignment', position: 'below-choices', source: 'figure', note: '본문 너비 전체', scale: 0.96, width_em: 25.037, height_em: 15.667, pdf: 'figure@assignment.below-stem.pdf', tikz: 'figure@assignment.below-stem.tikz' },
    { format: 'mock', position: 'inline-right', source: 'table', scale: 0.414, width_em: 11.734, height_em: 7.289, pdf: 'figure@mock.inline-right.pdf', tikz: 'figure@mock.inline-right.tikz', needs_check: true },
  ],
};

function inputs(overrides = {}) {
  const names = bundleFileNames(BUNDLE);
  return {
    bundle: BUNDLE,
    fileHashes: Object.fromEntries(names.map((name) => [name, `hash-of-${name}`])),
    tikzTexts: Object.fromEntries(names.filter((name) => name.endsWith('.tikz')).map((name) => [name, TIKZ])),
    academyId: ACADEMY,
    questionId: QUESTION,
    figureIndex: 3,
    originalPath: ORIGINAL,
    status: 'approved',
    now: '2026-11-26T00:00:00.000Z',
    ...overrides,
  };
}

test('a bundle lists each file once, even when sizes share it', () => {
  assert.deepEqual(bundleFileNames(BUNDLE), [
    'asset.json',
    'figure.json',
    'figure.pdf',
    'figure.png',
    'figure.tikz',
    'figure@assignment.below-stem.pdf',
    'figure@assignment.below-stem.tikz',
    'figure@mock.inline-right.pdf',
    'figure@mock.inline-right.tikz',
  ]);
});

test('files go under academy/question/index/content hash, and the record points there', () => {
  const plan = planEngineFigurePublish(inputs());
  assert.deepEqual(plan.problems, []);
  assert.match(plan.base, new RegExp(`^${ACADEMY}/${QUESTION}/3/[0-9a-f]{12}$`));
  assert.equal(plan.uploads.length, 9);
  assert.ok(plan.uploads.every((up) => up.path === `${plan.base}/${up.name}`));
  assert.equal(plan.uploads.find((up) => up.name === 'figure.tikz').contentType, 'text/plain');
  assert.equal(plan.uploads.find((up) => up.name === 'figure.pdf').contentType, 'application/pdf');

  const { record } = plan;
  assert.equal(record.figure_index, 3);
  assert.equal(record.status, 'approved');
  assert.equal(record.original_path, ORIGINAL);
  assert.equal(record.bucket, 'problem-figures');
  assert.equal(record.pdf_path, `${plan.base}/figure.pdf`);
  assert.equal(record.tikz_path, `${plan.base}/figure.tikz`);
  assert.equal(record.content_hash, plan.contentHash);
  assert.deepEqual(record.tags, ['series-repeat', 'sector']);
  assert.deepEqual(record.elements, ['quadrilateral', 'arc']);
  assert.equal(record.kind, 'plane');
  assert.equal(record.size_class, 'large');
  assert.equal(record.variants.length, 3);
  assert.equal(record.variants[0].source, 'figure');

  // 인쇄 쪽이 이 줄을 그대로 읽어 쓸 수 있어야 한다.
  const meta = { engine_figures: [record] };
  const found = approvedEngineFigureFor(meta, { figure_index: 3, path: ORIGINAL });
  assert.ok(found);
  const [parsed] = parseEngineFigures(meta);
  assert.equal(
    pickEngineFigureVariant(parsed, { format: 'assignment', position: 'below-choices' }).pdfPath,
    `${plan.base}/figure@assignment.below-stem.pdf`,
  );
});

test('a changed figure gets a new place, the same figure the same place', () => {
  const first = planEngineFigurePublish(inputs());
  const again = planEngineFigurePublish(inputs());
  assert.equal(first.base, again.base);
  const changed = inputs();
  changed.fileHashes['figure.pdf'] = 'another';
  assert.notEqual(planEngineFigurePublish(changed).base, first.base);
  assert.notEqual(bundleContentHash({ a: '1' }), bundleContentHash({ a: '2' }));
});

test('nothing is planned when the figure cannot be tied to its question or a file is missing', () => {
  assert.ok(planEngineFigurePublish(inputs({ bundle: {} })).problems.length > 0);
  assert.ok(planEngineFigurePublish(inputs({ academyId: '' })).problems.length > 0);
  assert.ok(planEngineFigurePublish(inputs({ originalPath: 'other-academy/doc/a.png' })).problems.length > 0);
  assert.ok(planEngineFigurePublish(inputs({ figureIndex: 0 })).problems.length > 0);
  const missing = inputs();
  delete missing.fileHashes['figure@mock.inline-right.pdf'];
  const plan = planEngineFigurePublish(missing);
  assert.ok(plan.problems.some((p) => p.includes('figure@mock.inline-right.pdf')));
  assert.equal(plan.record, null);
  assert.deepEqual(plan.uploads, []);
});

test('a drawing that cannot go into the print source is left out of the record, with a warning', () => {
  const bad = inputs();
  bad.tikzTexts['figure@mock.inline-right.tikz'] = TIKZ.replace('\\path', '\\input{secret}\\path');
  const plan = planEngineFigurePublish(bad);
  assert.deepEqual(plan.problems, []);
  assert.ok(plan.warnings.some((w) => w.includes('figure@mock.inline-right.tikz')));
  const variant = plan.record.variants.find((v) => v.format === 'mock');
  assert.equal('tikz_path' in variant, false);
  assert.ok(variant.pdf_path.endsWith('figure@mock.inline-right.pdf'));
});

test('label overlaps the engine reported are passed on as warnings', () => {
  const bundle = { ...BUNDLE, variants: [{ ...BUNDLE.variants[0], label_overlaps: ['H', 'B'] }, ...BUNDLE.variants.slice(1)] };
  const plan = planEngineFigurePublish(inputs({ bundle }));
  assert.ok(plan.warnings.some((w) => w.includes('H, B')));
});

test('the original must still be at the same place', () => {
  const assets = [{ figure_index: 3, path: ORIGINAL }, { figure_index: 1, path: 'x.png' }];
  assert.equal(originalStillThere(assets, 3, ORIGINAL), true);
  assert.equal(originalStillThere(assets, 1, ORIGINAL), false);
  assert.equal(originalStillThere([{ figure_index: 3, path: 'recropped.png' }], 3, ORIGINAL), false);
  assert.equal(originalStillThere(null, 3, ORIGINAL), false);
});
