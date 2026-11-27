import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  approvedEngineFigureFor,
  buildEngineFigureRecord,
  figureFormatForProfile,
  figureSizePosition,
  isPrintableEngineTikz,
  mmToEm,
  parseEngineFigures,
  pickEngineFigureVariant,
  storedFigurePosition,
} from '../src/problem_bank/engine_figures.js';
import {
  applyEngineFigureSizes,
  resolveFigureLayout,
} from '../src/problem_bank/render_engine/utils/figure_layout.js';
import { hydrateFiguresForXeLatex } from '../src/problem_bank/render_engine/xelatex_v2/renderer.js';
import { buildDocumentTexSource } from '../src/problem_bank/render_engine/xelatex_v2/template.js';

const PNG_1X1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  'base64',
);
const PDF_BYTES = Buffer.from('%PDF-1.5\n% engine figure\n', 'latin1');
// 엔진이 내는 그리는 글의 모양(머리말 한 줄 + tikzpicture 하나).
const TIKZ_TEXT = [
  '% ygg-figure engine=0.1.0 style=csat-2026.2',
  '\\begin{tikzpicture}[x=1mm,y=-1mm,line join=round]',
  '\\useasboundingbox (0,0) rectangle (52.49,49.15);',
  '\\path[draw,line width=0.285mm,line cap=round] (1,1) -- (40,1) -- (40,30) -- cycle;',
  '\\node[outer sep=0pt,inner sep=0pt,anchor=45] at (1,1) {\\fontsize{10.5pt}{12.6pt}\\selectfont $\\mathrm{A}$};',
  '\\node[outer sep=0pt,inner sep=0pt,anchor=center] at (20,20) {\\fontsize{10.5pt}{12.6pt}\\selectfont $\\left\\{\\dfrac{\\pi}{3}\\right\\}$};',
  '\\end{tikzpicture}%',
  '',
].join('\n');
const ORIGINAL_PATH = 'academy/doc/pdf-figures/13_1.png';

const BUNDLE = {
  format: 'ygg-figure-asset/1',
  id: 'csat-2023-common-13-1',
  engine: '0.1.0',
  style: 'csat-2026.1',
  body_pt: 11.3,
  width_mm: 52.49,
  height_mm: 49.15,
  width_px: 1240,
  height_px: 1162,
};

function record(overrides = {}) {
  return {
    ...buildEngineFigureRecord({
      bundle: BUNDLE,
      figureIndex: 1,
      originalPath: ORIGINAL_PATH,
      pdfPath: 'academy/question-1/1/abc.pdf',
      pngPath: 'academy/question-1/1/abc.png',
      sourcePath: 'academy/question-1/1/abc.json',
      contentHash: 'abc',
      status: 'approved',
      now: '2026-11-25T00:00:00.000Z',
    }),
    ...overrides,
  };
}

function question(engineFigures, layout) {
  return {
    id: 'question-1',
    question_number: '13',
    stem: '그림과 같이 사각형이 있다.\n[그림]',
    choices: [],
    meta: {
      figure_assets: [{
        bucket: 'problem-previews',
        path: ORIGINAL_PATH,
        figure_index: 1,
        mime_type: 'image/png',
        approved: true,
      }],
      ...(layout ? { figure_layout: layout } : {}),
      ...(engineFigures ? { engine_figures: engineFigures } : {}),
    },
  };
}

function storageClient({ failBuckets = [], tikz = TIKZ_TEXT } = {}) {
  const downloads = [];
  return {
    downloads,
    storage: {
      from: (bucket) => ({
        download: async (objectPath) => {
          downloads.push(`${bucket}/${objectPath}`);
          if (failBuckets.includes(bucket)) return { data: null, error: new Error('fetch failed') };
          if (objectPath.endsWith('.tikz')) return { data: new Blob([tikz]), error: null };
          return {
            data: new Blob([bucket === 'problem-figures' ? PDF_BYTES : PNG_1X1]),
            error: null,
          };
        },
      }),
    },
  };
}

async function hydrate(q, client, options) {
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pb-engine-figure-'));
  try {
    const result = await hydrateFiguresForXeLatex([q], client, workDir, options);
    const files = q.figure_local_paths.map((p) => ({
      name: path.basename(p),
      head: fs.readFileSync(p).subarray(0, 5).toString('latin1'),
    }));
    return { result, files };
  } finally {
    fs.rmSync(workDir, { recursive: true, force: true });
  }
}

