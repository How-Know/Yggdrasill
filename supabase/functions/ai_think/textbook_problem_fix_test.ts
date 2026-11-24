import { assert, assertEquals } from 'jsr:@std/assert@1';
import {
  anchorFigureWithBlank,
  applyCommonFigurePlacement,
  commonStemWithFigureMarker,
  dropPrintedRevert,
  buildFigureProposal,
  commonFigureProposal,
  emPxForHeader,
  emPxFromTextSample,
  ensureFigureMarkers,
  figureLayoutItem,
  figureRemovalIndexes,
  holdUnslottedFigureCrops,
  isSolutionSettled,
  LINE_PITCH_EM,
  solutionRefReplaceable,
  mergeBoxFigureMeasures,
  mergeTableFigureMeasures,
  subQuestionFigurePlacement,
  ownerStagedFigures,
  singleFigureInsideBox,
  normalizeBox,
  blankChoiceLabelsOf,
  currentBlankChoiceLabels,
  normalizeBlankChoiceLabelsFix,
  bogiFigureColumns,
  blankChoiceTextFromArray,
  normalizeTextFix,
  orderedFigureAssets,
  parseFigureMeasures,
  pincettePatch,
} from './textbook_problem_fix.ts';

Deno.test('그림 상자는 0..1000 정수로 묶고 너무 작거나 형식이 틀리면 버린다', () => {
  assertEquals(normalizeBox([10.4, -5, 500, 1200]), [10, 0, 500, 1000]);
  assertEquals(normalizeBox([10, 10, 12, 500]), null);
  assertEquals(normalizeBox([1, 2, 3]), null);
  assertEquals(normalizeBox('x'), null);
});

Deno.test('본문 글줄 묶음 높이와 줄 수로 글자 1em 픽셀을 잰다', () => {
  // 3줄, 이미지 높이 1000px, 상자 높이 440px → (2×1.7 + 1) em = 4.4em → 1em = 100px
  const em = emPxFromTextSample({ bbox_1k: [100, 0, 540, 900], lines: 3 }, 1000)!;
  assert(Math.abs(em - 440 / (2 * LINE_PITCH_EM + 1)) < 1e-9);
  assertEquals(emPxFromTextSample({ bbox_1k: [], lines: 0 }, 1000), null);
  assertEquals(emPxFromTextSample({ bbox_1k: [100, 0, 540, 900], lines: 3 }, 0), null);
});

Deno.test('원본 배치를 V2 위치로 옮기고 폭은 글자 크기 대비 비율로 정한다', () => {
  const [m] = parseFigureMeasures([{ bbox_1k: [100, 600, 400, 950], placement: 'right_of_text', align: 'right', v2_state: 'size' }]);
  // 그림 폭 = 0.35 × 1100px = 385px, 1em = 35px → 11em
  const item = figureLayoutItem(m, 35, 1100, 20);
  assertEquals(item.position, 'inline-right');
  assertEquals(item.anchor, 'right');
  assertEquals(item.widthEm, 11);
  // 글자 크기를 못 재면 기존 폭 유지, 아래 배치는 정렬을 그대로 쓴다
  const [below] = parseFigureMeasures([{ bbox_1k: [500, 100, 900, 500], placement: 'below_text', align: 'center', v2_state: 'ok' }]);
  const kept = figureLayoutItem(below, null, 1100, 16.5);
  assertEquals(kept, { widthEm: 16.5, position: 'below-stem', anchor: 'center', offsetXEm: 0, offsetYEm: 0 });
  // 범위 밖 폭은 4em ~ 한 단 폭(22em)으로 묶는다
  assertEquals(figureLayoutItem(below, 2, 1100, 20).widthEm, 22);
});

Deno.test('그림 자산은 렌더러와 같이 figure_index 별 승인·최신 우선으로 고른다', () => {
  const ordered = orderedFigureAssets([
    { figure_index: 2, path: 'b-old', approved: false, created_at: '2026-01-01' },
    { figure_index: 1, path: 'a', approved: false, created_at: '2026-01-01' },
    { figure_index: 2, path: 'b-new', approved: false, created_at: '2026-02-01' },
    { figure_index: 2, path: 'b-approved', approved: true, created_at: '2025-12-01' },
    { figure_index: 0, path: 'ignored' },
  ]);
  assertEquals(ordered.map((a) => a.path), ['a', 'b-approved']);
});

