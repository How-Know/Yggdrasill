import { assert, assertEquals } from 'jsr:@std/assert@1';
import {
  buildFigureProposal,
  emPxFromTextSample,
  ensureFigureMarkers,
  figureLayoutItem,
  LINE_PITCH_EM,
  normalizeBox,
  normalizeTextFix,
  orderedFigureAssets,
  parseFigureMeasures,
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
  // 범위 밖 폭은 4~40em 으로 묶는다
  assertEquals(figureLayoutItem(below, 2, 1100, 20).widthEm, 40);
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
