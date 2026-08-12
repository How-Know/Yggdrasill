import 'package:flutter_test/flutter_test.dart';
import 'package:yggdrasill_student/services/student_api.dart';

void main() {
  Map<String, dynamic> baseRow() => <String, dynamic>{
        'group_id': '00000000-0000-0000-0000-000000000001',
        'group_title': '분수 숙제',
        'order_index': 0,
        'phase': 1,
        'accumulated': 0,
        'cycle_elapsed': 0,
        'check_count': 0,
        'total_count': 10,
        'color': 0,
        'page_summary': '10-12',
        'content': '',
        'type': '교재',
        'm5_wait_title': '',
        'children': <Map<String, dynamic>>[],
        'list_kind': 'in_class',
      };

  test('검사 예정 숙제는 오늘까지로 통일 표시한다', () {
    final today = DateTime.now();
    final todayIso = DateTime(today.year, today.month, today.day, 10)
        .toUtc()
        .toIso8601String();
    final row = baseRow()
      ..addAll(<String, dynamic>{
        'inspection_status': 'due_for_check',
        'original_due_at': todayIso,
        'absence_carryover': false,
        'defer_count': 0,
      });

    final group = HomeworkGroup.fromRow(row);

    expect(group.isDueForCheck, isTrue);
    expect(group.inspectionLabel, '오늘까지');
    expect(group.originalDueDate, isNotNull);
  });

  test('결석 이월·미검사 이월도 학생앱에서는 오늘까지로 표시한다', () {
    final absence = HomeworkGroup.fromRow(
      baseRow()
        ..addAll(<String, dynamic>{
          'inspection_status': 'due_for_check',
          'original_due_at': '2026-08-06T01:00:00Z',
          'absence_carryover': true,
          'defer_count': 1,
          'last_outcome': 'left_behind',
        }),
    );
    final deferred = HomeworkGroup.fromRow(
      baseRow()
        ..addAll(<String, dynamic>{
          'inspection_status': 'due_for_check',
          'original_due_at': '2026-08-06T01:00:00Z',
          'absence_carryover': false,
          'defer_count': 0,
        }),
    );

    expect(absence.inspectionLabel, '오늘까지');
    expect(absence.deferCount, 1);
    expect(absence.lastInspectionOutcome, 'left_behind');
    expect(deferred.inspectionLabel, '오늘까지');
  });
}
