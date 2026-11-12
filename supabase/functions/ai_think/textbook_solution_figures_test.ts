import { assertEquals } from 'jsr:@std/assert@1';
import {
  countSolutionFigureMarkers,
  markedSolutionText,
  normalizeFigureBoxes,
  normalizeFigures,
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
