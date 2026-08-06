import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/homework_test_grading_result_service.dart';

void main() {
  group('HomeworkGradingProgressRate', () {
    test('미채점은 0% 진행/완료', () {
      final rate = HomeworkGradingProgressRate.emptyEnabled(total: 12);
      expect(rate.enabled, isTrue);
      expect(rate.advanceRate, 0);
      expect(rate.completionRate, 0);
    });

    test('미수행을 제외한 진행률과 정답 완료율을 계산한다', () {
      const rate = HomeworkGradingProgressRate(
        total: 10,
        graded: 8,
        completed: 5,
        enabled: true,
      );
      expect(rate.advanceRate, 0.8);
      expect(rate.completionRate, 0.5);
    });

    test('그룹 합산은 하위 과제를 더한다', () {
      const a = HomeworkGradingProgressRate(
        total: 4,
        graded: 4,
        completed: 2,
        enabled: true,
      );
      const b = HomeworkGradingProgressRate(
        total: 6,
        graded: 3,
        completed: 1,
        enabled: true,
      );
      final merged = a.merge(b);
      expect(merged.total, 10);
      expect(merged.graded, 7);
      expect(merged.completed, 3);
      expect(merged.enabled, isTrue);
    });

    test('비활성끼리 합치면 비활성이다', () {
      final merged = HomeworkGradingProgressRate.disabled
          .merge(HomeworkGradingProgressRate.disabled);
      expect(merged.enabled, isFalse);
    });
  });
}
