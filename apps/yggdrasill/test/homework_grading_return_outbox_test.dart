import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/homework_grading_return_outbox_service.dart';

void main() {
  test('durable grading draft restores every homework key and action', () {
    final draft = HomeworkGradingReturnDraft(
      id: 'request-1',
      studentId: 'student-1',
      groupId: 'group-1',
      action: 'complete',
      payload: const {
        'homework_item_ids': ['item-1', 'item-2', 'item-1', ''],
      },
      createdAt: DateTime(2026, 8, 21),
    );

    expect(draft.markCompleted, isTrue);
    expect(draft.itemIds, ['item-1', 'item-2', 'item-1']);
    expect(
      draft.keys,
      {
        (studentId: 'student-1', itemId: 'item-1'),
        (studentId: 'student-1', itemId: 'item-2'),
      },
    );
  });

  test('confirm draft is restored as a non-completing return', () {
    final draft = HomeworkGradingReturnDraft(
      id: 'request-2',
      studentId: 'student-1',
      groupId: 'group-1',
      action: 'confirm',
      payload: const {
        'homework_item_ids': ['item-1'],
      },
      createdAt: DateTime(2026, 8, 21),
    );

    expect(draft.markCompleted, isFalse);
  });
}
