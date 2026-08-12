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
      expect(group.dueDate, isNotNull);
      expect(group.recommendedMinutes, 35);
      expect(group.digitalSolvable, isTrue);
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
