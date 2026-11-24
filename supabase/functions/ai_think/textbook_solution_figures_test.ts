import { assertEquals } from 'jsr:@std/assert@1';
import {
  countSolutionFigureMarkers,
  markedSolutionText,
  normalizeFigureBoxes,
  normalizeFigures,
  normalizeTightenBoxes,
  solutionFiguresInstructions,
  solutionFiguresSchema,
  syncStagedFigureMarkers,
  transferFigureMarkers,
} from './textbook_solution_figures.ts';

Deno.test('반영 대기 해설 글의 그림 자리는 저장된 해설 글의 자리를 줄 단위로 따라간다', () => {
  // 저장된 글: 그림을 다시 찾아 표시가 3개(둘은 (ⅰ) 앞, 하나는 결론 앞). 반영 대기 글: 점 이름만 곧게 바꾼 예전 글(표시 2개).
  const base = [
    '[출제의도] 확률 구하기',
    '점 A에서 출발한다.',
    '[그림]',
    '[그림]',
    '(ⅰ) 점 B를 지나는 경우',
    '(ⅱ) 점 C를 지나는 경우',
    '[그림] 위 그림에서',
    '따라서 확률은 $\\frac{1}{3}$',
  ].join('\n\n');
  const staged = [
    '[출제의도] 확률 구하기',
    '점 $\\mathrm{A}$에서 출발한다.',
    '[그림]',
    '(ⅰ) 점 $\\mathrm{B}$를 지나는 경우',
    '(ⅱ) 점 $\\mathrm{C}$를 지나는 경우',
    '[그림]',
    '위 그림에서',
    '따라서 확률은 $\\frac{1}{3}$',
  ].join('\n\n');
  assertEquals(
    syncStagedFigureMarkers(base, staged),
    [
      '[출제의도] 확률 구하기',
      '점 $\\mathrm{A}$에서 출발한다.',
      '[그림]',
      '[그림]',
      '(ⅰ) 점 $\\mathrm{B}$를 지나는 경우',
      '(ⅱ) 점 $\\mathrm{C}$를 지나는 경우',
      '[그림] 위 그림에서',
      '따라서 확률은 $\\frac{1}{3}$',
    ].join('\n\n'),
  );
  // 이미 같은 자리면 바꾸지 않는다.
  assertEquals(syncStagedFigureMarkers(base, syncStagedFigureMarkers(base, staged)!), null);
  // 반영 대기 글이 머리 줄을 지웠어도 뒤 줄로 자리를 찾는다. 글 끝의 표시는 끝에 놓는다.
  assertEquals(
    syncStagedFigureMarkers('28. [정답] ②\n\n가\n\n[그림]\n\n나\n\n[그림]', '가\n\n나'),
    '가\n\n[그림]\n\n나\n\n[그림]',
  );
  // 표시 뒤 줄을 반영 대기 글에서 찾지 못하면(줄 가운데 표시, 달라진 글) 손대지 않는다.
  assertEquals(syncStagedFigureMarkers('가나\n\n[그림]\n\n다라', '가나다라'), null);
  assertEquals(syncStagedFigureMarkers('가\n\n[그림]\n\n나', '가\n\n전혀 다른 줄'), null);
});

Deno.test('다듬기 상자는 이미지 번호 자리에 놓고, 못 찾았거나 틀린 것은 null 로 둔다', () => {
  assertEquals(
    normalizeTightenBoxes({
      figures: [
        { index: 2, found: true, bbox_1k: [120, 40, 700, 960] },
        { index: 1, found: false, bbox_1k: [] },
        { index: 3, found: true, bbox_1k: [10, 10, 15, 900] },
        { index: 9, found: true, bbox_1k: [0, 0, 500, 500] },
      ],
    }, 3),
    [null, [120, 40, 700, 960], null],
  );
  assertEquals(normalizeTightenBoxes(null, 2), [null, null]);
});

Deno.test('해설 그림 상자는 0..1000 정수로 묶고 너무 작거나 형식이 틀리면 버린다', () => {
  assertEquals(
    normalizeFigureBoxes([
      { bbox_1k: [100.4, -5, 400, 1200] },
      { bbox_1k: [10, 10, 15, 500] },
      { bbox_1k: [1, 2, 3] },
      { bbox_1k: ['a', 0, 100, 100] },
      null,
    ]),
    [[100, 0, 400, 1000]],
  );
  assertEquals(
    normalizeFigures([
      { bbox_1k: [100, 600, 400, 950], placement: 'right_of_text' },
      { bbox_1k: [500, 100, 800, 500], placement: 'below_text' },
      { bbox_1k: [500, 100, 800, 500] },
    ]).map((f) => f.placement),
    ['right', 'below', 'below'],
  );
});