Deno.test('원본 그림을 자산 순서대로 짝짓고, 없는 그림은 새 번호로, 잘린 그림은 같은 번호로 다시 잘라낸다', () => {
  const measures = parseFigureMeasures([
    { bbox_1k: [100, 600, 400, 950], placement: 'right_of_text', align: 'right', v2_state: 'cut' },
    { bbox_1k: [500, 100, 900, 500], placement: 'below_text', align: 'left', v2_state: 'missing' },
  ]);
  const p = buildFigureProposal({
    measures,
    emPx: 35,
    imageWidthPx: 1100,
    assets: [{ figure_index: 3, path: 'x', approved: true }],
    currentLayout: {
      version: 1,
      items: [
        { assetKey: 'idx:3', widthEm: 18, heightEm: 2, position: 'below-stem', anchor: 'center' },
        { assetKey: 'path:keep', widthEm: 9 },
      ],
      groups: [{ type: 'horizontal', members: ['idx:3'] }],
    },
  })!;
  assertEquals(p.layout.items.map((i) => i.assetKey), ['idx:3', 'idx:4', 'path:keep']);
  assertEquals(p.layout.items[0].position, 'inline-right');
  assertEquals(p.layout.items[0].heightEm, 2);
  assertEquals(p.layout.items[1].anchor, 'left');
  assertEquals(p.layout.groups.length, 1);
  assertEquals(p.crops, [
    { figure_index: 3, bbox_1k: [100, 600, 400, 950], reason: 'cut' },
    { figure_index: 4, bbox_1k: [500, 100, 900, 500], reason: 'missing' },
  ]);
  assertEquals(buildFigureProposal({ measures: [], emPx: 35, imageWidthPx: 1100, assets: [], currentLayout: null }), null);
});

Deno.test('본문에 그림 자리가 없는 새 그림은 자동 등록에서 빼고 확인용으로 남긴다', () => {
  const measures = parseFigureMeasures([
    { bbox_1k: [50, 50, 300, 600], placement: 'below_text', align: 'left', v2_state: 'ok' },
    { bbox_1k: [400, 550, 700, 950], placement: 'right_of_text', align: 'right', v2_state: 'missing' },
  ]);
  const p = buildFigureProposal({
    measures,
    emPx: 35,
    imageWidthPx: 1100,
    assets: [{ figure_index: 1, path: 'a', approved: true }],
    currentLayout: null,
  });
  const held = holdUnslottedFigureCrops(p, { slots: 1, assetCount: 1 });
  assertEquals(held.held.map((c) => c.figure_index), [2]);
  assertEquals(held.proposal!.crops, []);
  assertEquals(held.proposal!.layout.items.map((i) => i.assetKey), ['idx:1']);
  const slotted = holdUnslottedFigureCrops(p, { slots: 2, assetCount: 1 });
  assertEquals(slotted.held, []);
  assertEquals(slotted.proposal!.crops.map((c) => c.figure_index), [2]);
});

Deno.test('핀셋 결과는 비어 있지 않은 값만 반영 대기 값으로 쌓는다', () => {
  assertEquals(
    pincettePatch({
      stem: '다음을 계산하여라.',
      commonStem: null,
      choices: [],
      figureLayout: null,
      answer: '12',
      solutionTranscribed: null,
      solutionAnswer: '12',
    }),
    { stem: '다음을 계산하여라.', answer: '12', solution_answer: '12' },
  );
  assertEquals(
    pincettePatch({ stem: null, commonStem: null, choices: null, figureLayout: null, answer: null, solutionTranscribed: null, solutionAnswer: null }),
    {},
  );
});

Deno.test('다른 조각이 섞인 그림은 같은 번호로 그림만 다시 잘라낸다', () => {
  const p = buildFigureProposal({
    measures: parseFigureMeasures([
      { bbox_1k: [120, 132, 330, 687], placement: 'below_text', align: 'center', v2_state: 'dirty' },
    ]),
    emPx: 42,
    imageWidthPx: 1100,
    assets: [{ figure_index: 1, path: 'x' }],
    currentLayout: null,
  })!;
  assertEquals(p.crops, [{ figure_index: 1, bbox_1k: [120, 132, 330, 687], reason: 'cut' }]);
});

Deno.test('원본에서 위아래로 떨어진 두 그림은 가로 묶음을 풀고, 같은 높이대 두 그림은 묶음을 유지한다', () => {
  const layout = {
    version: 1,
    items: [{ assetKey: 'idx:1', widthEm: 8.5 }, { assetKey: 'idx:2', widthEm: 8.5 }],
    groups: [{ type: 'horizontal', members: ['idx:1', 'idx:2'], gap: 0.5 }],
  };
  const assets = [{ figure_index: 1, path: 'a' }, { figure_index: 2, path: 'b' }];
  const stacked = buildFigureProposal({
    measures: parseFigureMeasures([
      { bbox_1k: [209, 326, 400, 641], placement: 'below_text', align: 'center', v2_state: 'position' },
      { bbox_1k: [718, 329, 910, 644], placement: 'below_text', align: 'center', v2_state: 'position' },
    ]),
    emPx: 40,
    imageWidthPx: 1100,
    assets,
    currentLayout: layout,
  })!;
  assertEquals(stacked.layout.groups, []);
  const sideBySide = buildFigureProposal({
    measures: parseFigureMeasures([
      { bbox_1k: [300, 50, 600, 450], placement: 'below_text', align: 'center', v2_state: 'ok' },
      { bbox_1k: [320, 520, 620, 950], placement: 'below_text', align: 'center', v2_state: 'ok' },
    ]),
    emPx: 40,
    imageWidthPx: 1100,
    assets,
    currentLayout: layout,
  })!;
  assertEquals(sideBySide.layout.groups.length, 1);
});

