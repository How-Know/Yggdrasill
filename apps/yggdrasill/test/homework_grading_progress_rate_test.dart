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

    test('진행률은 수행분/유효전체, 완료율은 정답/유효전체', () {
      const rate = HomeworkGradingProgressRate(
        total: 10,
        graded: 8,
        completed: 5,
        enabled: true,
      );
      expect(rate.advanceRate, 0.8);
      expect(rate.completionRate, 0.5);
      expect(rate.completionRate, lessThanOrEqualTo(rate.advanceRate));
    });

    test('수행분이 모두 정답이어도 미수행이 있으면 완료율은 진행률과 같고 100% 미만', () {
      const rate = HomeworkGradingProgressRate(
        total: 12,
        graded: 7,
        completed: 7,
        enabled: true,
      );
      expect(rate.advanceRate, closeTo(7 / 12, 1e-9));
      expect(rate.completionRate, closeTo(7 / 12, 1e-9));
      expect(rate.completionRate, lessThanOrEqualTo(rate.advanceRate));
      expect((rate.completionRate * 100).round(), isNot(100));
    });

    test('포기 제외 전부가 정답이면 진행/완료 모두 100%', () {
      const rate = HomeworkGradingProgressRate(
        total: 10,
        graded: 10,
        completed: 10,
        enabled: true,
      );
      expect(rate.advanceRate, 1.0);
      expect(rate.completionRate, 1.0);
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
      expect(merged.completionRate, lessThanOrEqualTo(merged.advanceRate));
    });

    test('그룹 전체 채점을 대표 하위에 저장한 경우 fallback을 다시 합산하지 않는다', () {
      const groupWide = HomeworkGradingProgressRate(
        total: 17,
        graded: 17,
        completed: 16,
        recordedQuestionCount: 17,
        enabled: true,
      );
      final selected = findGroupWideHomeworkProgressRate(
        const [groupWide],
        groupQuestionCount: 17,
      );

      expect(selected, same(groupWide));
      expect((selected!.completionRate * 100).round(), 94);

      // 기존 중복 계산은 17문항 전체 채점에 나머지 하위 16문항을 또 더해
      // 16 / 33 = 48%를 만들었다.
      final duplicated =
          groupWide.merge(HomeworkGradingProgressRate.emptyEnabled(total: 16));
      expect((duplicated.completionRate * 100).round(), 48);
    });

    test('포기가 있어 유효 분모가 작아져도 저장 문항 수로 그룹 전체 채점을 찾는다', () {
      const groupWide = HomeworkGradingProgressRate(
        total: 16,
        graded: 16,
        completed: 15,
        recordedQuestionCount: 17,
        enabled: true,
      );
      final selected = findGroupWideHomeworkProgressRate(
        const [groupWide],
        groupQuestionCount: 17,
      );

      expect(selected, same(groupWide));
      expect(selected!.total, 16);
    });

    test('비활성끼리 합치면 비활성이다', () {
      final merged = HomeworkGradingProgressRate.disabled
          .merge(HomeworkGradingProgressRate.disabled);
      expect(merged.enabled, isFalse);
    });
  });
}
