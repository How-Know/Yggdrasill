import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// 수업 기록 요약(알림장 "오늘의 학습 기록").
///
/// 숫자는 서버 `_lesson_record_compute`가 유일한 원본이다. 정의는
/// docs/architecture/learning-records.md §12. 판정(정상/확인/주의)은 아직 없다.
class LessonRecordService {
  LessonRecordService._internal();
  static final LessonRecordService instance = LessonRecordService._internal();

  /// 하원 전에도 쓸 수 있는 실시간 계산. 저장하지 않는다.
  Future<LessonRecordSummary?> fetchLive(String attendanceId) async {
    final id = attendanceId.trim();
    if (id.isEmpty) return null;
    try {
      final res = await Supabase.instance.client.rpc(
        'staff_lesson_record_v1',
        params: <String, dynamic>{'p_attendance_id': id},
      );
      if (res is! Map) return null;
      return LessonRecordSummary.fromJson(Map<String, dynamic>.from(res));
    } catch (e, st) {
      debugPrint('[LESSON_RECORD][fetchLive][ERROR] $e\n$st');
      return null;
    }
  }

  /// 하원 스냅샷의 요약 숫자를 원자료로 다시 계산해 저장한다.
  /// 스냅샷이 없으면(하원 전) false.
  Future<bool> refresh(String attendanceId) async {
    final id = attendanceId.trim();
    if (id.isEmpty) return false;
    try {
      final res = await Supabase.instance.client.rpc(
        'staff_refresh_lesson_record_v1',
        params: <String, dynamic>{'p_attendance_id': id},
      );
      return res == true;
    } catch (e, st) {
      debugPrint('[LESSON_RECORD][refresh][ERROR] $e\n$st');
      return false;
    }
  }
}

class LessonRecordFlowProgress {
  const LessonRecordFlowProgress({
    required this.flowId,
    required this.flowName,
    required this.completed,
    required this.classItemCount,
    required this.completedItemCount,
    this.bookId,
    this.gradeLabel,
    this.bookName,
    this.textbookTotalProblems,
    this.textbookCompletedBefore,
    this.textbookCompletedProblems,
  });

  final String? flowId;
  final String flowName;

  /// 오늘 수업 과제의 교재. 교재 없는 과제만 있으면 null.
  final String? bookId;
  final String? gradeLabel;
  final String? bookName;
  final bool completed;
  final int classItemCount;
  final int completedItemCount;

  /// 문항 단위로 마이그레이션된 교재만 값이 있다.
  final int? textbookTotalProblems;

  /// 등원 전 완료 문항 수.
  final int? textbookCompletedBefore;

  /// 하원(하원 전이면 계산 시점)까지 완료 문항 수.
  final int? textbookCompletedProblems;

  double? _pctOf(int? count) {
    final total = textbookTotalProblems;
    if (total == null || total <= 0 || count == null) return null;
    return (count.clamp(0, total) * 100) / total;
  }

  double? get progressPercent => _pctOf(textbookCompletedProblems);

  double? get beforePercent => _pctOf(textbookCompletedBefore);

  /// 오늘 수업에서 늘어난 진도(%p). 등원 전 값을 모르면 null.
  double? get todayPercent {
    final total = progressPercent;
    final before = beforePercent;
    if (total == null || before == null) return null;
    return total > before ? total - before : 0;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'flow_id': flowId,
        'flow_name': flowName,
        'book_id': bookId,
        'grade_label': gradeLabel,
        'book_name': bookName,
        'progress_state': completed ? 'completed' : 'in_progress',
        'class_item_count': classItemCount,
        'completed_item_count': completedItemCount,
        'textbook_total_problems': textbookTotalProblems,
        'textbook_completed_before': textbookCompletedBefore,
        'textbook_completed_problems': textbookCompletedProblems,
      };