Deno.test('새 그림 수만큼 본문에 [그림] 마커가 없으면 끝에 붙인다', () => {
  assertEquals(ensureFigureMarkers('다음 그림에서 x 의 값은?', 1), '다음 그림에서 x 의 값은?\n[그림]');
  assertEquals(ensureFigureMarkers('그림[그림]에서 ', 2), '그림[그림]에서\n[그림]');
  assertEquals(ensureFigureMarkers('[그림] 두 개 [그림]', 2), '[그림] 두 개 [그림]');
});

Deno.test('본문·공통 발문 수정안 정리: 공통 발문만 바뀐 경우도 받고 모델이 text_matches_original=true 를 찍어도 수정안을 살린다', () => {
  // 공통 발문만 바뀜(예: common_stem='36' → 원래 지시문) + 모델이 실수로 text_matches_original=true 로 응답
  const commonOnly = normalizeTextFix({
    textMatchesOriginal: true,
    correctedStem: null,
    correctedCommonStem: '다음 수의 약수의 개수를 구하여라.',
    correctedChoices: null,
    currentStem: '480',
    currentCommonStem: '36',
    currentChoices: [],
  });
  assertEquals(commonOnly, {
    stem: null,
    commonStem: '다음 수의 약수의 개수를 구하여라.',
    choices: null,
    textSame: false,
  });

  // 기존 common_stem 이 비어 있던 세트 문항도 세트 머리 지시문을 받는다
  const emptyCommon = normalizeTextFix({
    textMatchesOriginal: false,
    correctedStem: null,
    correctedCommonStem: '다음 표의 빈칸에 알맞은 수를 써넣어라.',
    correctedChoices: null,
    currentStem: '15=3\\times5',
    currentCommonStem: '',
    currentChoices: [],
  });
  assertEquals(emptyCommon.commonStem, '다음 표의 빈칸에 알맞은 수를 써넣어라.');
  assertEquals(emptyCommon.textSame, false);

  // 공통 발문이 새로 채워질 때 기존 stem 앞머리에 그 지시문이 중복돼 있으면 함께 떼어낸다
  const stripExisting = normalizeTextFix({
    textMatchesOriginal: false,
    correctedStem: null,
    correctedCommonStem: '다음 수의 약수의 개수를 구하여라.',
    correctedChoices: null,
    currentStem: '다음 수의 약수의 개수를 구하여라.[문단]480',
    currentCommonStem: '36',
    currentChoices: [],
  });
  assertEquals(stripExisting.commonStem, '다음 수의 약수의 개수를 구하여라.');
  assertEquals(stripExisting.stem, '480');

  // 모델이 corrected_stem 을 비웠어도 기존 stem 에 [ [[공백:3]] ] 나 aligned 내 날한글이 있으면 자동으로 정규화한 stem 을 제안한다
  const syntaxFixed = normalizeTextFix({
    textMatchesOriginal: true,
    correctedStem: null,
    correctedCommonStem: null,
    correctedChoices: null,
    currentStem: '두 수의 [ [[공백:3]] ]의 합',
    currentCommonStem: '',
    currentChoices: [],
  });
  assertEquals(syntaxFixed.stem, '두 수의 [[공백:3]]의 합');
  assertEquals(syntaxFixed.textSame, false);
});

Deno.test('normalizeTextFix: $ 구분자만 붙인 수정안은 버린다', () => {
  const delimiterOnly = normalizeTextFix({
    textMatchesOriginal: false,
    correctedStem: '[그림]\n[문단]\n해 $l\\parallel m$이므로 $\\angle x=55^{\\circ}$',
    correctedCommonStem: '그림에서 $l \\parallel m$일 때, $\\angle x$의 크기를 구하여라.',
    correctedChoices: [{ label: '①', text: '$30^{\\circ}$' }],
    currentStem: '[그림]\n[문단]\n해 l \\parallel m이므로 \\angle x = 55^{\\circ}',
    currentCommonStem: '그림에서 l\\parallel m일 때, \\angle x의 크기를 구하여라.',
    currentChoices: [{ label: '①', text: '30^{\\circ}' }],
  });
  assertEquals(delimiterOnly.stem, null);
  assertEquals(delimiterOnly.commonStem, null);
  assertEquals(delimiterOnly.choices, null);

  const realChange = normalizeTextFix({
    textMatchesOriginal: false,
    correctedStem: '해 $l\\parallel m$이므로 $\\angle x=40^{\\circ}$',
    correctedCommonStem: null,
    correctedChoices: null,
    currentStem: '해 l \\parallel m이므로 \\angle x = 55^{\\circ}',
    currentCommonStem: '',
    currentChoices: [],
  });
  assertEquals(realChange.stem, '해 $l\\parallel m$이므로 $\\angle x=40^{\\circ}$');
});

