import test from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';

import {
  DEFAULT_TEXT_EM_1K,
  buildPdfFigureLayout,
  calibrateTextEm1k,
  countTextLines,
  detectFigurePosition,
  figureAnchor,
  figureMarkersSideBySide,
  figureSideCandidate,
  figureWidthEm,
} from '../src/problem_bank/extract_engines/vlm/figure_geometry.js';

test('figure width follows the source bbox width in body-text em', () => {
  assert.equal(figureWidthEm([0, 100, 100, 275], 17.5), 10);
  assert.equal(figureWidthEm([0, 100, 100, 275]), 175 / DEFAULT_TEXT_EM_1K);
  assert.equal(figureWidthEm([0, 0, 100, 1000], 17.5), 30);
  assert.equal(figureWidthEm(null), null);
});

test('calibration uses the median of in-region single-figure samples and needs enough of them', () => {
  const sample = (ratio) => ({ bbox1k: [10, 100, 60, 280], widthEm: 20, ratio, region1k: [0, 50, 100, 500] });
  assert.equal(calibrateTextEm1k(Array.from({ length: 10 }, () => sample(2))), null);
  const samples = [
    ...Array.from({ length: 20 }, () => sample(1.94)),
    { bbox1k: [10, 100, 60, 280], widthEm: 20, ratio: 1.9, region1k: [500, 50, 600, 500] },
  ];
  assert.equal(calibrateTextEm1k(samples), 17.46);
});

test('side candidate and anchor come from where the figure sits inside the item region', () => {
  const region = [0, 0, 300, 400];
  assert.equal(figureSideCandidate([10, 250, 100, 390], region), 'right');
  assert.equal(figureSideCandidate([10, 10, 100, 150], region), 'left');
  assert.equal(figureSideCandidate([10, 100, 100, 300], region), null);
  assert.equal(figureSideCandidate([500, 250, 600, 390], region), null);
  assert.equal(figureAnchor([150, 20, 250, 150], region), 'left');
  assert.equal(figureAnchor([150, 120, 250, 280], region), 'center');
});

test('text lines need wide, low, many-stroke row runs', () => {
  const textRow = { wide: true, segments: 9 };
  const outlineRow = { wide: true, segments: 2 };
  const blank = { wide: false, segments: 0 };
  assert.equal(countTextLines([blank, textRow, textRow, textRow, textRow, blank]), 1);
  assert.equal(countTextLines([blank, outlineRow, outlineRow, outlineRow, outlineRow, blank]), 0);
  assert.equal(countTextLines(Array.from({ length: 50 }, () => textRow), { maxHeight: 20 }), 0);
});

async function pageWith({ textBesideFigure }) {
  const W = 1000;
  const H = 1400;
  const composites = [
    { input: { create: { width: 200, height: 160, channels: 3, background: '#000000' } }, left: 650, top: 100 },
  ];
  if (textBesideFigure) {
    for (let line = 0; line < 3; line++) {
      for (let g = 0; g < 20; g++) {
        composites.push({
          input: { create: { width: 12, height: 18, channels: 3, background: '#000000' } },
          left: 120 + g * 22,
          top: 110 + line * 40,
        });
      }
    }
  }
  return sharp({ create: { width: W, height: H, channels: 3, background: '#ffffff' } })
    .composite(composites)
    .png()
    .toBuffer();
}

test('figure on the right with body text beside it is placed inline-right', async () => {
  const region = [50, 100, 300, 900];
  const bbox = [71, 650, 186, 850];
  assert.equal(await detectFigurePosition(await pageWith({ textBesideFigure: true }), bbox, region), 'inline-right');
  assert.equal(await detectFigurePosition(await pageWith({ textBesideFigure: false }), bbox, region), 'below-stem');
});

test('layout keeps legacy defaults for image-choice sized figure sets', () => {
  const assets = Array.from({ length: 6 }, (_, i) => ({ figure_index: i + 1, bbox_1k: [0, 0, 100, 300] }));
  const layout = buildPdfFigureLayout(assets, { em1k: 17.5 });
  assert.ok(layout.items.every((it) => it.widthEm === 12 && it.position === 'below-stem'));
});

test('two side-by-side figures are sized from source and kept within one line', () => {
  const layout = buildPdfFigureLayout(
    [
      { figure_index: 1, bbox_1k: [0, 100, 100, 400] },
      { figure_index: 2, bbox_1k: [0, 500, 100, 800] },
    ],
    { em1k: 17.5 },
  );
  const total = layout.items[0].widthEm + layout.items[1].widthEm;
  assert.ok(total <= 25.6, `total ${total}`);
  assert.equal(layout.items[0].widthEm, layout.items[1].widthEm);
  assert.equal(layout.groups[0].type, 'horizontal');
});

test('two figures under different sub-questions are not grouped side by side', () => {
  const assets = [
    { figure_index: 1, bbox_1k: [0, 100, 100, 400] },
    { figure_index: 2, bbox_1k: [0, 500, 100, 800] },
  ];
  const stacked = buildPdfFigureLayout(assets, {
    em1k: 17.5,
    stem: '그래프를 그려라.\n[문단]\n1) 표\n[문단]\n[그림]\n[문단]\n2) 모든 수\n[문단]\n[그림]',
  });
  assert.deepEqual(stacked.groups, []);
  assert.equal(figureMarkersSideBySide('두 그림\n[문단]\n[그림]\n[문단]\n[그림]'), true);
  assert.equal(figureMarkersSideBySide('(가) [그림] (나) [그림]'), true);
  assert.equal(figureMarkersSideBySide('[그림]\n[문단]\n2)\n[문단]\n[그림]'), false);
  assert.equal(figureMarkersSideBySide('[그림] 오른쪽 그림에서 넓이를 구하여라. [그림]'), false);
  assert.equal(figureMarkersSideBySide(null), true);
});

test('single figure layout uses the detected position and region anchor', () => {
  const inline = buildPdfFigureLayout([{ figure_index: 1, bbox_1k: [10, 600, 100, 850] }], {
    em1k: 17.5,
    positions: ['inline-right'],
    region1k: [0, 100, 300, 900],
  });
  assert.deepEqual(
    { position: inline.items[0].position, anchor: inline.items[0].anchor, widthEm: inline.items[0].widthEm },
    { position: 'inline-right', anchor: 'right', widthEm: 14.3 },
  );
  const below = buildPdfFigureLayout([{ figure_index: 1, bbox_1k: [150, 110, 250, 300] }], {
    em1k: 17.5,
    positions: ['below-stem'],
    region1k: [0, 100, 300, 900],
  });
  assert.equal(below.items[0].anchor, 'left');
});
