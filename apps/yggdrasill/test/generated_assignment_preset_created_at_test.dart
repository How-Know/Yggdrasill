import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/screens/class_content/homework_created_date.dart';
import 'package:mneme_flutter/services/learning_problem_bank_service.dart';

void main() {
  test('게이트웨이 camelCase createdAt을 과제 생성일로 읽는다', () {
    final preset = LearningProblemDocumentExportPreset.fromMap(
      <String, dynamic>{
        'id': '10000000-0000-0000-0000-000000000001',
        'academyId': '20000000-0000-0000-0000-000000000002',
        'displayName': '미리 만든 과제',
        'presetKind': 'assignment',
        'createdAt': '2026-08-10T12:00:00Z',
        'updatedAt': '2026-09-01T12:00:00Z',
      },
    );

    expect(preset.createdAt, DateTime.utc(2026, 8, 10, 12));
    expect(preset.updatedAt, DateTime.utc(2026, 9, 1, 12));
    expect(
      homeworkCreatedDateLabel(
        (preset.createdAt ?? preset.updatedAt)?.toLocal(),
      ),
      '08.10',
    );
  });
}