Deno.test('그림이 공통 발문에만 있으면 세트 머리에서 본 자리로 배치 위치만 바꾼다', () => {
  const base = {
    layout: { version: 1, items: [{ assetKey: 'idx:1', widthEm: 12, position: 'below-stem', anchor: 'center' }], groups: [] },
    crops: [],
  };
  const ctx = { commonStem: '그림과 같이 [그림] 이다.', stem: '물음에 답하여라.', measured: false };
  const moved = applyCommonFigurePlacement(base, 'right_of_text', ctx)!;
  assertEquals(moved.layout.items[0].position, 'inline-right');
  assertEquals(moved.layout.items[0].anchor, 'right');
  assertEquals(moved.layout.items[0].widthEm, 12);
  assertEquals(applyCommonFigurePlacement(base, 'none', ctx), base);
  assertEquals(applyCommonFigurePlacement(base, 'right_of_text', { ...ctx, measured: true }), base);
  assertEquals(applyCommonFigurePlacement(base, 'right_of_text', { ...ctx, stem: '[그림] 에서' }), base);
  assertEquals(applyCommonFigurePlacement(base, 'right_of_text', { ...ctx, commonStem: '다음 물음에 답하여라.' }), base);
  assertEquals(applyCommonFigurePlacement(null, 'right_of_text', ctx), null);
});

Deno.test('공통 발문 그림이 세트 어디에도 없으면 세트 머리에서 잘라 등록하도록 제안한다', () => {
  const base = {
    boxes: [{ bbox_1k: [200, 300, 900, 700] }],
    placement: 'below_text',
    commonStem: '다음 좌표평면에 점을 나타내어라.[문단][그림]',
    stem: 'A(3, 4)',
    assets: [],
    currentLayout: null,
    emPx: 40,
    headerWidthPx: 1000,
  };
  const p = commonFigureProposal(base)!;
  assertEquals(p.crops, [{ figure_index: 1, bbox_1k: [200, 300, 900, 700], reason: 'missing', source: 'set_header' }]);
  assertEquals(p.layout.items[0].position, 'below-stem');
  assertEquals(p.layout.items[0].widthEm, 10);
  assertEquals(commonFigureProposal({ ...base, assets: [{ figure_index: 1, approved: true }] }), null);
  assertEquals(commonFigureProposal({ ...base, stem: '[그림] 에서' }), null);
  assertEquals(commonFigureProposal({ ...base, commonStem: '다음 물음에 답하여라.' }), null);
  assertEquals(commonFigureProposal({ ...base, boxes: [] }), null);
  const recrop = commonFigureProposal({ ...base, assets: [{ figure_index: 1, approved: true }], state: 'dirty' })!;
  assertEquals(recrop.crops, [{ figure_index: 1, bbox_1k: [200, 300, 900, 700], reason: 'cut', source: 'set_header' }]);
  assertEquals(commonFigureProposal({ ...base, assets: [{ figure_index: 1, approved: true }], state: 'ok' }), null);
});

Deno.test('문항 그림이 아닌 그림은 그림 번호로 바꿔 빼기 제안을 만든다', () => {
  const assets = [{ figure_index: 2, approved: true }, { figure_index: 5, approved: true }];
  assertEquals(figureRemovalIndexes([2], assets, '다음 물음에 답하여라.'), [5]);
  assertEquals(figureRemovalIndexes([1, 1], assets, '[그림]에서'), [2]);
  assertEquals(figureRemovalIndexes([1, 2], assets, '[그림]에서'), []);
  assertEquals(figureRemovalIndexes([3], assets, ''), []);
  assertEquals(figureRemovalIndexes(null, assets, ''), []);
});

Deno.test('문항 원본의 글자 크기를 세트 머리 이미지 픽셀로 옮긴다', () => {
  const em = emPxForHeader({
    emPx: 40,
    originalWidthPx: 1100,
    originalRegion1k: [0, 100, 100, 540],
    headerWidthPx: 1100,
    headerRegion1k: [0, 100, 100, 320],
  });
  assertEquals(em, 80);
  assertEquals(emPxForHeader({ emPx: 40, originalWidthPx: 1100, originalRegion1k: null, headerWidthPx: 1100, headerRegion1k: [0, 1, 2, 3] }), null);
});