test('an engine figure record keeps the size relative to the body font', () => {
  const one = record();
  assert.equal(one.status, 'approved');
  assert.equal(one.approved_at, '2026-11-25T00:00:00.000Z');
  // 52.49mm 를 11.3pt 글자 크기로 나눈 값.
  assert.ok(Math.abs(one.width_em - 13.217) < 0.002, `width_em=${one.width_em}`);
  assert.ok(Math.abs(mmToEm(52.49, 11.3) - one.width_em) < 0.001);
  const parsed = parseEngineFigures({ engine_figures: [one, { figure_index: 2 }, null, 'x'] });
  assert.equal(parsed.length, 1, 'rows without a file or a size are ignored');
  assert.equal(parsed[0].pdfPath, 'academy/question-1/1/abc.pdf');
});

test('a draft is not built as approved', () => {
  const one = buildEngineFigureRecord({
    bundle: BUNDLE,
    figureIndex: 1,
    originalPath: ORIGINAL_PATH,
    pdfPath: 'a.pdf',
  });
  assert.equal(one.status, 'draft');
  assert.equal('approved_at' in one, false);
  assert.throws(() => buildEngineFigureRecord({ bundle: {}, figureIndex: 1, pdfPath: 'a.pdf' }));
});

test('only an approved engine figure drawn from the current original is used', () => {
  const asset = { figure_index: 1, path: ORIGINAL_PATH };
  assert.ok(approvedEngineFigureFor({ engine_figures: [record()] }, asset));
  assert.equal(approvedEngineFigureFor({ engine_figures: [record({ status: 'draft' })] }, asset), null);
  assert.equal(approvedEngineFigureFor({ engine_figures: [record({ figure_index: 2 })] }, asset), null);
  assert.equal(
    approvedEngineFigureFor({ engine_figures: [record()] }, { figure_index: 1, path: 'academy/doc/recropped.png' }),
    null,
    'the original was replaced after the figure was drawn',
  );
  assert.equal(approvedEngineFigureFor({}, asset), null);
});

// 크기 표대로 다시 그린 그림(도형만 커지고 글자는 그대로)이 든 묶음.
const SIZED_BUNDLE = {
  ...BUNDLE,
  variants: [
    { format: 'mock', position: 'below-stem', source: 'table', scale: 1.37, width_em: 17.5, height_em: 15.7, pdf: 'figure@mock.below-stem.pdf' },
    { format: 'assignment', position: 'below-stem', source: 'figure', note: '글자가 많다', scale: 0.6, width_em: 11, height_em: 10, pdf: 'figure@assignment.below-stem.pdf', needs_check: true },
    { format: 'naesin', position: 'inline-right', source: 'table', scale: 0.75, width_em: 10, height_em: 9.3, pdf: 'figure@naesin.inline-right.pdf' },
  ],
};

function sizedRecord() {
  return buildEngineFigureRecord({
    bundle: SIZED_BUNDLE,
    figureIndex: 1,
    originalPath: ORIGINAL_PATH,
    pdfPath: 'academy/question-1/1/abc.pdf',
    variantPdfPaths: {
      'mock/below-stem': 'academy/question-1/1/abc@mock.below-stem.pdf',
      'assignment/below-stem': 'academy/question-1/1/abc@assignment.below-stem.pdf',
      // naesin/inline-right 는 올리지 않았다 → 기록하지 않는다.
    },
    status: 'approved',
  });
}

