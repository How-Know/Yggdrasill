import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/screens/textbook/textbook_authoring_stage_dialog.dart';

// 수력충전 답지·해설은 중단원 하나를 뽑을 때도 앞뒤 중단원 지면이 함께 훑힌다.
// "단원 마무리 평가" 는 이름이 고정이라, 이름만 보고 코너 블록을 집으면 앞
// 중단원의 마무리 머리가 이번 마무리 블록을 가로챈다. 2-1 답지 8쪽
// "[01~09] ▶p.134~137" 가 본문 p.150~152 블록을 차지해 24문항이 전부 다른
// 단원 답으로 채워졌고, 그 바람에 남은 문항이 0이 되어 정작 이번 마무리가
// 실린 뒤쪽 지면(14쪽)은 훑지도 않고 끝났다.

void main() {
  // 소단원 블록 0~2 와 마무리 블록 3 을 가진 중단원(본문 p.138~152).
  final lowPage = <int, int>{0: 138, 1: 144, 2: 148, 3: 150};
  final highPage = <int, int>{0: 143, 1: 147, 2: 149, 3: 152};
  final cornerOf = <int, String>{0: '', 1: '', 2: '', 3: '단원 마무리 평가'};

  int forHeader(String title, int start, int end) =>
      textbookStageBlockForHeader(
        title: title,
        pageStart: start,
        pageEnd: end,
        lowPage: lowPage,
        highPage: highPage,
        cornerOf: cornerOf,
      );

  test('이번 중단원의 마무리 머리는 쪽이 겹치는 마무리 블록에 붙는다', () {
    expect(forHeader('단원 마무리 평가 [10~12]', 150, 152), 3);
  });

  test('앞 중단원의 마무리 머리는 가로채지 못하고 건너뛴다', () {
    expect(forHeader('단원 마무리 평가 [01~09]', 134, 137), -1);
  });

  test('뒤 중단원의 마무리 머리도 건너뛴다', () {
    expect(forHeader('단원 마무리 평가 [13~18]', 203, 207), -1);
  });

  test('쪽 배지를 못 읽은 마무리 머리만 첫 마무리 블록으로 되짚는다', () {
    expect(forHeader('단원 마무리 평가', 0, 0), 3);
  });

  test('보통 소단원 머리는 쪽이 겹치는 블록을 고른다', () {
    expect(forHeader('11 연립방정식의 활용 - 거리', 144, 147), 1);
    expect(forHeader('12 연립방정식의 활용 - 농도', 148, 149), 2);
    expect(forHeader('01 함수의 뜻', 156, 156), -1);
  });
}