Deno.test('본문이 그림과 답란뿐이면 그림을 왼쪽에 붙인다', () => {
  const p = {
    layout: { version: 1, items: [{ assetKey: 'idx:1', widthEm: 5, position: 'below-stem', anchor: 'right' }], groups: [] },
    crops: [],
  };
  assertEquals(anchorFigureWithBlank(p, '[그림][문단]([공백:3])')!.layout.items[0].anchor, 'left');
  assertEquals(anchorFigureWithBlank(p, '[그림]\n[문단]\n( )')!.layout.items[0].anchor, 'left');
  assertEquals(anchorFigureWithBlank(p, '다음 그림을 보고 답하여라.[문단][그림]'), p);
  const inline = { ...p, layout: { ...p.layout, items: [{ ...p.layout.items[0], position: 'inline-left', anchor: 'left' }] } };
  assertEquals(anchorFigureWithBlank(inline, '[그림][문단]([공백:3])')!.layout.items[0].position, 'inline-left');
  assertEquals(anchorFigureWithBlank(null, '[그림][문단]([공백:3])'), null);
});

Deno.test('세트 머리에만 그림이 있고 그림 자리가 어디에도 없으면 공통 발문 끝에 그림 자리를 붙인다', () => {
  const base = {
    commonStem: '그림에 대하여 옳은 것에 ○표를 하여라.',
    stem: '점 A는 직선 l 위에 (있다, 있지 않다).',
    placement: 'right_of_text',
    assets: [{ figure_index: 1, path: 'a' }],
  };
  assertEquals(commonStemWithFigureMarker(base), '그림에 대하여 옳은 것에 ○표를 하여라.[문단][그림]');
  assertEquals(commonStemWithFigureMarker({ ...base, placement: 'none' }), null);
  assertEquals(commonStemWithFigureMarker({ ...base, assets: [] }), null);
  assertEquals(commonStemWithFigureMarker({ ...base, stem: '[그림][문단]점 A' }), null);
  assertEquals(commonStemWithFigureMarker({ ...base, commonStem: '그림을 보고 답하여라.[그림]' }), null);
  assertEquals(commonStemWithFigureMarker({ ...base, commonStem: '' }), null);
});

