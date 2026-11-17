import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_review_solution_image_service.dart';

/// 흰 바탕에 검은 사각형들을 그린 RGBA
Uint8List _canvas(int w, int h, List<List<int>> rects) {
  final px = Uint8List(w * h * 4)..fillRange(0, w * h * 4, 255);
  for (final r in rects) {
    for (var y = r[0]; y < r[2]; y += 1) {
      for (var x = r[1]; x < r[3]; x += 1) {
        final i = (y * w + x) * 4;
        px[i] = 0;
        px[i + 1] = 0;
        px[i + 2] = 0;
      }
    }
  }
  return px;
}

void main() {
  group('해설 그림 크롭에서 잘린 글 조각 빼기', () {
    test('그림 아래 왼쪽 경계에 닿은 글 조각과 티끌을 뺀다', () {
      final px = _canvas(200, 400, [
        [10, 30, 150, 180], // 그림
        [180, 0, 195, 60], // 잘린 글(왼쪽 경계)
        [215, 0, 230, 40], // 잘린 글(왼쪽 경계)
        [300, 100, 302, 102], // 티끌
      ]);
      final keep = solutionFigureKeepRows(px, 200, 400);
      expect(keep, isNotNull);
      expect(keep!.top, 0);
      expect(keep.bottom, greaterThanOrEqualTo(150));
      expect(keep.bottom, lessThan(180));
    });

    test('그림 아래 떨어진 꼭짓점 이름(경계에 안 닿음)은 남긴다', () {
      final px = _canvas(200, 300, [
        [10, 30, 150, 180],
        [165, 40, 185, 60],
      ]);
      expect(solutionFigureKeepRows(px, 200, 300), isNull);
    });

    test('그림 자체가 경계에 닿으면 손대지 않는다', () {
      final px = _canvas(200, 300, [
        [10, 0, 150, 180],
        [180, 0, 195, 60],
      ]);
      expect(solutionFigureKeepRows(px, 200, 300), isNull);
    });

    test('묶음이 하나면 손대지 않는다', () {
      final px = _canvas(200, 300, [
        [10, 30, 250, 180],
      ]);
      expect(solutionFigureKeepRows(px, 200, 300), isNull);
    });
  });
}
