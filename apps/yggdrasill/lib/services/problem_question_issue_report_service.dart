import 'package:supabase_flutter/supabase_flutter.dart';

class ProblemQuestionIssueType {
  const ProblemQuestionIssueType(this.key, this.label);

  final String key;
  final String label;
}

const List<ProblemQuestionIssueType> kProblemQuestionIssueTypes =
    <ProblemQuestionIssueType>[
  ProblemQuestionIssueType('question_typo', '문제 오타'),
  ProblemQuestionIssueType('answer_typo', '정답 오타'),
  ProblemQuestionIssueType('question_error', '문항 오류'),
  ProblemQuestionIssueType('missing_answer', '정답 없음'),
  ProblemQuestionIssueType('figure_mismatch', '그림 매칭 잘못됨'),
  ProblemQuestionIssueType('figure_size_error', '그림 크기 잘못됨'),
  ProblemQuestionIssueType('figure_error', '그림 오류'),
  ProblemQuestionIssueType('solution_coordinate_error', '해설 좌표 오류'),
  ProblemQuestionIssueType('solution_content_error', '해설/풀이 오류'),
  ProblemQuestionIssueType('classification_error', '문항 범위/분류 오류'),
];

class ProblemQuestionIssueReportService {
  ProblemQuestionIssueReportService._();

  static final ProblemQuestionIssueReportService instance =
      ProblemQuestionIssueReportService._();

  final SupabaseClient _client = Supabase.instance.client;

  Future<void> createReport({
    required String academyId,
    required String questionId,
    required List<String> issueTypes,
    String homeworkItemId = '',
    String studentId = '',
    String note = '',
  }) async {
    final safeAcademyId = academyId.trim();
    final safeQuestionId = questionId.trim();
    final safeTypes = issueTypes
        .map((type) => type.trim())
        .where((type) => type.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (safeAcademyId.isEmpty || safeQuestionId.isEmpty || safeTypes.isEmpty) {
      throw ArgumentError('missing_issue_report_required_fields');
    }
    await _client.from('pb_question_issue_reports').insert({
      'academy_id': safeAcademyId,
      'question_id': safeQuestionId,
      if (homeworkItemId.trim().isNotEmpty)
        'homework_item_id': homeworkItemId.trim(),
      if (studentId.trim().isNotEmpty) 'student_id': studentId.trim(),
      'reporter_user_id': _client.auth.currentUser?.id,
      'issue_types': safeTypes,
      'note': note.trim(),
      'status': 'open',
    });
  }
}