  factory LessonRecordFlowProgress.fromJson(Map<String, dynamic> json) {
    String? text(dynamic v) {
      final s = (v as String?)?.trim() ?? '';
      return s.isEmpty ? null : s;
    }

    return LessonRecordFlowProgress(
      flowId: json['flow_id'] as String?,
      flowName: (json['flow_name'] as String?) ?? '',
      bookId: text(json['book_id']),
      gradeLabel: text(json['grade_label']),
      bookName: text(json['book_name']),
      completed: json['progress_state'] == 'completed',
      classItemCount: _asInt(json['class_item_count']) ?? 0,
      completedItemCount: _asInt(json['completed_item_count']) ?? 0,
      textbookTotalProblems: _asInt(json['textbook_total_problems']),
      textbookCompletedBefore: _asInt(json['textbook_completed_before']),
      textbookCompletedProblems: _asInt(json['textbook_completed_problems']),
    );
  }
}

class LessonRecordSummary {
  const LessonRecordSummary({
    required this.attendanceId,
    required this.isLive,
    required this.problemRecordCoverage,
    required this.homeworkTotal,
    required this.homeworkCompleted,
    required this.assignmentTotal,
    required this.assignmentCompleted,
    required this.assignmentBasis,
    required this.flows,
    this.solvedProblemCount,
    this.firstTryCorrectCount,
    this.correctionRequiredCount,
    this.correctionSuccessCount,
    this.passedProblemCount,
    this.avgTriesToPass,
  });

  final String attendanceId;
  final bool isLive;

  /// 'full' / 'partial' / 'none'. 'none' 이면 문항 숫자는 모두 null.
  final String problemRecordCoverage;
  final int? solvedProblemCount;
  final int? firstTryCorrectCount;
  final int? correctionRequiredCount;
  final int? correctionSuccessCount;

  /// 푼 문항 중 하원까지 정답이 나온 문항 수.
  final int? passedProblemCount;

  /// [passedProblemCount] 문항의 회차 첫 채점부터 정답까지 채점 수 평균. 완료 문항이 없으면 null.
  final double? avgTriesToPass;
  final int homeworkTotal;
  final int homeworkCompleted;
  final int assignmentTotal;
  final int assignmentCompleted;

  /// 'goal_snapshot' / 'session_plan' / 'none'.
  final String assignmentBasis;
  final List<LessonRecordFlowProgress> flows;

  bool get hasProblemRecords => problemRecordCoverage != 'none';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'attendance_id': attendanceId,
        'is_live': false,
        'problem_record_coverage': problemRecordCoverage,
        'solved_problem_count': solvedProblemCount,
        'first_try_correct_count': firstTryCorrectCount,
        'correction_required_count': correctionRequiredCount,
        'correction_success_count': correctionSuccessCount,
        'passed_problem_count': passedProblemCount,
        'avg_tries_to_pass': avgTriesToPass,
        'homework_total': homeworkTotal,
        'homework_completed': homeworkCompleted,
        'assignment_total': assignmentTotal,
        'assignment_completed': assignmentCompleted,
        'assignment_basis': assignmentBasis,
        'flows': flows.map((flow) => flow.toJson()).toList(growable: false),
      };

  factory LessonRecordSummary.fromJson(Map<String, dynamic> json) {
    final rawFlows = json['flows'];
    return LessonRecordSummary(
      attendanceId: (json['attendance_id'] as String?) ?? '',
      isLive: json['is_live'] == true,
      problemRecordCoverage:
          (json['problem_record_coverage'] as String?) ?? 'none',
      solvedProblemCount: _asInt(json['solved_problem_count']),
      firstTryCorrectCount: _asInt(json['first_try_correct_count']),
      correctionRequiredCount: _asInt(json['correction_required_count']),
      correctionSuccessCount: _asInt(json['correction_success_count']),
      passedProblemCount: _asInt(json['passed_problem_count']),
      avgTriesToPass: _asDouble(json['avg_tries_to_pass']),
      homeworkTotal: _asInt(json['homework_total']) ?? 0,
      homeworkCompleted: _asInt(json['homework_completed']) ?? 0,
      assignmentTotal: _asInt(json['assignment_total']) ?? 0,
      assignmentCompleted: _asInt(json['assignment_completed']) ?? 0,
      assignmentBasis: (json['assignment_basis'] as String?) ?? 'none',
      flows: rawFlows is List
          ? rawFlows
              .whereType<Map>()
              .map((e) => LessonRecordFlowProgress.fromJson(
                    Map<String, dynamic>.from(e),
                  ))
              .toList()
          : const <LessonRecordFlowProgress>[],
    );
  }
}

int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}
