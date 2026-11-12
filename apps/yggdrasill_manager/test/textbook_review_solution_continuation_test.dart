import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_problem_review_service.dart';
import 'package:yggdrasill_manager/services/textbook_review_solution_image_service.dart';

SolutionRefBox ref(int page, int top, {required bool right}) => SolutionRefBox(
      rawPage: page,
      numberTop: top,
      region1k: right ? [top, 495, top + 100, 995] : [top, 70, top + 100, 492],
    );

void main() {
  final usual = [
    ref(55, 65, right: false),
    ref(55, 66, right: true),
    ref(56, 64, right: false),
    ref(56, 67, right: true),
  ];

  test('오른쪽 단 맨 아래에서 끊긴 풀이는 다음 쪽 왼쪽 단 첫 번호 위를 이어 붙인다', () {
    final seg = solutionContinuationSegment(
      rawPage: 56,
      region1k: const [827, 495, 990, 995],
      refs: [...usual, ref(57, 139, right: false), ref(57, 66, right: true)],
    );
    expect(seg, isNotNull);
    expect(seg!.rawPage, 57);
    expect(seg.region1k[0], lessThan(66));
    expect(seg.region1k[2], lessThan(139));
    expect(seg.region1k[1], 70);
  });

  test('왼쪽 단이면 같은 쪽 오른쪽 단을 본다', () {
    final seg = solutionContinuationSegment(
      rawPage: 56,
      region1k: const [800, 70, 990, 492],
      refs: [ref(55, 65, right: false), ref(55, 66, right: true), ref(56, 64, right: false), ref(56, 140, right: true)],
    );
    expect(seg?.rawPage, 56);
    expect(seg?.region1k[1], 495);
  });

  test('다음 단 첫 번호가 평소 자리면, 또는 단 끝에 닿지 않았으면 이어 붙이지 않는다', () {
    final refs = [...usual, ref(57, 64, right: false)];
    expect(solutionContinuationSegment(rawPage: 56, region1k: const [827, 495, 990, 995], refs: refs), isNull);
    expect(solutionContinuationSegment(rawPage: 56, region1k: const [700, 495, 900, 995], refs: refs), isNull);
    expect(solutionContinuationSegment(rawPage: 56, region1k: const [827, 495, 990, 995], refs: usual), isNull);
  });

  test('이어 붙인 이미지의 상자를 조각 쪽 좌표로 되돌린다', () {
    final stack = TextbookReviewRenderedStack(
      bytes: Uint8List(0),
      widthPx: 1000,
      heightPx: 1024,
      parts: [
        TextbookReviewRenderedRegion(bytes: Uint8List(0), widthPx: 1000, heightPx: 500, region1k: const [800, 495, 1000, 995], rawPage: 56),
        TextbookReviewRenderedRegion(bytes: Uint8List(0), widthPx: 1000, heightPx: 500, region1k: const [50, 60, 130, 500], rawPage: 57),
      ],
      topsPx: const [0, 524],
    );
    final upper = stack.locate(const [100, 100, 300, 500])!;
    expect(upper.part.rawPage, 56);
    final lower = stack.locate(const [600, 100, 800, 500])!;
    expect(lower.part.rawPage, 57);
    expect(lower.box[0], closeTo((600 * 1.024 - 524) * 2, 2));
  });
}