Deno.test('원본 오류 교정 문항: 인쇄본으로 되돌리는 본문 수정안만 버린다', () => {
  const printed = { stem: '정사각형 ABCD를 \\overline{\\text{EH}}를 접는 선으로 하여 점 F에 오도록 접을 때\n[문단]\n[그림]', choices: [] };
  const revert = { stem: '정사각형 ABCD를 \\overline{EH}를 접는 선으로 하여 점 F에 오도록 접을 때\n[문단]\n[그림]', commonStem: null, choices: null, textSame: false };
  // 표시하지 않은 문항은 그대로 둔다.
  assertEquals(dropPrintedRevert(revert, null), { ...revert, reverted: false });
  // 표시한 문항: \text{} 감싸기만 다른 인쇄본 글로 되돌리는 수정안은 버리고 "원본과 같음"으로 본다.
  const dropped = dropPrintedRevert(revert, printed);
  assertEquals(dropped.stem, null);
  assertEquals(dropped.textSame, true);
  assertEquals(dropped.reverted, true);
  // 인쇄본과 다른 글로 고치는 수정안(다른 오타 수정)은 남긴다.
  const other = { ...revert, stem: '정사각형 ABCD를 \\overline{FH}를 접는 선으로 하여 점 E에 오도록 접을 때, 값은?\n[문단]\n[그림]' };
  const kept = dropPrintedRevert(other, printed);
  assertEquals(kept.stem, other.stem);
  assertEquals(kept.reverted, false);
  // 선지를 인쇄본으로 되돌리는 수정안도 버린다.
  const ch = dropPrintedRevert(
    { stem: null, commonStem: null, choices: [{ label: '①', text: '$3$' }], textSame: false },
    { stem: 'x', choices: [{ label: '①', text: '3' }] },
  );
  assertEquals(ch.choices, null);
  assertEquals(ch.reverted, true);
});
Deno.test('보기 상자 안 그림은 통째로 한 장: 나눠 잰 도형을 합치고, 이미 통째 그림이면 다시 자르지 않는다', () => {
  const stem = '<보기>에서 옳은 것은?\n[문단]\n[보기시작]\n[그림]\n[보기끝]';
  assertEquals(singleFigureInsideBox(stem), true);
  assertEquals(singleFigureInsideBox('값은?\n[문단]\n[그림]'), false);
  assertEquals(singleFigureInsideBox('[보기시작]\nㄱ. 1\n[보기끝]\n[그림]'), false);
  assertEquals(singleFigureInsideBox('[보기시작]\n[그림]\n[그림]\n[보기끝]'), false);

  const m = (bbox: [number, number, number, number], v2State: 'dirty' | 'missing' | 'ok') =>
    ({ bbox, placement: 'below_text' as const, align: 'left' as const, v2State });
  const measures = [m([180, 39, 323, 458], 'dirty'), m([192, 486, 310, 941], 'missing'), m([598, 486, 799, 923], 'missing')];
  const region = [94, 517, 486, 926];

  // 통째 그림이 이미 있으면(추출 때 자른 것) 그대로 둔다.
  const whole = [{ figure_index: 1, approved: true, bbox_1k: [150, 520, 418, 914] }];
  const kept = mergeBoxFigureMeasures({ measures, stem, assets: whole, originalRegion1k: region });
  assertEquals(kept.length, 1);
  assertEquals(kept[0].bbox, [160, 19, 819, 961]);
  assertEquals(kept[0].align, 'center');
  assertEquals(kept[0].v2State, 'ok');

  // 왼쪽 기호가 잘린 통째 그림(추출 때 좁게 잘림)이나 도형 하나만 담긴 그림이면 합친 영역으로 다시 자른다.
  const narrow = [{ figure_index: 1, approved: true, bbox_1k: [154, 567, 412, 904] }];
  assertEquals(mergeBoxFigureMeasures({ measures, stem, assets: narrow, originalRegion1k: region })[0].v2State, 'cut');
  const part = [{ figure_index: 1, approved: true, crop_region_1k: [153, 518, 223, 709] }];
  assertEquals(mergeBoxFigureMeasures({ measures, stem, assets: part, originalRegion1k: region })[0].v2State, 'cut');
  // 그림이 없으면 새로 자른다.
  assertEquals(mergeBoxFigureMeasures({ measures, stem, assets: [], originalRegion1k: region })[0].v2State, 'missing');
  // 보기 상자 문항이 아니거나 그림이 하나면 건드리지 않는다.
  assertEquals(mergeBoxFigureMeasures({ measures, stem: '값은?\n[그림]\n[그림]\n[그림]', assets: [], originalRegion1k: region }), measures);
  assertEquals(mergeBoxFigureMeasures({ measures: measures.slice(0, 1), stem, assets: [], originalRegion1k: region }).length, 1);

  assertEquals(ownerStagedFigures({ figure_assets: [{}], sources: { figure_assets: 'owner' } }), true);
  assertEquals(ownerStagedFigures({ figure_assets: [{}], sources: { figure_assets: 'ai' } }), false);
  assertEquals(ownerStagedFigures(null), false);
});
Deno.test('칸 안에 그림이 있는 표는 표 전체를 그림 한 장으로 바꾼다', () => {
  const stem = '다음 표를 완성하여라.\n[문단]\n[표시작]\n\\begin{tabular}{|c|c|}\n\\text{다면체} & [그림] & [그림] \\\\\n\\end{tabular}\n[표끝]';
  const cell = { placement: 'below_text', align: 'center', v2State: 'ok' } as const;
  const out = mergeTableFigureMeasures({
    stem,
    measures: [
      { bbox: [100, 50, 600, 950], ...cell, wholeTable: true },
      { bbox: [120, 300, 200, 400], ...cell },
      { bbox: [120, 600, 200, 700], ...cell },
    ],
  });
  assertEquals(out.stem, '다음 표를 완성하여라.\n[문단]\n[그림]');
  assertEquals(out.measures.length, 1);
  assertEquals(out.measures[0].v2State, 'cut');
  // 표 전체를 못 쟀으면 아무것도 바꾸지 않는다.
  const none = mergeTableFigureMeasures({ stem, measures: [{ bbox: [120, 300, 200, 400], ...cell }] });
  assertEquals(none.stem, null);
  assertEquals(none.measures.length, 1);
  // 그림 없는 글자 표는 그대로 둔다.
  assertEquals(mergeTableFigureMeasures({ stem: '[표시작]\na & b\n[표끝]', measures: [] }).stem, null);
});

