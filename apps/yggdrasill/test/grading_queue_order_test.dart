import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/screens/class_content/grading_queue_order.dart';

void main() {
  test('숙제 카드가 제출 카드로 바뀌어도 최초 대기열 위치를 유지한다', () {
    final retained = <String, DateTime>{};
    final identity = gradingQueueEntryIdentity(
      studentId: 'student-1',
      groupId: 'group-1',
      summaryId: 'summary-1',
    );
    final arrival = DateTime(2026, 8, 12, 15);
    final submitted = DateTime(2026, 8, 12, 16);

    expect(
      retainGradingQueueTime(
        retained,
        entryIdentity: identity,
        candidate: arrival,
      ),
      arrival,
    );
    expect(
      retainGradingQueueTime(
        retained,
        entryIdentity: identity,
        candidate: submitted,
      ),
      arrival,
    );
  });

  test('처음부터 제출 카드인 경우 실제 제출 시각을 사용한다', () {
    final retained = <String, DateTime>{};
    final submitted = DateTime(2026, 8, 12, 16);

    expect(
      retainGradingQueueTime(
        retained,
        entryIdentity: gradingQueueEntryIdentity(
          studentId: 'student-1',
          summaryId: 'item-1',
        ),
        candidate: submitted,
      ),
      submitted,
    );
  });

  test('그룹 카드는 섹션과 대표 항목이 바뀌어도 같은 식별자를 사용한다', () {
    final before = gradingQueueEntryIdentity(
      studentId: 'student-1',
      groupId: 'group-1',
      summaryId: 'homework-summary',
    );
    final after = gradingQueueEntryIdentity(
      studentId: 'student-1',
      groupId: 'group-1',
      summaryId: 'submitted-summary',
    );

    expect(after, before);
  });

  group('미제출 숙제 채점모드 노출', () {
    final now = DateTime(2026, 8, 23, 22);

    test('오늘 배정했고 검사일이 미래면 숨긴다', () {
      expect(
        shouldShowUnsubmittedHomeworkInGradingMode(
          schedules: [
            GradingHomeworkSchedule(
              assignedAt: DateTime(2026, 8, 23, 9),
              dueForCheckAt: DateTime(2026, 8, 24, 13),
            ),
          ],
          now: now,
        ),
        isFalse,
      );
    });

    test('오늘 생성된 반복 배정이어도 검사일이 오늘이면 노출한다', () {
      expect(
        shouldShowUnsubmittedHomeworkInGradingMode(
          schedules: [
            GradingHomeworkSchedule(
              assignedAt: DateTime(2026, 8, 23, 0, 0, 5),
              dueForCheckAt: DateTime(2026, 8, 23, 13),
            ),
          ],
          now: now,
        ),
        isTrue,
      );
    });

    test('검사일이 없으면 이전 배정만 노출한다', () {
      expect(
        shouldShowUnsubmittedHomeworkInGradingMode(
          schedules: [
            GradingHomeworkSchedule(
              assignedAt: DateTime(2026, 8, 22, 18),
            ),
          ],
          now: now,
        ),
        isTrue,
      );
    });

    test('활성 배정이 없으면 노출하지 않는다', () {
      expect(
        shouldShowUnsubmittedHomeworkInGradingMode(
          schedules: const [],
          now: now,
        ),
        isFalse,
      );
    });
  });
}