test('the size table: one size per format and position, the natural size otherwise', () => {
  assert.equal(figureFormatForProfile('csat'), 'mock');
  assert.equal(figureFormatForProfile('mock'), 'mock');
  assert.equal(figureFormatForProfile('assignment'), 'assignment');
  assert.equal(figureFormatForProfile('naesin'), 'naesin');
  assert.equal(figureFormatForProfile('gyeongsin'), 'naesin', 'school exam forms are naesin');
  assert.equal(figureSizePosition('between-stem-choices'), 'below-stem');
  assert.equal(figureSizePosition('inline-left'), 'inline-right');
  assert.equal(figureSizePosition('inline-text'), null);

  const one = sizedRecord();
  assert.deepEqual(one.variants.map((v) => `${v.format}/${v.position}`), ['mock/below-stem', 'assignment/below-stem']);
  assert.equal(one.variants[1].source, 'figure');
  assert.equal(one.variants[1].note, '글자가 많다');
  assert.equal(one.variants[1].needs_check, true);

  const [parsed] = parseEngineFigures({ engine_figures: [one] });
  const mock = pickEngineFigureVariant(parsed, { format: 'mock', position: 'between-stem-choices' });
  assert.deepEqual(mock, {
    pdfPath: 'academy/question-1/1/abc@mock.below-stem.pdf', tikzPath: '', widthEm: 17.5, heightEm: 15.7, sized: true,
  });
  // 표에 그 크기 그림이 없으면 제 크기 그림.
  const naesin = pickEngineFigureVariant(parsed, { format: 'naesin', position: 'below-stem' });
  assert.equal(naesin.pdfPath, 'academy/question-1/1/abc.pdf');
  assert.equal(naesin.sized, false);
  assert.equal(pickEngineFigureVariant(parsed, { format: 'mock', position: 'inline-text' }).sized, false);
  assert.equal(pickEngineFigureVariant(parsed, {}).sized, false);

  const meta = { figure_layout: { items: [{ assetKey: 'idx:2', position: 'inline-right' }, { assetKey: 'ord:1', position: 'below-choices' }] } };
  assert.equal(storedFigurePosition(meta, 2, 5), 'inline-right');
  assert.equal(storedFigurePosition(meta, 9, 1), 'below-choices');
  assert.equal(storedFigurePosition({}, 1, 1), 'below-stem');
});

test('printing picks the figure drawn for this format and position', async () => {
  const client = storageClient();
  const q = question([sizedRecord()]);
  const { result } = await hydrate(q, client, { figureFormat: 'mock' });
  assert.equal(result.engineFigureCount, 1);
  assert.deepEqual(client.downloads, ['problem-figures/academy/question-1/1/abc@mock.below-stem.pdf']);
  assert.deepEqual(q.figure_local_infos[0].engineFigure, {
    figureId: 'csat-2023-common-13-1', widthEm: 17.5, heightEm: 15.7, sized: true,
  });
  assert.equal(resolveFigureLayout(q, 11).items[0].widthEm, 17.5);

  // 그 양식의 그림이 없으면 제 크기 그림.
  const other = storageClient();
  const q2 = question([sizedRecord()]);
  await hydrate(q2, other, { figureFormat: 'naesin' });
  assert.deepEqual(other.downloads, ['problem-figures/academy/question-1/1/abc.pdf']);
  assert.ok(Math.abs(q2.figure_local_infos[0].engineFigure.widthEm - 13.217) < 0.002);
});

test('printing takes the vector file of an approved engine figure', async () => {
  const client = storageClient();
  const q = question([record()]);
  const { result, files } = await hydrate(q, client);
  assert.deepEqual(client.downloads, ['problem-figures/academy/question-1/1/abc.pdf']);
  assert.equal(result.engineFigureCount, 1);
  assert.equal(files.length, 1);
  assert.equal(files[0].name, 'fig-question-1-1.pdf');
  assert.equal(files[0].head, '%PDF-');
  const info = q.figure_local_infos[0];
  assert.equal(info.assetKey, 'idx:1');
  assert.equal(info.mimeType, 'application/pdf');
  assert.ok(Math.abs(info.engineFigure.widthEm - 13.217) < 0.002);
  assert.equal(info.widthPx, 1240);
});

test('a draft, a switched-off engine, or a failed download prints the original', async () => {
  const draft = await hydrate(question([record({ status: 'draft' })]), storageClient());
  assert.equal(draft.result.engineFigureCount, 0);
  assert.equal(draft.files[0].name, 'fig-question-1-1.png');

  const off = await hydrate(question([record()]), storageClient(), { engineFigures: false });
  assert.equal(off.result.engineFigureCount, 0);
  assert.equal(off.files[0].name, 'fig-question-1-1.png');

  const client = storageClient({ failBuckets: ['problem-figures'] });
  const q = question([record()]);
  const failed = await hydrate(q, client);
  assert.equal(failed.result.engineFigureCount, 0);
  assert.equal(failed.result.appliedCount, 1);
  assert.equal(failed.files[0].name, 'fig-question-1-1.png');
  assert.equal(q.figure_local_infos[0].engineFigure, undefined);
});

test('an engine figure is printed at its own size, where the stored layout says', () => {
  const layout = {
    version: 1,
    groups: [],
    items: [{ assetKey: 'idx:1', widthEm: 12, position: 'inline-right', anchor: 'right', offsetXEm: 0, offsetYEm: 1.5 }],
  };
  const q = question([record()], layout);
  q.figure_local_infos = [{ assetKey: 'idx:1', figureIndex: 1, engineFigure: { widthEm: 13.217, heightEm: 12.376 } }];
  const item = resolveFigureLayout(q, 11).items[0];
  assert.equal(item.widthEm, 13.217);
  assert.equal(item.position, 'inline-right');
  assert.equal(item.offsetYEm, 1.5);

  const plain = question(null, layout);
  plain.figure_local_infos = [{ assetKey: 'idx:1', figureIndex: 1 }];
  assert.equal(resolveFigureLayout(plain, 11).items[0].widthEm, 12, 'an image figure keeps the stored width');
});

