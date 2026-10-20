import 'package:flutter_test/flutter_test.dart';
import 'package:mneme_flutter/services/learning_problem_bank_service.dart';

void main() {
  test('export job keeps question row ids apart from ordered uids', () {
    final job = LearningProblemExportJob.fromMap(<String, dynamic>{
      'id': 'job-1',
      'status': 'completed',
      'selected_question_ids': <String>['row-a', ' row-b '],
      'options': <String, dynamic>{
        'selectedQuestionUidsOrdered': <String>['uid-a', 'uid-b'],
      },
      'created_at': '2026-10-12T07:41:45.307418+00:00',
      'started_at': '2026-10-12T07:41:46.877+00:00',
    });

    expect(job.selectedQuestionUids, <String>['uid-a', 'uid-b']);
    expect(job.selectedQuestionRowIds, <String>['row-a', 'row-b']);
    expect(job.startedAt, DateTime.utc(2026, 10, 12, 7, 41, 46, 877));
  });

  test('export job without selected_question_ids has no row ids', () {
    final job = LearningProblemExportJob.fromMap(<String, dynamic>{
      'id': 'job-2',
      'options': <String, dynamic>{
        'selectedQuestionUidsOrdered': <String>['uid-a'],
      },
    });

    expect(job.selectedQuestionRowIds, isEmpty);
  });
}