Deno.test('조각을 따로 보낸 해설은 그림마다 조각 번호를 받고, 번호가 틀린 그림은 버린다', () => {
  const raw = [
    { piece: 2, bbox_1k: [100, 100, 400, 500] },
    { piece: 4, bbox_1k: [100, 100, 400, 500] },
    { bbox_1k: [100, 100, 400, 500] },
    { piece: 1, bbox_1k: [500, 100, 800, 500] },
  ];
  assertEquals(normalizeFigures(raw, 3).map((f) => f.piece), [2, 1]);
  // 한 장일 때는 조각 번호를 보지 않는다.
  assertEquals(normalizeFigures(raw).map((f) => f.piece), [1, 1, 1, 1]);
});

Deno.test('조각 스키마와 지시문은 조각을 따로 보낼 때만 바뀐다', () => {
  // deno-lint-ignore no-explicit-any
  const figure = (s: any) => s.properties.problems.items.properties.figures.items;
  assertEquals(figure(solutionFiguresSchema(false)).required.includes('piece'), false);
  assertEquals(figure(solutionFiguresSchema(true)).required[0], 'piece');
  assertEquals(figure(solutionFiguresSchema(false)).required.includes('piece'), false);
  assertEquals(solutionFiguresInstructions(false).includes('회색 가로선'), true);
  assertEquals(solutionFiguresInstructions(true).includes('회색 가로선'), false);
  assertEquals(solutionFiguresInstructions(true).includes('piece'), true);
});

Deno.test('그림 표시는 [그림] 과 예전 설명형 [그림: …] 을 함께 센다', () => {
  assertEquals(countSolutionFigureMarkers('가 [그림] 나 [그림: 정사각형]'), 2);
  assertEquals(countSolutionFigureMarkers('그림과 같다'), 0);
});

Deno.test('표시를 끼운 전사본은 글자가 원본과 같고 표시 수가 그림 수와 같을 때만 쓴다', () => {
  const original = '좌표평면 위에 나타내면 그림과 같다.';
  assertEquals(
    markedSolutionText(original, '좌표평면 위에 나타내면 그림과 같다.\n[그림]', 1),
    '좌표평면 위에 나타내면 그림과 같다.\n[그림]',
  );
  // 글자가 바뀌었으면 쓰지 않는다
  assertEquals(markedSolutionText(original, '좌표평면에 나타내면 그림과 같다.[그림]', 1), null);
  // 표시 수가 그림 수와 다르면 쓰지 않는다
  assertEquals(markedSolutionText(original, `${original}[그림][그림]`, 1), null);
  // 설명형 표시는 [그림] 으로 바꾼다
  assertEquals(
    markedSolutionText('반례 [그림: 정사각형]', '반례 [그림: 정사각형과 직사각형]', 1),
    '반례 [그림]',
  );
  assertEquals(markedSolutionText(original, original, 0), null);
});

Deno.test('줄마다 문단으로 나눈 전사본에는 원래 줄 구분을 지키고 그림 표시만 옮긴다', () => {
  const original = '그래프는 다음과 같다.\n\n따라서 $a=1$\n\n$b=2$';
  // 모델이 줄을 합쳐 돌려줘도 원래 줄 구분이 남는다
  assertEquals(
    transferFigureMarkers(original, '그래프는 다음과 같다. [그림] 따라서 $a=1$ $b=2$'),
    '그래프는 다음과 같다.\n\n[그림] 따라서 $a=1$\n\n$b=2$',
  );
  // 표시가 따로 한 줄이면 따로 한 문단
  assertEquals(
    transferFigureMarkers(original, '그래프는 다음과 같다.\n[그림]\n따라서 $a=1$\n$b=2$'),
    '그래프는 다음과 같다.\n\n[그림]\n\n따라서 $a=1$\n\n$b=2$',
  );
  // 끝에 붙인 표시, 처음에 붙인 표시
  assertEquals(transferFigureMarkers('가\n\n나', '가\n나\n[그림]'), '가\n\n나\n\n[그림]');
  assertEquals(transferFigureMarkers('가\n\n나', '[그림]\n가\n나'), '[그림]\n\n가\n\n나');
  // 전사본에 있던 표시 자리는 모델이 정한 자리로 바뀐다
  assertEquals(
    transferFigureMarkers('가\n\n[그림]\n\n나\n\n다', '가\n나\n[그림]\n다'),
    '가\n\n나\n\n[그림]\n\n다',
  );
  // 나란히 놓인 그림 둘
  assertEquals(transferFigureMarkers('가\n\n나', '가\n[그림] [그림]\n나'), '가\n\n[그림]\n\n[그림]\n\n나');
});
