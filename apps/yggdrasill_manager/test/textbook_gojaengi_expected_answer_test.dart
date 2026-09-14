import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_manager/services/textbook_vlm_answer_service.dart';

void main() {
  test('고쟁이 E 슬롯은 오래된 unknown 크롭도 중단원 TEST 출처를 갖는다', () {
    final expected = textbookExpectedAnswerFor(
      seriesKey: 'gojaengi',
      problemNumber: '23',
      section: 'unknown',
      subKey: 'E',
      displayPage: 201,
      midName: '경우의 수',
    );

    expect(expected.toJson(), <String, dynamic>{
      'problem_number': '23',
      'corner': '중단원 TEST',
      'title': '경우의 수',
      'page': 201,
    });
  });

  test('고쟁이 A 슬롯은 빈 section이어도 본교재 출처를 갖는다', () {
    final expected = textbookExpectedAnswerFor(
      seriesKey: 'gojaengi',
      problemNumber: '503',
      subKey: 'A',
      displayPage: 133,
    );

    expect(expected.corner, '본교재');
    expect(expected.bodyPage, 133);
  });
}
