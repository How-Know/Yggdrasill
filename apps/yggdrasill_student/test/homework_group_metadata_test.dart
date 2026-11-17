import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/student_api.dart';

void main() {
  group('HomeworkGroup metadata parsing', () {
    test('parses new snake_case metadata', () {
      final group = HomeworkGroup.fromRow({
        'group_id': 'group-1',
        'list_kind': 'homework',
        'assignment_origin': 'class_carryover',
        'due_date': '2026-08-06',
        'recommended_minutes': 35,
        'digital_solvable': true,
      });

      expect(group.listKind, HomeworkListKind.homework);
      expect(
        group.assignmentOrigin,
        HomeworkAssignmentOrigin.classCarryover,
      );
      expect(group.assignmentOriginLabel, '8월 6일까지');
      expect(group.dueAt, isNull);
      expect(
        group.dueUntilLabel(now: DateTime(2026, 8, 1)),
        '8월 6일까지',
      );
      expect(group.dueDate, isNotNull);
      expect(group.recommendedMinutes, 35);
      expect(group.digitalSolvable, isTrue);
    });

    test('숙제 종료 시각은 날짜와 시각을 칩 문구로 만든다', () {
      final group = HomeworkGroup.fromRow({
        'group_id': 'group-due',
        'list_kind': 'homework',
        'due_date': '2026-11-20',
        'current_due_at': '2026-11-20T09:30:00Z',
      });
      final due = group.dueAt!;
      final period = due.hour < 12 ? '오전' : '오후';
      final hour12 = due.hour % 12 == 0 ? 12 : due.hour % 12;
      final minute = due.minute.toString().padLeft(2, '0');
      final clock = '$period $hour12:$minute';

      expect(
        group.dueUntilLabel(now: DateTime(due.year, due.month, due.day)),
        '오늘 $clock까지',
      );
      expect(
        group.dueUntilLabel(
          now: DateTime(due.year, due.month, due.day).subtract(
            const Duration(days: 3),
          ),
        ),
        '${due.month}월 ${due.day}일 $clock까지',
      );
    });

    test('falls back to legacy homework-only source', () {
      final group = HomeworkGroup.fromRow(
        {
          'group_id': 'group-2',
          'type': '출력물',
        },
        homeworkOnly: true,
      );

      expect(group.listKind, HomeworkListKind.homework);
      expect(group.assignmentOrigin, HomeworkAssignmentOrigin.direct);
      expect(group.digitalSolvable, isFalse);
      expect(group.isHomeworkOnly, isTrue);
    });

    test('falls back to in-class for legacy main source', () {
      final group = HomeworkGroup.fromRow({
        'group_id': 'group-3',
        'type': '교재',
      });

      expect(group.listKind, HomeworkListKind.inClass);
      expect(group.assignmentOrigin, HomeworkAssignmentOrigin.unknown);
      expect(group.digitalSolvable, isTrue);
    });
  });
}
