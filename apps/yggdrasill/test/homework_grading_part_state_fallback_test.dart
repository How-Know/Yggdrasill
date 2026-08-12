import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/homework_test_grading_result_service.dart';

void main() {
  test('수정 차수 컬럼이 없어도 저장된 파트별 정오를 조회한다', () {
    final select = homeworkGradingSavedItemSelect(
      excludedColumns: const {'correction_attempt_number'},
    );

    expect(select, isNot(contains('correction_attempt_number')));
    expect(select, contains('part_states'));
    expect(select, contains('question_key'));
    expect(select, contains('state'));
  });

  test('호환 저장에서도 파트별 정오를 제거하지 않는다', () {
    final row = homeworkGradingCompatibilityItemRow({
      'question_key': 'homework|16|3|problem',
      'state': 'wrong',
      'baseline_attempt_id': 'baseline',
      'baseline_state': 'wrong',
      'correction_state': 'corrected',
      'correction_attempt_number': 2,
      'part_states': const {
        '(1)': 'correct',
        '(2)': 'wrong',
      },
    });

    expect(row['part_states'], {
      '(1)': 'correct',
      '(2)': 'wrong',
    });
    expect(row, isNot(contains('baseline_attempt_id')));
    expect(row, isNot(contains('baseline_state')));
    expect(row, isNot(contains('correction_state')));
    expect(row, isNot(contains('correction_attempt_number')));
  });
}