Deno.test('상자가 든 글은 공통 발문 수정안으로 받지 않는다', () => {
  const cur = '다음 조건을 모두 만족시키는 입체도형을 구하여라.\n[문단]\n[박스시작]\n(가) 밑면이 1개이다.\n[박스끝]';
  const fix = normalizeTextFix({
    textMatchesOriginal: false,
    correctedStem: null,
    correctedCommonStem: '다음 조건을 모두 만족시키는 입체도형을 구하여라.\n[문단]\n[박스시작]\n(가) 밑면이 1개이다.',
    correctedChoices: null,
    currentStem: cur,
    currentCommonStem: '',
    currentChoices: [],
  });
  assertEquals(fix.commonStem, null);
  assertEquals(fix.stem, null);
});
Deno.test('소문항 안의 그림은 글 옆으로 재져도 소문항 번호 아래 왼쪽에 둔다', () => {
  const stem = '오른쪽 그림을 보고 답하여라.\n[그림]\n[문단]\n[소문항1]\n1) [그림]\n[문단]\n[소문항2]\n2) [그림]';
  const m = { bbox: [0, 0, 100, 100] as [number, number, number, number], align: 'center', v2State: 'ok' } as const;
  const out = subQuestionFigurePlacement(
    [{ ...m, placement: 'right_of_text' }, { ...m, placement: 'right_of_text' }, { ...m, placement: 'below_text' }],
    stem,
  );
  assertEquals(out.map((x) => `${x.placement}/${x.align}`), ['right_of_text/center', 'below_text/left', 'below_text/center']);
});
Deno.test('빈칸형 선지: 한 줄 array 로 쓴 선지는 쉼표 형식으로 바꾼다', () => {
  assertEquals(blankChoiceLabelsOf({ choice_layout: 'blank_table', blank_choice_labels: ['이름', '면의 모양', '꼭짓점의 개수'] })?.length, 3);
  assertEquals(blankChoiceLabelsOf({ choice_layout: 'default' }), null);
  assertEquals(
    blankChoiceTextFromArray('\\begin{array}{ccc}\\text{정사면체}&\\text{정삼각형}&4\\end{array}', 3),
    '정사면체, 정삼각형, 4',
  );
  assertEquals(blankChoiceTextFromArray('\\begin{array}{cc}a&b\\end{array}', 3), null);
  assertEquals(blankChoiceTextFromArray('\\begin{array}{ccc}a&b&c\\\\d&e&f\\end{array}', 3), null);
  assertEquals(blankChoiceTextFromArray('정사면체, 정삼각형, 4', 3), null);

  const arr = (a: string, b: string, c: string) => `\\begin{array}{ccc}\\text{${a}}&\\text{${b}}&${c}\\end{array}`;
  const current = [
    { label: '①', text: arr('정사면체', '정삼각형', '4') },
    { label: '②', text: arr('정육면체', '정사각형', '8') },
  ];
  // AI 수정안이 없어도 저장된 선지가 array 면 고치는 수정안을 낸다.
  const fix = normalizeTextFix({
    textMatchesOriginal: true,
    correctedStem: null,
    correctedCommonStem: null,
    correctedChoices: null,
    currentStem: '옳지 않은 것은?',
    currentCommonStem: '',
    currentChoices: current,
    blankChoiceColumns: 3,
  });
  assertEquals(fix.choices?.map((c) => c.text), ['정사면체, 정삼각형, 4', '정육면체, 정사각형, 8']);
  assertEquals(fix.textSame, false);
  // 빈칸형이 아니면 그대로 둔다.
  const plain = normalizeTextFix({
    textMatchesOriginal: true,
    correctedStem: null,
    correctedCommonStem: null,
    correctedChoices: null,
    currentStem: '옳지 않은 것은?',
    currentCommonStem: '',
    currentChoices: current,
  });
  assertEquals(plain.choices, null);
});

Deno.test('보기 2단: 보기 안 그림이 원본에서 좌우로 나란할 때만 2단으로 본다', () => {
  const stem = '<보기> 중에서 고른 것은?\n[문단]\n[보기시작]\nㄱ. [그림]\nㄴ. [그림]\nㄷ. [그림]\n[보기끝]';
  const sideBySide = [{ bbox: [229, 110, 396, 509] }, { bbox: [225, 585, 399, 966] }, { bbox: [442, 103, 584, 486] }];
  const stacked = [{ bbox: [100, 110, 250, 509] }, { bbox: [270, 110, 420, 509] }, { bbox: [440, 110, 590, 509] }];
  assertEquals(bogiFigureColumns(stem, sideBySide), 2);
  assertEquals(bogiFigureColumns(stem, stacked), null);
  // 보기 밖에도 그림이 있거나 보기가 없으면 건드리지 않는다.
  assertEquals(bogiFigureColumns('[그림]\n' + stem, [{ bbox: [0, 0, 90, 400] }, ...sideBySide]), null);
  assertEquals(bogiFigureColumns('ㄱ. [그림]\nㄴ. [그림]', sideBySide), null);
});

Deno.test('글 줄 안 그림: 원본에서 글줄에 낀 그림은 inline-text 로 두고 잰 높이를 쓴다', () => {
  const p = buildFigureProposal({
    measures: [
      { bbox: [349, 49, 391, 121], placement: 'inline', align: 'left', v2State: 'ok' },
      { bbox: [478, 185, 838, 812], placement: 'below_text', align: 'center', v2State: 'ok' },
    ] as Parameters<typeof buildFigureProposal>[0]['measures'],
    emPx: 39.7,
    imageWidthPx: 1100,
    imageHeightPx: 1366,
    assets: [{ figure_index: 1 }, { figure_index: 2 }],
    currentLayout: null,
  });
  assertEquals(p?.layout.items[0].position, 'inline-text');
  assertEquals(p?.layout.items[0].heightEm, 1.4);
  assertEquals(p?.layout.items[1].position, 'below-stem');
});

