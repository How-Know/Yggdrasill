import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/mock_exam_resource_service.dart';

void main() {
  test('문항을 가진 구간을 읽는다', () {
    expect(
      mockQuestionOwnSection({
        'mock_exam_item': {'exam_id': 'e', 'section': 'na', 'item_id': 'i'},
      }),
      'na',
    );
    expect(mockQuestionOwnSection({}), '');
    expect(mockQuestionOwnSection({'mock_exam_item': 'na'}), '');
    expect(mockQuestionOwnSection({'mock_exam_item': {'section': null}}), '');
  });

  test('가형·나형 자리의 형식은 그 시험지 번호로 정한다', () {
    // 나형 15번(객관식) 문항을 가형 26번 자리가 가리키면 가형에서는 단답형이다.
    expect(mockExamIsObjective(3, 15, 'na'), isTrue);
    expect(mockExamIsObjective(3, 26, 'ga'), isFalse);
  });
}
