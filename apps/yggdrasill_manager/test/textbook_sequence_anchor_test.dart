import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_authoring_stage_dialog.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_answer_service.dart';

// 개념+유형 고등 공통수학1 Ⅱ-4 실사례. 해설 63~66쪽은 01 소단원(본문 150~163쪽),
// 70~74쪽은 02 소단원(본문 165~177쪽)이다. 두 소단원 모두 "02-1" 이 있어,
// 02 소단원의 02-1~03-3 만 다시 돌리자 해설 64쪽의 01 소단원 풀이를 집었다.
void main() {
  test('앞 문항이 찾힌 해설 쪽보다 앞 지면에서는 묻지 않는다', () {
    final anchors = textbookConsistentAnchors(const [
      (bodyPage: 153, page: 63),
      (bodyPage: 154, page: 64),
      (bodyPage: 165, page: 70),
      (bodyPage: 166, page: 70),
      (bodyPage: 170, page: 72),
    ]);
    // 02 소단원 02-1 (본문 167쪽)
    expect(
      textbookSequenceAllowsPage(anchors: anchors, bodyPage: 167, page: 64),
      isFalse,
    );
    expect(
      textbookSequenceAllowsPage(anchors: anchors, bodyPage: 167, page: 71),
      isTrue,
    );
    expect(
      textbookSequenceAllowsPage(anchors: anchors, bodyPage: 167, page: 73),
      isFalse,
    );
  });

  test('차례와 어긋난 저장값은 앵커에서 빠진다', () {
    final anchors = textbookConsistentAnchors(const [
      (bodyPage: 153, page: 63),
      (bodyPage: 155, page: 65),
      (bodyPage: 158, page: 66),
      (bodyPage: 161, page: 67),
      (bodyPage: 166, page: 70),
      // 잘못 붙은 02-1·02-2·03-1
      (bodyPage: 167, page: 64),
      (bodyPage: 168, page: 64),
      (bodyPage: 170, page: 72),
      (bodyPage: 175, page: 73),
    ]);
    expect(anchors.map((a) => a.bodyPage), [153, 155, 158, 161, 166, 170, 175]);
    expect(
      textbookSequenceAllowsPage(anchors: anchors, bodyPage: 168, page: 71),
      isTrue,
    );
  });

  test('같은 본문 쪽에 제대로 붙은 저장값이 있으면 잘못 붙은 하나가 범위를 막지 않는다', () {
    // 연습문제 17·18(177쪽)이 해설 70쪽에 잘못 저장되고 14~16 은 75쪽에 제대로 저장됨.
    final anchors = textbookConsistentAnchors(const [
      (bodyPage: 166, page: 70),
      (bodyPage: 177, page: 70),
      (bodyPage: 177, page: 75),
    ]);
    expect(
      textbookSequenceAllowsPage(anchors: anchors, bodyPage: 171, page: 72),
      isTrue,
    );
  });

  test('같은 본문 쪽 문항끼리는 범위를 묶지 않는다', () {
    final anchors = textbookConsistentAnchors(const [
      (bodyPage: 175, page: 74),
    ]);
    expect(
      textbookSequenceAllowsPage(anchors: anchors, bodyPage: 175, page: 73),
      isTrue,
    );
  });

  test('같은 번호·코너가 여럿이면 본문 차례상 앞선 것만 표시한다', () {
    const numbers = <int, String>{0: '02-1', 1: '02-1', 2: '03-3', 3: '1', 4: '1'};
    const corners = <int, String>{
      0: '문제',
      1: '문제',
      2: '문제',
      3: '개념 Check',
      4: '연습문제',
    };
    const pages = <int, int>{0: 180, 1: 167, 2: 168, 3: 170, 4: 175};
    final frontier = textbookFrontierPositions(
      order: const [0, 1, 2, 3, 4],
      keyOf: (p) => '${corners[p]}|${textbookAnswerNumberKey(numbers[p]!)}',
      bodyPageOf: (p) => pages[p]!,
    );
    expect(frontier, {1});
  });

  test('읽는 순서보다 본문 차례가 앞선 해설 좌표는 버린다', () {
    // 해설 70쪽: 왼쪽 단 맨 위 01 소단원 연습문제 17·18 을 모델이 "177쪽" 으로 적었다.
    final dropped = textbookOutOfReadingOrder(const [
      (bodyPage: 177, region: [40, 60, 60, 100]),
      (bodyPage: 177, region: [200, 60, 220, 100]),
      (bodyPage: 165, region: [420, 60, 440, 100]),
      (bodyPage: 165, region: [600, 60, 620, 100]),
      (bodyPage: 165, region: [800, 60, 820, 100]),
      (bodyPage: 166, region: [100, 540, 120, 580]),
      (bodyPage: 166, region: [500, 540, 520, 580]),
    ]);
    expect(dropped, {0, 1});
  });

  test('왼쪽 단 아래가 오른쪽 단 위보다 먼저 읽힌다', () {
    final dropped = textbookOutOfReadingOrder(const [
      (bodyPage: 171, region: [50, 560, 70, 600]),
      (bodyPage: 170, region: [800, 60, 820, 100]),
      (bodyPage: 0, region: [10, 10, 20, 20]),
      (bodyPage: 172, region: null),
    ]);
    expect(dropped, isEmpty);
  });

  test('frontier 표시는 요청 JSON 에 실린다', () {
    const expected = TextbookExpectedAnswer(
      number: '02-1',
      corner: '문제',
      bodyPage: 167,
    );
    expect(expected.toJson().containsKey('frontier'), isFalse);
    expect(expected.asFrontier().toJson()['frontier'], isTrue);
  });
}
