import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/screens/class_content/homework_performance_attempt.dart';

void main() {
  test('생성 직후 대기는 시도 0이다', () {
    expect(
      homeworkPerformanceAttemptIndex(checkCount: 0, phase: 1),
      0,
    );
  });

  test('첫 수행·제출은 시도 1이다', () {
    expect(
      homeworkPerformanceAttemptIndex(checkCount: 0, phase: 2),
      1,
    );
    expect(
      homeworkPerformanceAttemptIndex(checkCount: 0, phase: 3),
      1,
    );
  });

  test('확인 후 대기·확인은 끝난 시도 수를 유지한다', () {
    expect(
      homeworkPerformanceAttemptIndex(checkCount: 1, phase: 4),
      1,
    );
    expect(
      homeworkPerformanceAttemptIndex(checkCount: 1, phase: 1),
      1,
    );
  });

  test('확인 후 재수행은 다음 차수다', () {
    expect(
      homeworkPerformanceAttemptIndex(checkCount: 1, phase: 2),
      2,
    );
    expect(
      homeworkPerformanceAttemptIndex(checkCount: 1, phase: 3),
      2,
    );
  });
}