Deno.test("선지 아래에 둔 그림은 원본에서 '글 아래'로 재져도 선지 아래로 둔다", () => {
  const propose = (placement: string, position: string) =>
    buildFigureProposal({
      measures: parseFigureMeasures([{ bbox_1k: [520, 300, 900, 700], placement, align: 'center', v2_state: 'size' }]),
      emPx: 40,
      imageWidthPx: 1100,
      assets: [{ figure_index: 1, path: 'a' }],
      currentLayout: { version: 1, items: [{ assetKey: 'idx:1', widthEm: 12, position, anchor: 'center' }], groups: [] },
    })!.layout.items[0];
  const kept = propose('below_text', 'below-choices');
  assertEquals(kept.position, 'below-choices');
  // 크기는 원본에서 잰 값으로 바뀐다.
  assertEquals(kept.widthEm, 11);
  // 원본에서 글 옆으로 잰 그림은 잰 대로 둔다. 선지 아래가 아니던 그림을 선지 아래로 보내지도 않는다.
  assertEquals(propose('right_of_text', 'below-choices').position, 'inline-right');
  assertEquals(propose('below_text', 'below-stem').position, 'below-stem');
});

Deno.test('표 모양 선지 제목: 반영 대기 값을 먼저 쓰고, 화면이 달라지는 같은 개수의 수정안만 받는다', () => {
  const meta = { choice_layout: 'blank_table', blank_choice_labels: ['닮은 도형', '닮음조건', '\\overlineDC의 길이'] };
  const fixed = ['닮은 도형', '닮음조건', '\\overline{DC}의 길이'];
  assertEquals(currentBlankChoiceLabels(meta, null)?.[2], '\\overlineDC의 길이');
  assertEquals(currentBlankChoiceLabels(meta, { blank_choice_labels: fixed })?.[2], '\\overline{DC}의 길이');
  assertEquals(currentBlankChoiceLabels({ choice_layout: 'default' }, { blank_choice_labels: fixed }), null);
  const cur = currentBlankChoiceLabels(meta, null);
  assertEquals(normalizeBlankChoiceLabelsFix(fixed, cur), fixed);
  assertEquals(normalizeBlankChoiceLabelsFix(fixed, fixed), null);
  assertEquals(normalizeBlankChoiceLabelsFix(['닮은 도형', '닮음조건'], cur), null);
  assertEquals(normalizeBlankChoiceLabelsFix(null, cur), null);
  assertEquals(normalizeBlankChoiceLabelsFix(fixed, null), null);
});

Deno.test('정답이 통과했고 원본 해설을 이미 옮긴 문항은 해설을 다시 옮기지 않는다', () => {
  const base = { math_status: 'clean', solution_transcribed: '$x=1$', quality_checks: { solution_vision: { found: true } } };
  assert(isSolutionSettled(base));
  assert(isSolutionSettled({ ...base, math_status: 'approved', quality_checks: {} }));
  // 정답이 안 맞거나, 해설을 못 찾았거나, 옮긴 해설이 없으면 다시 옮긴 해설을 받는다.
  assert(!isSolutionSettled({ ...base, math_status: 'issue' }));
  assert(!isSolutionSettled({ ...base, math_status: 'pending' }));
  assert(!isSolutionSettled({ ...base, quality_checks: { solution_vision: { found: false } } }));
  assert(!isSolutionSettled({ ...base, solution_transcribed: '  ' }));
  assert(!isSolutionSettled({ ...base, solution_transcribed: null }));
  // 세 정답은 일치했는데 해설 풀이 과정의 오류로만 'issue' 인 문항도 해설을 다시 옮기지 않는다.
  const logicOnly = { ...base, math_status: 'issue', answer_matched: true, mismatch_reason: '해설 논리 오류: 부호가 틀렸다.' };
  assert(isSolutionSettled(logicOnly));
  assert(!isSolutionSettled({ ...logicOnly, answer_matched: false }));
  assert(!isSolutionSettled({ ...logicOnly, mismatch_reason: '해설 정답과 채점 정답이 다르다.' }));
  assert(!isSolutionSettled({ ...logicOnly, quality_checks: { solution_vision: { found: false } } }));
});

Deno.test('수정 단계가 찾은 해설 상자는 사람이 고친 위치와 이어진 영역까지 계산한 위치를 덮지 않는다', () => {
  // 위치가 없거나, 교재처럼 이어진 영역을 계산하지 않은 위치(null)는 바꿀 수 있다.
  assert(solutionRefReplaceable(null));
  assert(solutionRefReplaceable({ edited_at: null, continuation_regions: null }));
  assert(solutionRefReplaceable({ edited_at: null }));
  // 모의고사: 이어진 영역이 없다고 계산한 것([])도 계산한 위치다.
  assert(!solutionRefReplaceable({ edited_at: null, continuation_regions: [] }));
  assert(!solutionRefReplaceable({ edited_at: null, continuation_regions: [{ raw_page: 3, region_1k: [100, 500, 400, 880] }] }));
  assert(!solutionRefReplaceable({ edited_at: '2026-11-20T00:00:00Z', continuation_regions: null }));
});