test('the size follows the same key order as the renderer and fills in a missing item', () => {
  const infos = [{ assetKey: 'idx:1', figureIndex: 1, engineFigure: { widthEm: 18, heightEm: 9 } }];
  const byOrder = applyEngineFigureSizes(
    { version: 1, groups: [], items: [{ assetKey: 'ord:1', widthEm: 20, position: 'below-choices' }] },
    { figure_local_infos: infos },
  );
  assert.equal(byOrder.items.length, 1);
  assert.equal(byOrder.items[0].widthEm, 18);
  assert.equal(byOrder.items[0].position, 'below-choices');

  const none = applyEngineFigureSizes(null, { figure_local_infos: infos });
  assert.deepEqual(none.items.map((it) => [it.assetKey, it.widthEm, it.position]), [['idx:1', 18, 'below-stem']]);
  assert.equal(applyEngineFigureSizes(null, { figure_local_infos: [{ assetKey: 'idx:1' }] }), null);
});

test('the print source includes the vector figure at its own width', () => {
  const q = question([record()], {
    version: 1,
    groups: [],
    items: [{ assetKey: 'idx:1', widthEm: 12, position: 'below-stem', anchor: 'center', offsetXEm: 0, offsetYEm: 0 }],
  });
  q.figure_local_paths = ['C:/work/fig-question-1-1.pdf'];
  q.figure_local_infos = [{
    assetKey: 'idx:1',
    figureIndex: 1,
    widthPx: 1240,
    heightPx: 1162,
    engineFigure: { widthEm: 13.217, heightEm: 12.376 },
  }];
  const tex = buildDocumentTexSource([q], { profile: 'naesin', paper: 'A4', columns: 1 });
  // 제 크기로 찍되, 단이 더 좁으면 단 폭까지만 줄인다.
  assert.match(
    tex,
    /\\includegraphics\[width=13\.22em,max width=\\linewidth,keepaspectratio\]\{C:\/work\/fig-question-1-1\.pdf\}/,
  );

  // 원본 그림은 예전 그대로 찍는다.
  q.figure_local_infos = [{ assetKey: 'idx:1', figureIndex: 1, widthPx: 484, heightPx: 450 }];
  q.figure_local_paths = ['C:/work/fig-question-1-1.png'];
  const plain = buildDocumentTexSource([q], { profile: 'naesin', paper: 'A4', columns: 1 });
  assert.match(plain, /\\includegraphics\[width=12\.00em\]\{C:\/work\/fig-question-1-1\.png\}/);
});

// 그림 속 글자가 실리는 양식의 본문 글자와 같게: 그리는 글(TikZ)을 인쇄 문서 안에서 조판한다.
function drawnRecord() {
  return buildEngineFigureRecord({
    bundle: SIZED_BUNDLE,
    figureIndex: 1,
    originalPath: ORIGINAL_PATH,
    pdfPath: 'academy/question-1/1/abc.pdf',
    tikzPath: 'academy/question-1/1/abc.tikz',
    variantPdfPaths: { 'mock/below-stem': 'academy/question-1/1/abc@mock.below-stem.pdf' },
    variantTikzPaths: { 'mock/below-stem': 'academy/question-1/1/abc@mock.below-stem.tikz' },
    status: 'approved',
  });
}

test('a record keeps where the drawing source of each size is', () => {
  const one = drawnRecord();
  assert.equal(one.tikz_path, 'academy/question-1/1/abc.tikz');
  assert.equal(one.variants[0].tikz_path, 'academy/question-1/1/abc@mock.below-stem.tikz');
  const [parsed] = parseEngineFigures({ engine_figures: [one] });
  assert.equal(
    pickEngineFigureVariant(parsed, { format: 'mock', position: 'below-stem' }).tikzPath,
    'academy/question-1/1/abc@mock.below-stem.tikz',
  );
  assert.equal(pickEngineFigureVariant(parsed, { format: 'naesin', position: 'below-stem' }).tikzPath, 'academy/question-1/1/abc.tikz');
  assert.equal('tikz_path' in record(), false, 'a record without a drawing source has no such field');
});

