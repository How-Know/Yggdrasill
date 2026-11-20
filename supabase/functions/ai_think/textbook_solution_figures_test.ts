import { assertEquals } from 'jsr:@std/assert@1';
import {
  countSolutionFigureMarkers,
  markedSolutionText,
  normalizeFigureBoxes,
  normalizeFigures,
  transferFigureMarkers,
} from './textbook_solution_figures.ts';

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
