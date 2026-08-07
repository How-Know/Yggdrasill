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

  test('반환된 숙제는 오늘 검사 표식을 노출한다', () {
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
    expect(group.inspectionLabel, '오늘 검사');
    expect(group.originalDueDate, isNotNull);
  });

  test('결석 뒤 반환된 숙제는 결석 이월 표식을 노출한다', () {
    final row = baseRow()
      ..addAll(<String, dynamic>{
        'inspection_status': 'due_for_check',
        'original_due_at': '2026-08-06T01:00:00Z',
        'absence_carryover': true,
        'defer_count': 1,
        'last_outcome': 'left_behind',
      });

    final group = HomeworkGroup.fromRow(row);

    expect(group.inspectionLabel, '결석 이월 · 오늘 검사');
    expect(group.deferCount, 1);
    expect(group.lastInspectionOutcome, 'left_behind');
  });

  test('등원했는데 검사가 밀린 숙제는 미검사 이월 표식을 노출한다', () {
    final row = baseRow()
      ..addAll(<String, dynamic>{
        'inspection_status': 'due_for_check',
        'original_due_at': '2026-08-06T01:00:00Z',
        'absence_carryover': false,
        'defer_count': 0,
      });

    final group = HomeworkGroup.fromRow(row);

    expect(group.inspectionLabel, '미검사 이월 · 오늘 검사');
  });
}