test('only a drawing the engine wrote is put into the print source', () => {
  assert.equal(isPrintableEngineTikz(TIKZ_TEXT), true);
  assert.equal(isPrintableEngineTikz(''), false);
  assert.equal(isPrintableEngineTikz(TIKZ_TEXT.replace('% ygg-figure', '% other')), false);
  assert.equal(isPrintableEngineTikz(TIKZ_TEXT.replace('$\\mathrm{A}$', '\\input{secret}')), false);
  assert.equal(isPrintableEngineTikz(TIKZ_TEXT.replace('$\\mathrm{A}$', '\\def\\x{1}')), false);
  assert.equal(isPrintableEngineTikz(TIKZ_TEXT.replace('$\\mathrm{A}$', '$A$}')), false, 'an unbalanced brace would break the page');
  assert.equal(isPrintableEngineTikz(`${TIKZ_TEXT}\\end{document}`), false);
  assert.equal(isPrintableEngineTikz(`${TIKZ_TEXT}${TIKZ_TEXT}`), false);
});

test('printing takes the drawing source too, and falls back to the PDF when it cannot be used', async () => {
  const client = storageClient();
  const q = question([drawnRecord()]);
  const { result } = await hydrate(q, client, { figureFormat: 'mock' });
  assert.equal(result.engineFigureCount, 1);
  assert.deepEqual(client.downloads, [
    'problem-figures/academy/question-1/1/abc@mock.below-stem.pdf',
    'problem-figures/academy/question-1/1/abc@mock.below-stem.tikz',
  ]);
  assert.equal(path.basename(q.figure_local_infos[0].engineFigure.tikzPath), 'fig-question-1-1.tikz');
  assert.equal(path.basename(q.figure_local_paths[0]), 'fig-question-1-1.pdf');

  const unsafe = storageClient({ tikz: TIKZ_TEXT.replace('$\\mathrm{A}$', '\\input{secret}') });
  const q2 = question([drawnRecord()]);
  const second = await hydrate(q2, unsafe, { figureFormat: 'mock' });
  assert.equal(second.result.engineFigureCount, 1, 'the figure is still printed, from its PDF');
  assert.equal(q2.figure_local_infos[0].engineFigure.tikzPath, undefined);
});

test('the print source typesets the drawing itself and leaves room under a wrapped engine figure', () => {
  const layout = (position) => ({
    version: 1,
    groups: [],
    items: [{ assetKey: 'idx:1', widthEm: 12, position, anchor: 'center', offsetXEm: 0, offsetYEm: 0 }],
  });
  const withFigure = (position, engineFigure) => {
    const q = question([record()], layout(position));
    q.stem = '[그림]\n그림과 같이 사각형이 있다. 이 사각형의 넓이를 구하시오.';
    q.figure_local_paths = [engineFigure ? 'C:/work/fig-question-1-1.pdf' : 'C:/work/fig-question-1-1.png'];
    q.figure_local_infos = [{
      assetKey: 'idx:1', figureIndex: 1, widthPx: 1240, heightPx: 1162, ...(engineFigure ? { engineFigure } : {}),
    }];
    const tex = buildDocumentTexSource([q], { profile: 'naesin', paper: 'A4', columns: 1 });
    // 머리말(명령을 정의하는 곳)이 아니라 본문에서 찾는다.
    return tex.slice(tex.indexOf('\\begin{document}'));
  };
  const drawn = { widthEm: 13.217, heightEm: 12.376, tikzPath: 'C:\\work\\fig-question-1-1.tikz' };

  const below = withFigure('below-stem', drawn);
  assert.ok(
    below.includes('\\YggEngineFigure{13.22em}{C:/work/fig-question-1-1.tikz}{C:/work/fig-question-1-1.pdf}'),
    'the drawing is typeset in the document, with the PDF as the fallback',
  );
  assert.equal(below.includes('\\YggWrapTight=1'), false);

  const wrapped = withFigure('inline-right', drawn);
  assert.ok(wrapped.includes('\\YggWrapTight=1\\relax\n\\YggMeasuredWrapAuto{r}'));
  assert.ok(wrapped.includes('\\YggWrapTight=0\\relax'));

  // 원본 그림의 어울림은 예전 그대로다.
  const plain = withFigure('inline-right', null);
  assert.ok(plain.includes('\\YggMeasuredWrapAuto{r}'));
  assert.equal(plain.includes('\\YggWrapTight=1'), false);
});