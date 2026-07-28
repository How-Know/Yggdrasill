import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_answer_service.dart';

// 개념+유형은 코너(필수 문제 / 쏙쏙 / 탄탄 …)마다, 소단원마다 문항 번호가
// 1번부터 다시 시작한다. 1-1 교재 중단원 1에서는 번호 "1" 인 문항이 다섯 개
// 있었고, 번호를 Map 키로 쓰던 예전 코드는 기대 82개를 43개로 뭉개서 절반이
// 정답 없이 남았다. 그래서 목록의 **위치**로 크롭을 찾는다.

TextbookExpectedAnswerBatch batchOf(
  List<TextbookExpectedAnswer> entries, {
  List<int>? positions,
}) {
  return TextbookExpectedAnswerBatch(
    positions:
        positions ?? <int>[for (var i = 0; i < entries.length; i += 1) i],
    entries: entries,
  );
}

void main() {
  test('같은 번호가 코너마다 있어도 게이트웨이 위치로 각각 연결된다', () {
    final batch = batchOf(const <TextbookExpectedAnswer>[
      TextbookExpectedAnswer(number: '1', corner: '필수 문제', bodyPage: 107),
      TextbookExpectedAnswer(
          number: '1', corner: 'STEP1 쏙쏙 개념 익히기', bodyPage: 112),
      TextbookExpectedAnswer(
          number: '1', corner: 'STEP2 탄탄 단원 다지기', bodyPage: 120),
    ]);
    expect(batch.resolve(detectedNumber: '1', expectedIndex: 0), <int>[0]);
    expect(batch.resolve(detectedNumber: '1', expectedIndex: 1), <int>[1]);
    expect(batch.resolve(detectedNumber: '1', expectedIndex: 2), <int>[2]);
  });

  test('남은 항목만 보낸 호출도 원래 목록 위치로 되돌린다', () {
    // 2회차 호출은 아직 못 채운 3·5번째 항목만 보낸다. 게이트웨이가 주는
    // 인덱스는 그 호출 배열 기준이라 원래 위치로 되짚어야 한다.
    final batch = batchOf(
      const <TextbookExpectedAnswer>[
        TextbookExpectedAnswer(number: '4', corner: '필수 문제', bodyPage: 109),
        TextbookExpectedAnswer(number: '2', corner: '탄탄', bodyPage: 120),
      ],
      positions: <int>[3, 5],
    );
    expect(batch.resolve(detectedNumber: '4', expectedIndex: 0), <int>[3]);
    expect(batch.resolve(detectedNumber: '2', expectedIndex: 1), <int>[5]);
  });

  test('위치를 못 받으면 번호로 되짚고, 겹치면 하나만 집는다', () {
    final batch = batchOf(const <TextbookExpectedAnswer>[
      TextbookExpectedAnswer(number: '1', corner: '필수 문제', bodyPage: 107),
      TextbookExpectedAnswer(number: '1', corner: '쏙쏙', bodyPage: 112),
    ]);
    // 근거 없이 두 크롭에 같은 정답을 붙이면 틀린 정답이 조용히 저장된다.
    expect(batch.resolve(detectedNumber: '1'), <int>[0]);
  });

  test('접두어가 붙은 번호는 접두어까지 구분한다', () {
    final batch = batchOf(const <TextbookExpectedAnswer>[
      TextbookExpectedAnswer(number: '예제1', corner: '쓱쓱 서술형 완성하기'),
      TextbookExpectedAnswer(number: '유제1', corner: '쓱쓱 서술형 완성하기'),
      TextbookExpectedAnswer(number: '연습1', corner: '쓱쓱 서술형 완성하기'),
    ]);
    expect(batch.resolve(detectedNumber: '유제1'), <int>[1]);
    expect(batch.resolve(detectedNumber: '연습1'), <int>[2]);
  });

  test('범위 정답은 범위에 드는 기대 항목 전부에 붙는다', () {
    final batch = batchOf(const <TextbookExpectedAnswer>[
      TextbookExpectedAnswer(number: '1'),
      TextbookExpectedAnswer(number: '2'),
      TextbookExpectedAnswer(number: '3'),
      TextbookExpectedAnswer(number: '9'),
    ]);
    expect(batch.resolve(detectedNumber: '1~3'), <int>[0, 1, 2]);
  });

  test('기대 목록에 없는 번호는 버린다', () {
    final batch = batchOf(const <TextbookExpectedAnswer>[
      TextbookExpectedAnswer(number: '1'),
    ]);
    expect(batch.resolve(detectedNumber: '77'), isEmpty);
    // 범위를 벗어난 인덱스도 믿지 않는다.
    expect(batch.resolve(detectedNumber: '77', expectedIndex: 9), isEmpty);
  });
}
