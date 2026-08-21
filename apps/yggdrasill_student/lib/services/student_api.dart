import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_config.dart';
import 'student_avatar_session.dart';

enum HomeworkListKind {
  inClass,
  homework;

  static HomeworkListKind parse(
    Object? raw, {
    required bool homeworkOnlyFallback,
  }) {
    final value = '$raw'.trim().toLowerCase().replaceAll('-', '_');
    switch (value) {
      case 'in_class':
      case 'inclass':
      case 'class':
        return HomeworkListKind.inClass;
      case 'homework':
      case 'homework_only':
        return HomeworkListKind.homework;
      default:
        return homeworkOnlyFallback
            ? HomeworkListKind.homework
            : HomeworkListKind.inClass;
    }
  }
}

enum HomeworkAssignmentOrigin {
  direct,
  classCarryover,
  unknown;

  static HomeworkAssignmentOrigin parse(
    Object? raw, {
    required HomeworkListKind listKind,
  }) {
    final value = '$raw'.trim().toLowerCase().replaceAll('-', '_');
    switch (value) {
      case 'direct':
      case 'direct_homework':
      case 'homework_direct':
        return HomeworkAssignmentOrigin.direct;
      case 'class_carryover':
      case 'carryover':
      case 'in_class':
      case 'class':
        return HomeworkAssignmentOrigin.classCarryover;
      default:
        return listKind == HomeworkListKind.homework
            ? HomeworkAssignmentOrigin.direct
            : HomeworkAssignmentOrigin.unknown;
    }
  }
}

/// 과제 그룹 (m5_list_homework_groups와 동일 형태).
class HomeworkGroup {
  HomeworkGroup({
    required this.groupId,
    required this.title,
    required this.orderIndex,
    required this.phase,
    required this.accumulated,
    required this.cycleElapsed,
    required this.checkCount,
    required this.totalCount,
    required this.color,
    required this.pageSummary,
    required this.runStart,
    required this.content,
    required this.type,
    required this.timeLimitMinutes,
    this.recommendedMinutes,
    required this.waitTitle,
    required this.children,
    this.bookId = '',
    this.gradeLabel = '',
    this.isTest = false,
    this.isNaesin = false,
    this.pendingComplete = false,
    this.isHomeworkOnly = false,
    this.listKind = HomeworkListKind.inClass,
    this.assignmentOrigin = HomeworkAssignmentOrigin.unknown,
    this.dueDate,
    this.digitalSolvable = false,
    this.inspectionStatus = '',
    this.originalDueDate,
    this.absenceCarryover = false,
    this.deferCount = 0,
    this.lastInspectionOutcome = '',
    this.isAdditionalAfterSnapshot = false,
  });

  final String groupId;
  final String title;
  final int orderIndex;
  final int phase;
  final int accumulated; // 누적(초)
  final int cycleElapsed; // 현재 사이클 경과(초)
  final int checkCount;
  final int totalCount;
  final int color;
  final String pageSummary;
  final DateTime? runStart;
  final String content;
  final String type;

  /// 시험 제한시간(분). 권장시간과 다름.
  final int? timeLimitMinutes;

  /// 권장 소요시간(분). 학습앱 홈 카드와 동일 집계.
  final int? recommendedMinutes;
  final String waitTitle;
  final List<HomeworkChild> children;
  final String bookId;
  final String gradeLabel;
  bool isTest;
  bool isNaesin;
  bool pendingComplete;
  final bool isHomeworkOnly;
  final HomeworkListKind listKind;
  final HomeworkAssignmentOrigin assignmentOrigin;
  final DateTime? dueDate;
  final bool digitalSolvable;
  final String inspectionStatus;
  final DateTime? originalDueDate;
  final bool absenceCarryover;
  final int deferCount;
  final String lastInspectionOutcome;

  /// 목표 제시(스냅샷) 이후에 추가된 오늘 수업 그룹.
  /// 서버 title은 그대로 두고, 홈 카드 표시에만 '+' 접두를 쓴다.
  bool isAdditionalAfterSnapshot;

  bool get isInClass => listKind == HomeworkListKind.inClass;
  bool get isHomework => listKind == HomeworkListKind.homework;
  bool get isDueForCheck => inspectionStatus == 'due_for_check';

  String get inspectionLabel {
    if (!isDueForCheck) return '';
    return '오늘까지';
  }

  /// 숙제 마감일 칩. 예: `3월 12일까지`
  String get assignmentOriginLabel {
    final due = dueDate;
    if (due == null) return '';
    final local = due.toLocal();
    return '${local.month}월 ${local.day}일까지';
  }

  /// 출력물/프린트 출처 — 표지 대신 흰 배경.
  bool get isPrintSource {
    final t = type.trim();
    return t == '출력물' || t == '프린트';
  }

  /// content의 `교재:` 줄, 없으면 type 라벨.
  String get sourceLabel {
    final fromContent = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)')
        .firstMatch(content)
        ?.group(1)
        ?.trim();
    if (fromContent != null && fromContent.isNotEmpty) return fromContent;
    final t = type.trim();
    if (t.isNotEmpty) return t;
    return '';
  }

  /// content의 `과정:` 줄, 없으면 grade_label.
  String get courseLabel {
    final fromContent = RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)')
        .firstMatch(content)
        ?.group(1)
        ?.trim();
    if (fromContent != null && fromContent.isNotEmpty) return fromContent;
    return gradeLabel.trim();
  }

  /// 1행: 교재명(출처), 과정명
  String get primaryMetaLine {
    final source = sourceLabel;
    final course = courseLabel;
    if (source.isEmpty && course.isEmpty) return '-';
    if (source.isEmpty) return course;
    if (course.isEmpty) return source;
    return '$source, $course';
  }

  /// 권장 소요 시간 (예: `1시간 30분 소요 예정` / `45분 소요 예정`).
  /// [recommendedMinutes]가 없거나 0 이하면 빈 문자열.
  String get recommendedDurationLine {
    final minutes = recommendedMinutes ?? 0;
    if (minutes <= 0) return '';
    final hours = minutes ~/ 60;
    final mins = minutes % 60;
    final String amount;
    if (hours > 0 && mins > 0) {
      amount = '$hours시간 $mins분';
    } else if (hours > 0) {
      amount = '$hours시간';
    } else {
      amount = '$mins분';
    }
    return '$amount 소요 예정';
  }

  /// 실제 수행시간(누적+현재 사이클) ÷ 문항수 — 학생 페이스.
  /// 예: `한 문제당 약 60분`. 문항수·수행시간이 없으면 빈 문자열.
  String averagePacePerProblemLine({required bool isRunning}) {
    final count = totalCount;
    if (count <= 0) return '';
    final sec = liveTotalElapsedSec(isRunning: isRunning);
    if (sec <= 0) return '';
    final per = sec / count / 60.0;
    if (per < 1) {
      final secs = (per * 60).round();
      if (secs <= 0) return '';
      return '한 문제당 약 $secs초';
    }
    final whole = per.round();
    if ((per - whole).abs() < 0.05) {
      return '한 문제당 약 $whole분';
    }
    return '한 문제당 약 ${per.toStringAsFixed(1)}분';
  }

  /// 3행: 페이지 · 문항수 (예: `p.10-12 · 12문항`)
  ///
  /// 서버 `page_summary` 우선. 비어 있으면 하위과제 page(이미 item_pages 로
  /// 채워진 값 포함)를 이어 붙여 학습앱과 같이 보이게 한다.
  String get pageCountLine {
    var page = pageSummary.trim();
    if (page.isEmpty) {
      final fromChildren = <String>[
        for (final child in children)
          if (child.page.trim().isNotEmpty) child.page.trim(),
      ];
      if (fromChildren.isNotEmpty) {
        page = fromChildren.toSet().join(',');
      }
    }
    final pagePart = page.isEmpty ? '' : 'p.$page';
    final countPart = totalCount > 0 ? '$totalCount문항' : '';
    if (pagePart.isEmpty && countPart.isEmpty) return '';
    if (pagePart.isEmpty) return countPart;
    if (countPart.isEmpty) return pagePart;
    return '$pagePart · $countPart';
  }

  /// 목록을 불러온 시각. 수행 중 경과시간 표시에 사용.
  final DateTime fetchedAt = DateTime.now();

  /// 학습앱 홈 카드 `시도 N`과 동일.
  /// 대기(1)·확인(4)은 끝난 검사 횟수, 수행(2)·제출(3)은 다음 차수(+1).
  int get performanceAttemptIndex {
    final checks = checkCount < 0 ? 0 : checkCount;
    if (phase == 2 || phase == 3) {
      return checks + 1 < 1 ? 1 : checks + 1;
    }
    return checks < 1 ? 1 : checks;
  }

  bool get running => phase == 2 && runStart != null;

  /// 지금 시점 기준 사이클 경과(초).
  int liveCycleElapsed() {
    if (!running) return cycleElapsed;
    final extra = DateTime.now().difference(fetchedAt).inSeconds;
    return cycleElapsed + (extra > 0 ? extra : 0);
  }

  /// 누적 + 현재 사이클 수행시간(초). [isRunning]은 세션 러닝 여부.
  int liveTotalElapsedSec({required bool isRunning}) {
    final acc = accumulated < 0 ? 0 : accumulated;
    final cycle =
        isRunning ? liveCycleElapsed() : (cycleElapsed < 0 ? 0 : cycleElapsed);
    return acc + cycle;
  }

  static HomeworkGroup fromRow(Map<String, dynamic> row,
      {bool homeworkOnly = false}) {
    List<HomeworkChild> children = const [];
    final rawChildren = row['children'];
    if (rawChildren is List) {
      children = rawChildren
          .whereType<Map<String, dynamic>>()
          .map(HomeworkChild.fromRow)
          .toList(growable: false);
    }
    final listKind = HomeworkListKind.parse(
      row['list_kind'] ?? row['listKind'],
      homeworkOnlyFallback: homeworkOnly,
    );
    final type = (row['type'] as String?) ?? '';
    final explicitDigital = row['digital_solvable'] ?? row['digitalSolvable'];
    final digitalSolvable = explicitDigital is bool
        ? explicitDigital
        : explicitDigital is num
            ? explicitDigital != 0
            : explicitDigital is String
                ? const {'true', 't', '1', 'yes'}
                    .contains(explicitDigital.trim().toLowerCase())
                : type.trim() != '출력물' && type.trim() != '프린트';
    final dueDateRaw = row['due_date'] ?? row['dueDate'];
    return HomeworkGroup(
      groupId: row['group_id'] as String,
      title: (row['group_title'] as String?) ?? '',
      orderIndex: (row['order_index'] as num?)?.toInt() ?? 0,
      phase: (row['phase'] as num?)?.toInt() ?? 1,
      accumulated: (row['accumulated'] as num?)?.toInt() ?? 0,
      cycleElapsed: (row['cycle_elapsed'] as num?)?.toInt() ?? 0,
      checkCount: (row['check_count'] as num?)?.toInt() ?? 0,
      totalCount: (row['total_count'] as num?)?.toInt() ?? 0,
      color: (row['color'] as num?)?.toInt() ?? 0,
      pageSummary: (row['page_summary'] as String?) ?? '',
      runStart: row['run_start'] != null
          ? DateTime.tryParse(row['run_start'] as String)
          : null,
      content: (row['content'] as String?) ?? '',
      type: type,
      timeLimitMinutes: (row['time_limit_minutes'] as num?)?.toInt(),
      recommendedMinutes: (row['recommended_minutes'] as num?)?.toInt(),
      waitTitle: (row['m5_wait_title'] as String?) ?? '',
      children: children,
      bookId: (row['book_id'] as String?)?.trim() ?? '',
      gradeLabel: (row['grade_label'] as String?)?.trim() ?? '',
      isHomeworkOnly: homeworkOnly,
      listKind: listKind,
      assignmentOrigin: HomeworkAssignmentOrigin.parse(
        row['assignment_origin'] ?? row['assignmentOrigin'],
        listKind: listKind,
      ),
      dueDate: dueDateRaw == null
          ? null
          : DateTime.tryParse('$dueDateRaw')?.toLocal(),
      digitalSolvable: digitalSolvable,
      inspectionStatus: '${row['inspection_status'] ?? ''}'.trim(),
      originalDueDate:
          DateTime.tryParse('${row['original_due_at'] ?? ''}')?.toLocal(),
      absenceCarryover: row['absence_carryover'] == true,
      deferCount: (row['defer_count'] as num?)?.toInt() ?? 0,
      lastInspectionOutcome: '${row['last_outcome'] ?? ''}'.trim(),
      isAdditionalAfterSnapshot: row['is_additional_after_snapshot'] == true ||
          row['isAdditionalAfterSnapshot'] == true,
    );
  }
}

class HomeworkChild {
  const HomeworkChild({
    required this.itemId,
    required this.title,
    required this.page,
    required this.count,
    required this.memo,
    required this.phase,
  });

  final String itemId;
  final String title;
  final String page;
  final String count;
  final String memo;
  final int phase;

  static HomeworkChild fromRow(Map<String, dynamic> row) {
    return HomeworkChild(
      itemId: (row['item_id'] as String?)?.trim() ?? '',
      title: (row['title'] as String?) ?? '',
      page: (row['page'] as String?) ?? '',
      count: '${row['count'] ?? ''}',
      memo: (row['memo'] as String?) ?? '',
      phase: (row['phase'] as num?)?.toInt() ?? 1,
    );
  }
}

/// 과제로 배정된 개별 문항 (마이그레이션 교재 과제에만 존재).
class HomeworkProblem {
  const HomeworkProblem({
    required this.problemId,
    required this.itemId,
    required this.itemTitle,
    required this.cropId,
    required this.bookId,
    required this.gradeLabel,
    required this.problemNumber,
    required this.rawPage,
    required this.displayPage,
    required this.sourceStage,
    required this.passed,
    required this.attemptCount,
    this.lastResult,
    this.lastAnswer,
    this.lastScoredBy,
    this.lastGradedResult,
    this.lastGradedAnswer,
    this.lastGradedScoredBy,
    this.gradedAttemptCount,
    this.roundNo = 0,
    this.roundAttemptCount = 0,
  });

  final String problemId;
  final String itemId;
  final String itemTitle;
  final String cropId;
  final String bookId;
  final String gradeLabel;
  final String problemNumber;
  final int? rawPage;
  final int? displayPage;
  final String sourceStage;
  final bool passed;

  /// 이 배정에서의 누적 시도 수.
  final int attemptCount;

  /// 마지막 시도 결과 (correct | wrong | skipped ...). 안 풀었으면 null.
  final String? lastResult;

  /// 이 배정에서 마지막으로 낸 답. 안 풀었으면 null.
  final String? lastAnswer;

  /// 마지막 시도의 채점 주체 (auto | self). 안 풀었으면 null.
  final String? lastScoredBy;

  /// skipped 를 건너뛴 마지막 채점 결과. 없으면 null.
  final String? lastGradedResult;
  final String? lastGradedAnswer;
  final String? lastGradedScoredBy;

  /// skipped 가 아닌 시도 수. 서버가 아직 안 주면 null.
  final int? gradedAttemptCount;

  /// 이 문항을 몇 번째로 푸는 중인가 (배정 이전의 자유 풀이까지 포함).
  final int roundNo;

  /// 지금 회차 안에서의 시도 수.
  final int roundAttemptCount;

  static HomeworkProblem fromRow(Map<String, dynamic> row) {
    return HomeworkProblem(
      problemId: (row['homework_item_problem_id'] as String?) ?? '',
      itemId: (row['homework_item_id'] as String?) ?? '',
      itemTitle: (row['item_title'] as String?) ?? '',
      cropId: (row['crop_id'] as String?) ?? '',
      bookId: (row['book_id'] as String?) ?? '',
      gradeLabel: (row['grade_label'] as String?) ?? '',
      problemNumber: (row['problem_number'] as String?) ?? '',
      rawPage: (row['raw_page'] as num?)?.toInt(),
      displayPage: (row['display_page'] as num?)?.toInt(),
      sourceStage: (row['source_stage'] as String?) ?? 'original',
      passed: (row['passed'] as bool?) ?? false,
      attemptCount: (row['attempt_count'] as num?)?.toInt() ?? 0,
      lastResult: row['last_result'] as String?,
      lastAnswer: row['last_answer'] as String?,
      lastScoredBy: row['last_scored_by'] as String?,
      lastGradedResult: row['last_graded_result'] as String?,
      lastGradedAnswer: row['last_graded_answer'] as String?,
      lastGradedScoredBy: row['last_graded_scored_by'] as String?,
      gradedAttemptCount: (row['graded_attempt_count'] as num?)?.toInt(),
      roundNo: (row['round_no'] as num?)?.toInt() ?? 0,
      roundAttemptCount: (row['round_attempt_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 과제 그룹의 문항 통과 현황.
class HomeworkMastery {
  const HomeworkMastery({
    required this.problemBased,
    required this.total,
    required this.passed,
    required this.mastered,
  });

  final bool problemBased;
  final int total;
  final int passed;
  final bool mastered;

  int get remaining => (total - passed).clamp(0, total);

  static const HomeworkMastery none = HomeworkMastery(
    problemBased: false,
    total: 0,
    passed: 0,
    mastered: false,
  );

  static HomeworkMastery fromMap(Map<String, dynamic> row) {
    return HomeworkMastery(
      problemBased: (row['problem_based'] as bool?) ?? false,
      total: (row['total'] as num?)?.toInt() ?? 0,
      passed: (row['passed'] as num?)?.toInt() ?? 0,
      mastered: (row['mastered'] as bool?) ?? false,
    );
  }
}

class StudentInfo {
  const StudentInfo({
    required this.name,
    required this.school,
    required this.grade,
    required this.startHour,
    required this.startMinute,
    required this.duration,
    this.avatarKind,
    this.avatarUrl,
    this.avatarEmoji,
    this.avatarMonogramStyle,
    this.nickname,
  });

  final String name;
  final String school;
  final int? grade;
  final int? startHour;
  final int? startMinute;
  final int? duration;
  final String? avatarKind;
  final String? avatarUrl;
  final String? avatarEmoji;
  final int? avatarMonogramStyle;

  /// 학생앱 표시용. 비어 있으면 [name](실명)을 쓴다.
  final String? nickname;

  String get displayName {
    final nick = (nickname ?? '').trim();
    return nick.isNotEmpty ? nick : name.trim();
  }
}

class AcademyBranding {
  const AcademyBranding({
    required this.name,
    this.logoUrl = '',
  });

  final String name;
  final String logoUrl;
}

class QuickLoginStudent {
  const QuickLoginStudent({
    required this.id,
    required this.name,
    required this.school,
    required this.grade,
    required this.startHour,
    required this.startMinute,
  });

  final String id;
  final String name;
  final String school;
  final int? grade;
  final int? startHour;
  final int? startMinute;

  static QuickLoginStudent fromRow(Map<String, dynamic> row) {
    return QuickLoginStudent(
      id: '${row['student_id'] ?? ''}',
      name: '${row['name'] ?? ''}',
      school: '${row['school'] ?? ''}',
      grade: (row['grade'] as num?)?.toInt(),
      startHour: (row['start_hour'] as num?)?.toInt(),
      startMinute: (row['start_minute'] as num?)?.toInt(),
    );
  }
}

class QuickLoginRoster {
  const QuickLoginRoster({
    required this.students,
    required this.networkProtected,
  });

  final List<QuickLoginStudent> students;
  final bool networkProtected;
}

class TodayAttendance {
  const TodayAttendance({
    this.arrival,
    this.departure,
    this.classDateTime,
    this.classEndTime,
    this.plannedDepartureAt,
    this.earlyLeaveReason,
  });

  final DateTime? arrival;
  final DateTime? departure;
  final DateTime? classDateTime;

  /// 시간표 기준 수업 종료.
  final DateTime? classEndTime;

  /// 오늘 예정 귀가(실하원 `departure`와 별개).
  final DateTime? plannedDepartureAt;
  final String? earlyLeaveReason;
}

/// 학생앱 — 다음 회차 수업 일정.
class StudentNextClass {
  const StudentNextClass({
    required this.classDateTime,
    this.classEndTime,
    this.className,
  });

  final DateTime classDateTime;
  final DateTime? classEndTime;
  final String? className;
}

/// 주간 수업시간(하원−등원) 막대 + 90일 평균.
class StudentClassDurationWeek {
  const StudentClassDurationWeek({
    required this.days,
    required this.yMaxMinutes,
    required this.sampleCount,
    this.averageMinutes,
    this.weekStart,
    this.weekEnd,
  });

  final List<StudentClassDurationDay> days;
  final int? averageMinutes;
  final int sampleCount;
  final int yMaxMinutes;
  final DateTime? weekStart;
  final DateTime? weekEnd;

  static StudentClassDurationWeek fromJson(Map<String, dynamic> json) {
    final rawDays = json['days'];
    final days = <StudentClassDurationDay>[];
    if (rawDays is List) {
      for (final item in rawDays) {
        if (item is! Map) continue;
        days.add(
          StudentClassDurationDay.fromJson(Map<String, dynamic>.from(item)),
        );
      }
    }
    DateTime? parseDate(Object? value) {
      if (value == null) return null;
      final text = value.toString();
      // date-only → local midnight
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
        final parts = text.split('-');
        return DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
      }
      return DateTime.tryParse(text)?.toLocal();
    }

    return StudentClassDurationWeek(
      days: days,
      averageMinutes: (json['average_minutes'] as num?)?.toInt(),
      sampleCount: (json['sample_count'] as num?)?.toInt() ?? 0,
      yMaxMinutes: (json['y_max_minutes'] as num?)?.toInt() ?? 240,
      weekStart: parseDate(json['week_start']),
      weekEnd: parseDate(json['week_end']),
    );
  }
}

class StudentClassDurationDay {
  const StudentClassDurationDay({
    required this.weekday,
    required this.minutes,
    this.date,
  });

  final String weekday;
  final int minutes;
  final DateTime? date;

  static StudentClassDurationDay fromJson(Map<String, dynamic> json) {
    DateTime? date;
    final raw = json['date'];
    if (raw != null) {
      final text = raw.toString();
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
        final parts = text.split('-');
        date = DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
      } else {
        date = DateTime.tryParse(text)?.toLocal();
      }
    }
    return StudentClassDurationDay(
      weekday: '${json['weekday'] ?? ''}',
      minutes: (json['minutes'] as num?)?.toInt() ?? 0,
      date: date,
    );
  }
}

/// 최근 출결 1회 — 프로필 펼침 그래프용.
class RecentAttendanceSession {
  const RecentAttendanceSession({
    required this.classDateTime,
    this.arrival,
    this.departure,
    this.className = '',
    this.deltaMinutes,
    this.latenessThreshold = 10,
  });

  final DateTime classDateTime;
  final DateTime? arrival;
  final DateTime? departure;
  final String className;

  /// 등원 − 수업시작(분). 음수=일찍, 양수=늦음. 등원 없으면 null.
  final int? deltaMinutes;
  final int latenessThreshold;

  bool get hasArrival => arrival != null;

  bool get isLate {
    final d = deltaMinutes;
    if (d == null) return false;
    return d > latenessThreshold;
  }

  static RecentAttendanceSession? fromRow(Map<String, dynamic> row) {
    final classRaw = row['class_date_time'];
    if (classRaw == null) return null;
    final classDt = DateTime.tryParse(classRaw as String)?.toLocal();
    if (classDt == null) return null;
    DateTime? parse(String key) => row[key] != null
        ? DateTime.tryParse(row[key] as String)?.toLocal()
        : null;
    return RecentAttendanceSession(
      classDateTime: classDt,
      arrival: parse('arrival_time'),
      departure: parse('departure_time'),
      className: (row['class_name'] as String?)?.trim() ?? '',
      deltaMinutes: (row['delta_minutes'] as num?)?.toInt(),
      latenessThreshold: (row['lateness_threshold'] as num?)?.toInt() ?? 10,
    );
  }
}

/// 학생이 직접 입력하는 현재 자기평가와 고3 수능 희망 수준.
class StudentDesiredLevelInfo {
  const StudentDesiredLevelInfo({
    this.selfAssessedUpperPercent,
    this.levelCode,
    this.upperPercent,
    this.displayName,
    this.options = const <StudentLevelOption>[],
  });

  final double? selfAssessedUpperPercent;
  final int? levelCode;
  final double? upperPercent;
  final String? displayName;
  final List<StudentLevelOption> options;

  String get goalValueLabel =>
      StudentLevelOption.formatTopPercent(upperPercent);

  static StudentDesiredLevelInfo fromRow(Map<String, dynamic>? row) {
    if (row == null) {
      return const StudentDesiredLevelInfo();
    }
    dynamic optionsRaw = row['options'];
    if (optionsRaw is String && optionsRaw.trim().isNotEmpty) {
      try {
        optionsRaw = jsonDecode(optionsRaw);
      } catch (_) {
        optionsRaw = null;
      }
    }
    final options = <StudentLevelOption>[];
    if (optionsRaw is List) {
      for (final item in optionsRaw) {
        if (item is! Map) continue;
        final opt = StudentLevelOption.fromRow(Map<String, dynamic>.from(item));
        if (opt != null) options.add(opt);
      }
    }
    options.sort((a, b) => a.levelCode.compareTo(b.levelCode));
    final top = (row['desired_top_percent'] as num?)?.toDouble() ??
        (row['upper_percent'] as num?)?.toDouble();
    return StudentDesiredLevelInfo(
      selfAssessedUpperPercent:
          (row['self_assessed_top_percent'] as num?)?.toDouble(),
      levelCode: (row['desired_level_code'] as num?)?.toInt(),
      upperPercent: top,
      displayName: (row['display_name'] as String?)?.trim(),
      options: options,
    );
  }
}

class StudentLevelOption {
  const StudentLevelOption({
    required this.levelCode,
    required this.displayName,
    required this.upperPercent,
  });

  final int levelCode;
  final String displayName;
  final double upperPercent;

  String get topPercentLabel => formatTopPercent(upperPercent);

  static String formatTopPercent(num? percent) {
    if (percent == null) return '상위 —%';
    final v = percent.toDouble();
    if (v == v.roundToDouble()) return '상위 ${v.round()}%';
    return '상위 ${v.toStringAsFixed(1)}%';
  }

  static StudentLevelOption? fromRow(Map<String, dynamic> row) {
    final code = (row['level_code'] as num?)?.toInt();
    final percent = (row['upper_percent'] as num?)?.toDouble();
    if (code == null || percent == null || code < 1 || code > 9) return null;
    final name = (row['display_name'] as String?)?.trim();
    return StudentLevelOption(
      levelCode: code,
      displayName: (name == null || name.isEmpty) ? '${code}등급' : name,
      upperPercent: percent,
    );
  }
}

/// 출결(출석) 점수 — 학습앱 스탯과 동일 규칙(서버 계산).
class AttendanceScoreInfo {
  const AttendanceScoreInfo({
    required this.score100,
    required this.rank,
    required this.cohortSize,
    required this.topPercent,
    this.insufficientEvidence = false,
  });

  final double score100;
  final int rank;
  final int cohortSize;
  final double topPercent;
  final bool insufficientEvidence;

  int get scoreRounded => score100.round().clamp(0, 100);

  String get subtitle {
    if (cohortSize <= 0 || rank <= 0) {
      return '학원 순위 데이터가 부족해요';
    }
    return '상위 ${topPercent.toStringAsFixed(1)}% · $rank등';
  }

  static AttendanceScoreInfo? fromRow(Map<String, dynamic>? row) {
    if (row == null) return null;
    final score = (row['score100'] as num?)?.toDouble();
    final rank = (row['rank'] as num?)?.toInt();
    final cohort = (row['cohort_size'] as num?)?.toInt();
    final top = (row['top_percent'] as num?)?.toDouble();
    if (score == null || rank == null || cohort == null || top == null) {
      return null;
    }
    return AttendanceScoreInfo(
      score100: score,
      rank: rank,
      cohortSize: cohort,
      topPercent: top,
      insufficientEvidence: row['insufficient_evidence'] == true,
    );
  }
}

/// 누적 포인트 — 학습앱 포인트 카드와 동일 기준(lifetime_earned + 순위).
class PointSummaryInfo {
  const PointSummaryInfo({
    required this.lifetimeEarned,
    required this.balance,
    required this.lifetimeSpent,
    required this.entryCount,
    required this.rank,
    required this.cohortSize,
    required this.topPercent,
    this.lastEventAt,
  });

  final int lifetimeEarned;
  final int balance;
  final int lifetimeSpent;
  final int entryCount;
  final int rank;
  final int cohortSize;
  final double topPercent;
  final DateTime? lastEventAt;

  /// 천 단위 구분된 누적 획득 표기.
  String get lifetimeLabel {
    final raw = '$lifetimeEarned';
    final buf = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final fromEnd = raw.length - i;
      buf.write(raw[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) buf.write(',');
    }
    return buf.toString();
  }

  String get subtitle {
    if (entryCount <= 0) {
      return '출석·과제를 하면 포인트가 쌓여요';
    }
    if (cohortSize <= 0 || rank <= 0) {
      return '학원 순위 데이터가 부족해요';
    }
    return '상위 ${topPercent.toStringAsFixed(1)}% · $rank등';
  }

  static PointSummaryInfo? fromRow(Map<String, dynamic>? row) {
    if (row == null) return null;
    int asInt(dynamic v) => (v as num?)?.toInt() ?? 0;
    final lastRaw = row['last_event_at']?.toString();
    return PointSummaryInfo(
      lifetimeEarned: asInt(row['lifetime_earned']),
      balance: asInt(row['balance']),
      lifetimeSpent: asInt(row['lifetime_spent']),
      entryCount: asInt(row['entry_count']),
      rank: asInt(row['rank']),
      cohortSize: asInt(row['cohort_size']),
      topPercent: (row['top_percent'] as num?)?.toDouble() ?? 0,
      lastEventAt: (lastRaw == null || lastRaw.isEmpty)
          ? null
          : DateTime.tryParse(lastRaw)?.toLocal(),
    );
  }
}

/// 포인트 카드 펼침용 최근 적립 1건.
///
/// 과제는 그룹 단위로 합산되고, [children]에 하위과제 내역이 들어간다.
class PointHistoryEntry {
  const PointHistoryEntry({
    required this.id,
    required this.createdAt,
    required this.kind,
    required this.delta,
    required this.title,
    required this.detail,
    this.groupId,
    this.children = const [],
  });

  final String id;
  final DateTime createdAt;
  final String kind;
  final int delta;
  final String title;
  final String detail;
  final String? groupId;
  final List<PointHistoryEntry> children;

  String get deltaLabel => '+$delta P';

  bool get canExpand => kind == 'earn_homework' && children.length > 1;

  static PointHistoryEntry? fromRow(Map<String, dynamic> row) {
    final id = row['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final createdRaw = row['created_at'];
    DateTime? createdAt;
    if (createdRaw is DateTime) {
      createdAt = createdRaw.toLocal();
    } else {
      final raw = createdRaw?.toString();
      if (raw == null || raw.isEmpty) return null;
      createdAt = DateTime.tryParse(raw)?.toLocal();
    }
    if (createdAt == null) return null;
    final rawChildren = row['children'];
    final children = <PointHistoryEntry>[];
    final childList = rawChildren is String
        ? (rawChildren.isEmpty ? const [] : jsonDecode(rawChildren))
        : rawChildren;
    if (childList is List) {
      for (final child in childList) {
        if (child is! Map) continue;
        final parsed = PointHistoryEntry.fromRow(
          Map<String, dynamic>.from(child),
        );
        if (parsed != null) children.add(parsed);
      }
    }
    final groupId = row['group_id']?.toString().trim();
    return PointHistoryEntry(
      id: id,
      createdAt: createdAt,
      kind: row['kind']?.toString() ?? '',
      delta: (row['delta'] as num?)?.toInt() ?? 0,
      title: (row['title'] as String?)?.trim() ?? '',
      detail: (row['detail'] as String?)?.trim() ?? '',
      groupId: (groupId == null || groupId.isEmpty) ? null : groupId,
      children: children,
    );
  }
}

/// 과제 점수 — 학습앱 스탯과 동일 규칙(서버 `_homework_score_all_v2`).
class HomeworkScoreInfo {
  const HomeworkScoreInfo({
    required this.score100,
    required this.hasScore,
    required this.rank,
    required this.cohortSize,
    required this.topPercent,
    required this.evaluatedCount,
    required this.completedCount,
    required this.pendingCount,
    this.insufficientEvidence = false,
  });

  final double? score100;
  final bool hasScore;
  final int rank;
  final int cohortSize;
  final double topPercent;
  final int evaluatedCount;
  final int completedCount;
  final int pendingCount;
  final bool insufficientEvidence;

  String get subtitle {
    if (!hasScore) {
      if (pendingCount > 0) {
        return '기한이 지나면 점수가 생겨요';
      }
      return '과제를 처리하면 점수가 생겨요';
    }
    if (cohortSize <= 0 || rank <= 0) {
      return '학원 순위 데이터가 부족해요';
    }
    return '상위 ${topPercent.toStringAsFixed(1)}% · $rank등';
  }

  static HomeworkScoreInfo? fromRow(Map<String, dynamic>? row) {
    if (row == null) return null;
    int asInt(dynamic v) => (v as num?)?.toInt() ?? 0;
    final hasScore = row['has_score'] == true;
    final raw = (row['score100'] as num?)?.toDouble();
    return HomeworkScoreInfo(
      score100: hasScore ? raw : null,
      hasScore: hasScore && raw != null,
      rank: asInt(row['rank']),
      cohortSize: asInt(row['cohort_size']),
      topPercent: (row['top_percent'] as num?)?.toDouble() ?? 0,
      evaluatedCount: asInt(row['evaluated_count']),
      completedCount: asInt(row['completed_count']),
      pendingCount: asInt(row['pending_count']),
      insufficientEvidence: row['insufficient_evidence'] == true,
    );
  }
}

/// 총점 — 출석/과제 점수의 가중 평균(서버 계산, 학습앱 스탯과 동일 규칙).
///
/// 과제 근거가 없으면 [hasTotal]이 false이고 [score100]은 null이다.
/// 이 경우 점수를 숨기고 안내 문구를 보여준다.
class TotalScoreInfo {
  const TotalScoreInfo({
    required this.score100,
    required this.hasTotal,
    required this.attendanceScore100,
    required this.homeworkScore100,
    required this.attendanceWeight,
    required this.homeworkWeight,
    required this.attendanceEvidence,
    required this.homeworkEvidence,
    required this.homeworkEventCount,
    required this.rank,
    required this.cohortSize,
    required this.topPercent,
  });

  final double? score100;
  final bool hasTotal;
  final double attendanceScore100;
  final double homeworkScore100;
  final double attendanceWeight;
  final double homeworkWeight;
  final bool attendanceEvidence;
  final bool homeworkEvidence;
  final int homeworkEventCount;
  final int rank;
  final int cohortSize;
  final double topPercent;

  /// 총점 카드 아래에 표시할 안내/부가 문구.
  String get subtitle {
    if (!hasTotal) {
      if (!homeworkEvidence) return '과제를 처리하면 총점이 생겨요';
      if (!attendanceEvidence) return '출석 기록이 쌓이면 총점이 생겨요';
      return '총점을 만들 기록이 아직 부족해요';
    }
    if (cohortSize <= 0 || rank <= 0) {
      return '출석 ${_pct(attendanceWeight)} + 과제 ${_pct(homeworkWeight)} 반영';
    }
    return '상위 ${topPercent.toStringAsFixed(1)}% · $rank등';
  }

  static String _pct(double weight) => '${(weight * 100).toStringAsFixed(0)}%';

  static TotalScoreInfo? fromRow(Map<String, dynamic>? row) {
    if (row == null) return null;
    double asDouble(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
    int asInt(dynamic v) => (v as num?)?.toInt() ?? 0;
    final hasTotal = row['has_total'] == true;
    final raw = (row['total_score100'] as num?)?.toDouble();
    return TotalScoreInfo(
      score100: hasTotal ? raw : null,
      hasTotal: hasTotal && raw != null,
      attendanceScore100: asDouble(row['attendance_score100']),
      homeworkScore100: asDouble(row['homework_score100']),
      attendanceWeight: asDouble(row['attendance_weight']),
      homeworkWeight: asDouble(row['homework_weight']),
      attendanceEvidence: row['attendance_evidence'] == true,
      homeworkEvidence: row['homework_evidence'] == true,
      homeworkEventCount: asInt(row['homework_event_count']),
      rank: asInt(row['rank']),
      cohortSize: asInt(row['cohort_size']),
      topPercent: asDouble(row['top_percent']),
    );
  }
}

/// 오늘 완료된 과제 그룹 (진행률 상세 카드용, completed_at 기준).
/// 열린 등원 세션의 목표 제시(계획 저장) 스냅샷.
class StudentPlanGoalSnapshot {
  const StudentPlanGoalSnapshot({
    this.presentedAt,
    this.itemIds = const <String>{},
    this.planMinutes,
  });

  final DateTime? presentedAt;
  final Set<String> itemIds;
  final int? planMinutes;

  bool get isPresented => presentedAt != null;
}

/// 수업 계획 진행률.
///
/// 분모: 계획 저장 스냅샷의 남은 권장분(없으면 현재 권장 합).
/// 분자: 권장×문항완료율 (과제 전체 완료 전에도 부분 반영).
class StudentTodayPlanProgress {
  const StudentTodayPlanProgress({
    this.planMinutes = 0,
    this.completedRecommendedMinutes = 0,
    this.planGroupCount,
    this.completedGroupCount,
  });

  final int planMinutes;
  final int completedRecommendedMinutes;

  /// null이면 구버전 RPC(개수 컬럼 없음).
  final int? planGroupCount;
  final int? completedGroupCount;

  int get percent {
    if (planMinutes <= 0) return 0;
    return ((completedRecommendedMinutes * 100) / planMinutes)
        .round()
        .clamp(0, 100);
  }

  bool get hasGroupCounts =>
      planGroupCount != null && completedGroupCount != null;

  /// 예: `5개 중 2개 완료`
  String get groupCompletionLabel {
    final total = planGroupCount ?? 0;
    final safeTotal = total < 0 ? 0 : total;
    final done = (completedGroupCount ?? 0).clamp(0, safeTotal);
    return '$safeTotal개 중 $done개 완료';
  }

  static StudentTodayPlanProgress fromRow(Map<String, dynamic> row) {
    return StudentTodayPlanProgress(
      planMinutes: (row['plan_minutes'] as num?)?.toInt() ?? 0,
      completedRecommendedMinutes:
          (row['completed_recommended_minutes'] as num?)?.toInt() ?? 0,
      planGroupCount: row.containsKey('plan_group_count')
          ? (row['plan_group_count'] as num?)?.toInt() ?? 0
          : null,
      completedGroupCount: row.containsKey('completed_group_count')
          ? (row['completed_group_count'] as num?)?.toInt() ?? 0
          : null,
    );
  }
}

/// 오늘 수업 생산성: 순수 수업시간과 오늘 새로 통과한 문항수.
class StudentTodayProductivity {
  const StudentTodayProductivity({
    this.productiveSeconds = 0,
    this.completedProblemCount = 0,
  });

  final int productiveSeconds;
  final int completedProblemCount;

  static StudentTodayProductivity fromRow(Map<String, dynamic> row) {
    final seconds = (row['productive_seconds'] as num?)?.toInt() ?? 0;
    final count = (row['completed_problem_count'] as num?)?.toInt() ?? 0;
    return StudentTodayProductivity(
      productiveSeconds: seconds < 0 ? 0 : seconds,
      completedProblemCount: count < 0 ? 0 : count,
    );
  }
}

class StudentDailyPerformance {
  const StudentDailyPerformance({
    required this.date,
    this.planMinutes = 0,
    this.completedRecommendedMinutes = 0,
    this.performanceRate = 0,
    this.sessionCount = 0,
    this.isLive = false,
  });

  final DateTime date;
  final int planMinutes;
  final int completedRecommendedMinutes;
  final double performanceRate;
  final int sessionCount;
  final bool isLive;

  int get percent => (performanceRate * 100).round().clamp(0, 100);

  static StudentDailyPerformance? fromRow(Map<String, dynamic> row) {
    final date = DateTime.tryParse('${row['local_date'] ?? ''}');
    if (date == null) return null;
    final rate = (row['performance_rate'] as num?)?.toDouble() ?? 0;
    return StudentDailyPerformance(
      date: date,
      planMinutes: (row['plan_minutes'] as num?)?.toInt() ?? 0,
      completedRecommendedMinutes:
          (row['completed_recommended_minutes'] as num?)?.toInt() ?? 0,
      performanceRate: rate.clamp(0.0, 1.0),
      sessionCount: (row['session_count'] as num?)?.toInt() ?? 0,
      isLive: row['is_live'] == true,
    );
  }
}

class TodayCompletedHomework {
  const TodayCompletedHomework({
    required this.groupId,
    required this.title,
    required this.pageSummary,
    required this.totalCount,
    required this.accumulatedSec,
    required this.bookId,
    required this.gradeLabel,
    required this.type,
    required this.content,
    this.finishedAt,
  });

  final String groupId;
  final String title;
  final String pageSummary;
  final int totalCount;
  final int accumulatedSec;
  final String bookId;
  final String gradeLabel;
  final String type;
  final String content;
  final DateTime? finishedAt;

  bool get isPrintSource {
    final t = type.trim();
    return t == '출력물' || t == '프린트';
  }

  String get sourceLabel {
    final fromContent = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)')
        .firstMatch(content)
        ?.group(1)
        ?.trim();
    if (fromContent != null && fromContent.isNotEmpty) return fromContent;
    final t = type.trim();
    return t.isNotEmpty ? t : '';
  }

  String get courseLabel {
    final fromContent = RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)')
        .firstMatch(content)
        ?.group(1)
        ?.trim();
    if (fromContent != null && fromContent.isNotEmpty) return fromContent;
    return gradeLabel.trim();
  }

  /// `p.10-12 · 12문항`
  String get pageCountLine {
    final page = pageSummary.trim();
    final pagePart = page.isEmpty ? '' : 'p.$page';
    final countPart = totalCount > 0 ? '$totalCount문항' : '';
    if (pagePart.isEmpty && countPart.isEmpty) return '-';
    if (pagePart.isEmpty) return countPart;
    if (countPart.isEmpty) return pagePart;
    return '$pagePart · $countPart';
  }

  /// `1시간 23분` / `45분` / `-`
  String get durationLine {
    final sec = accumulatedSec < 0 ? 0 : accumulatedSec;
    if (sec <= 0) return '-';
    final totalMin = (sec / 60).floor();
    final hours = totalMin ~/ 60;
    final minutes = totalMin % 60;
    if (hours > 0 && minutes > 0) return '$hours시간 $minutes분';
    if (hours > 0) return '$hours시간';
    return '$minutes분';
  }

  static TodayCompletedHomework fromRow(Map<String, dynamic> row) {
    return TodayCompletedHomework(
      groupId: '${row['group_id'] ?? ''}',
      title: (row['group_title'] as String?)?.trim() ?? '',
      pageSummary: (row['page_summary'] as String?) ?? '',
      totalCount: (row['total_count'] as num?)?.toInt() ?? 0,
      accumulatedSec: (row['accumulated_sec'] as num?)?.toInt() ?? 0,
      bookId: (row['book_id'] as String?)?.trim() ?? '',
      gradeLabel: (row['grade_label'] as String?)?.trim() ?? '',
      type: (row['type'] as String?)?.trim() ?? '',
      content: (row['content'] as String?) ?? '',
      finishedAt: row['finished_at'] != null
          ? DateTime.tryParse(row['finished_at'] as String)
          : null,
    );
  }
}

/// Supabase 직접 통신 API. 모든 호출은 로그인된 학생 세션 기준(RPC가 본인 검증).
class StudentApi {
  StudentApi._();
  static final StudentApi instance = StudentApi._();

  SupabaseClient get _client => Supabase.instance.client;

  bool get isLoggedIn => _client.auth.currentSession != null;

  // ---------------------------------------------------------------- 인증

  /// 학생 아이디 + 비밀번호 로그인.
  Future<void> signIn({required String username, required String password}) {
    final email = '${username.trim().toLowerCase()}@$kStudentEmailDomain';
    return _client.auth
        .signInWithPassword(email: email, password: password)
        .then((_) {});
  }

  /// 가입코드 기반 회원가입 (student_signup Edge Function 호출) 후 자동 로그인.
  Future<void> signUp({
    required String code,
    required String username,
    required String password,
  }) async {
    final uri =
        Uri.parse('${resolveSupabaseUrl()}/functions/v1/student_signup');
    final res = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${resolveSupabaseAnonKey()}',
        'apikey': resolveSupabaseAnonKey(),
      },
      body: jsonEncode({
        'code': code.trim(),
        'username': username.trim().toLowerCase(),
        'password': password,
      }),
    );
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['ok'] != true) {
      throw StudentApiException(_signupErrorMessage('${body['error']}'));
    }
    await signIn(username: username, password: password);
  }

  Future<void> signOut() async {
    try {
      await presenceOffline();
    } catch (_) {}
    await _client.auth.signOut();
  }

  /// 학생앱 온라인 heartbeat. 서버가 등원중이면 academy, 아니면 home 으로 분류.
  /// [iosInstallId] 가 있고 다른 iPad 가 클레임했으면 [iosDeviceReplaced] = true.
  Future<({String? locationKind, bool iosDeviceReplaced})> presenceHeartbeat({
    String? iosInstallId,
  }) async {
    final raw = await _client.rpc(
      'student_app_heartbeat',
      params: {
        'p_ios_install_id': iosInstallId,
      },
    );
    if (raw is! Map) {
      return (locationKind: null, iosDeviceReplaced: false);
    }
    final map = Map<String, dynamic>.from(raw);
    if (map['ok'] == false && '${map['error']}' == 'ios_device_replaced') {
      return (locationKind: null, iosDeviceReplaced: true);
    }
    final kind = '${map['location_kind'] ?? ''}'.trim();
    return (
      locationKind: kind.isEmpty ? null : kind,
      iosDeviceReplaced: false,
    );
  }

  /// iOS 설치를 활성 기기로 클레임 (다른 iPad 세션을 밀어냄).
  Future<void> claimIosDevice(String iosInstallId) async {
    final id = iosInstallId.trim();
    if (id.isEmpty) return;
    await _client.rpc(
      'student_app_claim_ios_device',
      params: {'p_ios_install_id': id},
    );
  }

  Future<void> presenceOffline() => _client.rpc('student_app_presence_offline');

  Future<Map<String, dynamic>> _quickLoginRequest(
    Map<String, dynamic> body,
  ) async {
    final uri =
        Uri.parse('${resolveSupabaseUrl()}/functions/v1/student_pin_login');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${resolveSupabaseAnonKey()}',
        'apikey': resolveSupabaseAnonKey(),
      },
      body: jsonEncode(body),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw StudentApiException('빠른 로그인 서버 응답을 확인할 수 없어요.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<QuickLoginRoster> listQuickLoginStudents() async {
    final result = await _quickLoginRequest(const {'action': 'list'});
    if (result['ok'] != true) {
      throw StudentApiException(_quickLoginErrorMessage('${result['error']}'));
    }
    final students = (result['students'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((row) => QuickLoginStudent.fromRow(
              Map<String, dynamic>.from(row),
            ))
        .toList(growable: false);
    return QuickLoginRoster(
      students: students,
      networkProtected: result['network_protected'] == true,
    );
  }

  Future<void> signInWithPin({
    required String studentId,
    required String pin,
  }) async {
    final result = await _quickLoginRequest({
      'action': 'login',
      'student_id': studentId,
      'pin': pin,
    });
    if (result['ok'] != true) {
      throw StudentApiException(
          _quickLoginErrorMessage('${result['error']}', result: result));
    }
    final tokenHash = '${result['token_hash'] ?? ''}'.trim();
    if (tokenHash.isEmpty) {
      throw StudentApiException('로그인 세션을 만들지 못했어요.');
    }
    await _client.auth.verifyOTP(
      tokenHash: tokenHash,
      type: OtpType.magiclink,
    );
  }

  static String _quickLoginErrorMessage(
    String code, {
    Map<String, dynamic>? result,
  }) {
    switch (code) {
      case 'network_not_allowed':
        return '학원 Wi-Fi에 연결된 기기에서만 사용할 수 있어요.';
      case 'pin_invalid':
        return 'PIN이 맞지 않아요. ${result?['attempts_left'] ?? 0}번 더 입력할 수 있어요.';
      case 'locked':
        final seconds = (result?['locked_seconds'] as num?)?.toInt() ?? 300;
        return '입력 횟수를 초과했어요. ${((seconds + 59) ~/ 60)}분 뒤 다시 시도해 주세요.';
      case 'not_eligible':
        return '지금은 이 학생으로 빠른 로그인할 수 없어요.';
      default:
        return '빠른 로그인에 실패했어요. ($code)';
    }
  }

  static String _signupErrorMessage(String code) {
    switch (code) {
      case 'code_not_found':
        return '가입코드를 찾을 수 없어요. 다시 확인해 주세요.';
      case 'code_used':
        return '이미 사용된 가입코드예요.';
      case 'code_expired':
        return '만료된 가입코드예요. 선생님께 새로 발급받아 주세요.';
      case 'already_registered':
        return '이미 계정이 만들어진 학생이에요.';
      case 'username_taken':
        return '이미 사용 중인 아이디예요.';
      case 'invalid_username':
        return '아이디는 영문 소문자/숫자 3~20자로 만들어 주세요.';
      case 'weak_password':
        return '비밀번호는 6자 이상이어야 해요.';
      default:
        return '가입에 실패했어요. ($code)';
    }
  }

  // ---------------------------------------------------------------- 조회

  /// 로그인 전에도 표시 가능한 전용 학원 공개 브랜딩.
  Future<AcademyBranding> getPublicAcademyBranding() async {
    final rows =
        await _client.rpc('student_public_academy_branding') as List<dynamic>;
    if (rows.isEmpty) {
      return const AcademyBranding(name: '정현수학교습소');
    }
    final row = Map<String, dynamic>.from(rows.first as Map);
    final bucket = '${row['logo_bucket'] ?? ''}'.trim();
    final path = '${row['logo_path'] ?? ''}'.trim();
    var logoUrl = '${row['logo_url'] ?? ''}'.trim();
    if (bucket.isNotEmpty && path.isNotEmpty) {
      try {
        logoUrl =
            await _client.storage.from(bucket).createSignedUrl(path, 60 * 60);
      } catch (_) {
        // 이전 공개 URL이 있으면 그대로 사용한다.
      }
    }
    return AcademyBranding(
      name: '${row['academy_name'] ?? '정현수학교습소'}'.trim(),
      logoUrl: logoUrl,
    );
  }

  Future<StudentInfo?> getInfo() async {
    final rows = await _client.rpc('student_get_info') as List<dynamic>;
    if (rows.isEmpty) return null;
    final row = rows.first as Map<String, dynamic>;
    final nickRaw = (row['nickname'] as String?)?.trim() ?? '';
    final info = StudentInfo(
      name: (row['name'] as String?) ?? '',
      school: (row['school'] as String?) ?? '',
      grade: (row['grade'] as num?)?.toInt(),
      startHour: (row['start_hour'] as num?)?.toInt(),
      startMinute: (row['start_minute'] as num?)?.toInt(),
      duration: (row['duration'] as num?)?.toInt(),
      avatarKind: row['avatar_kind'] as String?,
      avatarUrl: row['avatar_url'] as String?,
      avatarEmoji: row['avatar_emoji'] as String?,
      avatarMonogramStyle: (row['avatar_monogram_style'] as num?)?.toInt(),
      nickname: nickRaw.isEmpty ? null : nickRaw,
    );
    StudentAvatarSession.instance.hydrateFromServer(
      kindRaw: info.avatarKind,
      url: info.avatarUrl,
      emojiValue: info.avatarEmoji,
      monogramStyle: info.avatarMonogramStyle,
    );
    return info;
  }

  Future<String> uploadAvatarPhoto(
    Uint8List bytes, {
    String contentType = 'image/jpeg',
  }) async {
    final id = await identity();
    if (id == null) {
      throw StateError('no student identity');
    }
    final ext = contentType.contains('png')
        ? 'png'
        : contentType.contains('webp')
            ? 'webp'
            : 'jpg';
    final path = '${id.academyId}/${id.studentId}/avatar.$ext';
    await _client.storage.from('student-avatars').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: contentType,
          ),
        );
    return _client.storage.from('student-avatars').getPublicUrl(path);
  }

  Future<void> setAvatar({
    required String kind,
    String? url,
    String? emoji,
    int? monogramStyle,
  }) async {
    await _client.rpc('student_set_avatar', params: {
      'p_kind': kind,
      'p_url': url,
      'p_emoji': emoji,
      'p_monogram_style': monogramStyle,
    });
  }

  /// 빈 문자열이면 닉네임 제거(실명 표시로 복귀).
  Future<void> setNickname(String? nickname) async {
    await _client.rpc('student_set_nickname', params: {
      'p_nickname': (nickname ?? '').trim(),
    });
  }

  /// Realtime 필터용 본인 academy/student.
  Future<({String academyId, String studentId})?> identity() async {
    final rows = await _client.rpc('student_app_identity') as List<dynamic>;
    if (rows.isEmpty) return null;
    final row = rows.first as Map<String, dynamic>;
    final academyId = (row['academy_id'] as String?)?.trim() ?? '';
    final studentId = (row['student_id'] as String?)?.trim() ?? '';
    if (academyId.isEmpty || studentId.isEmpty) return null;
    return (academyId: academyId, studentId: studentId);
  }

  /// 누적 포인트 + 학원 내 상위 퍼센트 (학습앱 포인트와 동일 기준).
  Future<PointSummaryInfo?> getPointSummary() async {
    final rows =
        await _client.rpc('student_get_point_summary_v1') as List<dynamic>;
    if (rows.isEmpty) return null;
    return PointSummaryInfo.fromRow(
      Map<String, dynamic>.from(rows.first as Map),
    );
  }

  /// 최근 적립 내역(과제·출석). 최신이 앞.
  Future<List<PointHistoryEntry>> listRecentPoints({int limit = 20}) async {
    try {
      final raw = await _client.rpc(
        'student_list_recent_points_v1',
        params: {'p_limit': limit},
      );
      final rows = raw is List ? raw : const <dynamic>[];
      return rows
          .whereType<Map>()
          .map((r) => PointHistoryEntry.fromRow(Map<String, dynamic>.from(r)))
          .whereType<PointHistoryEntry>()
          .toList(growable: false);
    } catch (e) {
      debugPrint('[points] listRecentPoints failed: $e');
      rethrow;
    }
  }

  /// 출결 점수 + 학원 내 상위 퍼센트.
  Future<AttendanceScoreInfo?> getAttendanceScore() async {
    final rows =
        await _client.rpc('student_get_attendance_score_v1') as List<dynamic>;
    if (rows.isEmpty) return null;
    return AttendanceScoreInfo.fromRow(
      Map<String, dynamic>.from(rows.first as Map),
    );
  }

  /// 과제 점수 + 학원 내 상위 퍼센트 (학습앱 스탯과 동일 산식).
  Future<HomeworkScoreInfo?> getHomeworkScore() async {
    final rows =
        await _client.rpc('student_get_homework_score_v1') as List<dynamic>;
    if (rows.isEmpty) return null;
    return HomeworkScoreInfo.fromRow(
      Map<String, dynamic>.from(rows.first as Map),
    );
  }

  /// 총점(출석 + 과제 가중 평균) + 학원 내 순위.
  Future<TotalScoreInfo?> getTotalScore() async {
    final rows =
        await _client.rpc('student_get_total_score_v1') as List<dynamic>;
    if (rows.isEmpty) return null;
    return TotalScoreInfo.fromRow(
      Map<String, dynamic>.from(rows.first as Map),
    );
  }

  /// 학생 자기평가 + 고3 수능 희망 수준 + 9등급 선택지.
  Future<StudentDesiredLevelInfo> getDesiredLevel() async {
    final rows =
        await _client.rpc('student_get_level_profile_v1') as List<dynamic>;
    if (rows.isEmpty) return const StudentDesiredLevelInfo();
    return StudentDesiredLevelInfo.fromRow(
      Map<String, dynamic>.from(rows.first as Map),
    );
  }

  /// 학생이 입력하는 두 값만 저장한다. 선생님의 현재 추정/미래 예상은 건드리지 않는다.
  Future<StudentDesiredLevelInfo> setReportedLevels({
    required int? selfAssessedTopPercent,
    required int? desiredTopPercent,
  }) async {
    final rows = await _client.rpc(
      'student_set_reported_levels_v1',
      params: {
        'p_self_assessed_top_percent': selfAssessedTopPercent,
        'p_desired_top_percent': desiredTopPercent,
      },
    ) as List<dynamic>;
    if (rows.isEmpty) {
      return StudentDesiredLevelInfo(
        selfAssessedUpperPercent: selfAssessedTopPercent?.toDouble(),
        upperPercent: desiredTopPercent?.toDouble(),
      );
    }
    final row = Map<String, dynamic>.from(rows.first as Map);
    final top = (row['desired_top_percent'] as num?)?.toDouble() ??
        (row['upper_percent'] as num?)?.toDouble() ??
        desiredTopPercent?.toDouble();
    return StudentDesiredLevelInfo(
      selfAssessedUpperPercent:
          (row['self_assessed_top_percent'] as num?)?.toDouble() ??
              selfAssessedTopPercent?.toDouble(),
      levelCode: (row['desired_level_code'] as num?)?.toInt(),
      upperPercent: top,
      displayName: (row['display_name'] as String?)?.trim(),
    );
  }

  /// 이번 열린 출석(등원) 이후 완료한 과제. 리스트 전용(수행률·완료율과 분리).
  Future<List<TodayCompletedHomework>> listSessionCompletedHomework() async {
    final rows = await _client.rpc('student_list_session_completed_homework_v1')
        as List<dynamic>;
    return rows
        .whereType<Map>()
        .map((r) => TodayCompletedHomework.fromRow(
              Map<String, dynamic>.from(r),
            ))
        .toList(growable: false);
  }

  /// 최근 [days]일 완료 과제 (기본 30일). 기록 보기 다이얼로그용.
  Future<List<TodayCompletedHomework>> listRecentCompletedHomework({
    int days = 30,
  }) async {
    final rows = await _client.rpc(
      'student_list_recent_completed_homework_v1',
      params: {'p_days': days},
    ) as List<dynamic>;
    return rows
        .whereType<Map>()
        .map((r) => TodayCompletedHomework.fromRow(
              Map<String, dynamic>.from(r),
            ))
        .toList(growable: false);
  }

  /// 오늘 수업 계획 진행률 (계획=오늘+대기 권장분, 완료=완료 과제 권장분).
  Future<StudentTodayPlanProgress> todayPlanProgress() async {
    final rows =
        await _client.rpc('student_today_plan_progress_v1') as List<dynamic>;
    if (rows.isEmpty) return const StudentTodayPlanProgress();
    final row = rows.first;
    if (row is! Map) return const StudentTodayPlanProgress();
    return StudentTodayPlanProgress.fromRow(Map<String, dynamic>.from(row));
  }

  /// (오늘 등원 경과시간 - 설정 휴식시간)과 오늘 새로 통과한 문항수.
  Future<StudentTodayProductivity> todayProductivity() async {
    final rows =
        await _client.rpc('student_today_productivity_v1') as List<dynamic>;
    if (rows.isEmpty) return const StudentTodayProductivity();
    final row = rows.first;
    if (row is! Map) return const StudentTodayProductivity();
    return StudentTodayProductivity.fromRow(Map<String, dynamic>.from(row));
  }

  /// 하원 회차 스냅샷(오늘 열린 회차는 실시간)을 날짜별로 합산한 수행률.
  Future<List<StudentDailyPerformance>> dailyPerformance({
    int days = 8,
  }) async {
    final rows = await _client.rpc(
      'student_daily_performance_v1',
      params: {'p_days': days},
    ) as List<dynamic>;
    return rows
        .whereType<Map>()
        .map((row) => StudentDailyPerformance.fromRow(
              Map<String, dynamic>.from(row),
            ))
        .whereType<StudentDailyPerformance>()
        .toList(growable: false);
  }

  /// 과제 그룹 목록 (메인 + 하원숙제 + 플래그 병합).
  Future<List<HomeworkGroup>> listHomeworkGroups() async {
    final results = await Future.wait([
      _client.rpc('student_list_homework_groups_v1'),
      _client.rpc('student_list_homework_only_groups_v1'),
      _client.rpc('student_group_test_naesin_flags'),
      _client.rpc('student_group_pending_complete_flags'),
      _client.rpc('student_homework_inspection_metadata_v1'),
    ]);

    final inspectionByGroup = <String, Map<String, dynamic>>{};
    for (final raw in results[4] as List<dynamic>) {
      if (raw is! Map) continue;
      final row = Map<String, dynamic>.from(raw);
      final groupId = '${row['group_id'] ?? ''}'.trim();
      if (groupId.isNotEmpty) inspectionByGroup[groupId] = row;
    }
    Map<String, dynamic> withInspection(Map<String, dynamic> source) {
      final row = Map<String, dynamic>.from(source);
      final metadata = inspectionByGroup['${row['group_id'] ?? ''}'.trim()];
      if (metadata != null) row.addAll(metadata);
      return row;
    }

    final main = (results[0] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map(withInspection)
        .map(HomeworkGroup.fromRow)
        .toList();
    final homeworkOnly = (results[1] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .map(withInspection)
        .map((r) => HomeworkGroup.fromRow(r, homeworkOnly: true))
        .toList();

    final flags = <String, Map<String, dynamic>>{};
    for (final r in (results[2] as List<dynamic>)) {
      if (r is Map<String, dynamic>) flags[r['group_id'] as String] = r;
    }
    final pending = <String, bool>{};
    for (final r in (results[3] as List<dynamic>)) {
      if (r is Map<String, dynamic>) {
        pending[r['group_id'] as String] =
            (r['pending_complete'] as bool?) ?? false;
      }
    }

    final all = [...main, ...homeworkOnly];
    for (final g in all) {
      final f = flags[g.groupId];
      if (f != null) {
        g.isTest = (f['is_test'] as bool?) ?? false;
        g.isNaesin = (f['is_naesin'] as bool?) ?? false;
      }
      g.pendingComplete = pending[g.groupId] ?? false;
    }

    // RPC에 플래그가 아직 없거나 false만 오면, 열린 출석의 스냅샷으로 클라이언트 보강.
    final needsClientSnapshot = all.any(
      (g) => g.isInClass && !g.isAdditionalAfterSnapshot,
    );
    if (needsClientSnapshot) {
      try {
        final snapshot = await _loadOpenPlanGoalSnapshot();
        if (snapshot != null) {
          final snapshotAt = snapshot.$1;
          final snapshotIds = snapshot.$2;
          if (snapshotAt != null) {
            for (final g in all) {
              if (!g.isInClass || g.children.isEmpty) continue;
              final anyInSnapshot = g.children.any(
                (child) => snapshotIds.contains(child.itemId),
              );
              if (!anyInSnapshot) {
                g.isAdditionalAfterSnapshot = true;
              }
            }
          }
        }
      } catch (e) {
        debugPrint('[HW][goal-snapshot] client fallback failed: $e');
      }
    }

    all.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return all;
  }

  /// 열린 등원 세션의 목표 제시 스냅샷.
  Future<StudentPlanGoalSnapshot?> openPlanGoalSnapshot() async {
    final id = await identity();
    if (id == null) return null;
    final rows = await _client
        .from('attendance_records')
        .select(
          'homework_plan_snapshot_at,homework_plan_snapshot_item_ids,'
          'homework_plan_snapshot_minutes',
        )
        .eq('student_id', id.studentId)
        .not('arrival_time', 'is', null)
        .isFilter('departure_time', null)
        .order('arrival_time', ascending: false)
        .limit(1);
    if (rows is! List || rows.isEmpty) return null;
    final row = Map<String, dynamic>.from(rows.first as Map);
    final atRaw = row['homework_plan_snapshot_at'];
    final at = atRaw == null ? null : DateTime.tryParse('$atRaw')?.toLocal();
    final ids = <String>{};
    final rawIds = row['homework_plan_snapshot_item_ids'];
    if (rawIds is List) {
      for (final value in rawIds) {
        final itemId = '$value'.trim();
        if (itemId.isNotEmpty) ids.add(itemId);
      }
    }
    final rawMinutes = row['homework_plan_snapshot_minutes'];
    final minutes =
        rawMinutes is num ? rawMinutes.toInt() : int.tryParse('$rawMinutes');
    return StudentPlanGoalSnapshot(
      presentedAt: at,
      itemIds: ids,
      planMinutes: minutes == null ? null : (minutes < 0 ? 0 : minutes),
    );
  }

  /// 열린 등원 세션의 목표 제시 스냅샷. (at, itemIds)
  Future<(DateTime?, Set<String>)?> _loadOpenPlanGoalSnapshot() async {
    final snap = await openPlanGoalSnapshot();
    if (snap == null) return null;
    return (snap.presentedAt, snap.itemIds);
  }

  /// 과제 그룹에 배정된 문항 목록. legacy 과제면 빈 목록.
  Future<List<HomeworkProblem>> listHomeworkProblems(String groupId) async {
    final rows = await _client.rpc(
      'student_list_homework_problems_v1',
      params: {'p_group_id': groupId},
    ) as List<dynamic>;
    return rows
        .whereType<Map<String, dynamic>>()
        .map(HomeworkProblem.fromRow)
        .toList(growable: false);
  }

  /// 과제 이탈 시 안 푼 문항을 미수행(skipped)으로 기록한다.
  /// 시도 +1 이 되고 회차 이력에 남아, 학습앱에서도 "미수행"으로 보인다.
  Future<void> logHomeworkSkipped({
    required String groupId,
    required String cropId,
  }) async {
    final id = await identity();
    if (id == null) return;
    await _client.rpc('learning_log_homework_attempt', params: {
      'p_student_id': id.studentId,
      'p_homework_group_id': groupId,
      'p_crop_id': cropId,
      'p_result': 'skipped',
      'p_scored_by': 'self',
      'p_meta': {'exit_flush': true},
    });
  }

  /// 셀프 채점을 배정 문항에 직접 남긴다.
  /// edge self_mark 가 자유 풀이로만 남기거나 삼킨 경우를 보완한다.
  Future<void> logHomeworkSelfMark({
    required String groupId,
    required String cropId,
    required bool correct,
    String? answer,
  }) async {
    final id = await identity();
    if (id == null) {
      throw StateError('student_identity_missing');
    }
    final result = await _client.rpc('learning_log_homework_attempt', params: {
      'p_student_id': id.studentId,
      'p_homework_group_id': groupId,
      'p_crop_id': cropId,
      'p_result': correct ? 'correct' : 'wrong',
      'p_scored_by': 'self',
      'p_answer_text': (answer ?? '').trim().isEmpty ? null : answer,
      'p_assist_level': 'unknown',
      'p_meta': {'self_mark_link': true},
    });
    if (result is Map && result['ok'] != true) {
      throw StateError(
        'homework_self_mark_link_failed:${result['reason'] ?? 'unknown'}',
      );
    }
  }

  /// 채점이 있었던 풀이 이탈을 검사 1회로 남긴다 (check_count +1).
  /// 단계는 바꾸지 않는다. 열기만 하고 나온 경우에는 호출하지 않는다.
  Future<void> recordHomeworkSelfInspection(String groupId) async {
    await _client.rpc(
      'student_record_homework_self_inspection_v1',
      params: {'p_group_id': groupId},
    );
  }

  /// 문항 통과 현황 요약.
  Future<HomeworkMastery> homeworkMastery(String groupId) async {
    final result = await _client.rpc(
      'student_homework_group_mastery_v1',
      params: {'p_group_id': groupId},
    );
    if (result is! Map<String, dynamic>) return HomeworkMastery.none;
    return HomeworkMastery.fromMap(result);
  }

  /// 배정 문항을 전부 맞혔으면 과제를 통과 처리한다.
  /// 조건을 못 채우면 서버가 아무것도 바꾸지 않고 사유만 돌려준다.
  Future<Map<String, dynamic>> completeHomeworkIfMastered(
      String groupId) async {
    final result = await _client.rpc(
      'student_complete_homework_group_if_mastered',
      params: {'p_group_id': groupId},
    );
    return (result as Map<String, dynamic>?) ?? const {'ok': false};
  }

  /// 이번 주(일~토) 일별 수업시간 + 최근 90일 평균.
  Future<StudentClassDurationWeek> classDurationWeek() async {
    final raw = await _client.rpc('student_class_duration_week_v1');
    final map =
        raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    return StudentClassDurationWeek.fromJson(map);
  }

  /// 다음 회차 수업 (아직 시작 전). 없으면 null.
  Future<StudentNextClass?> nextClass() async {
    final raw = await _client.rpc('student_next_class_v1');
    final rows = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];
    if (rows.isEmpty) return null;
    final row = rows.first;
    final rawDt = row['class_date_time'];
    if (rawDt == null) return null;
    final dt = DateTime.tryParse(rawDt.toString())?.toLocal();
    if (dt == null) return null;
    final rawEnd = row['class_end_time'];
    return StudentNextClass(
      classDateTime: dt,
      classEndTime: rawEnd == null
          ? null
          : DateTime.tryParse(rawEnd.toString())?.toLocal(),
      className: (row['class_name'] as String?)?.trim(),
    );
  }

  Future<TodayAttendance> todayAttendance() async {
    final raw = await _client.rpc('student_today_attendance');
    final rows = raw is List
        ? raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];
    if (rows.isEmpty) return const TodayAttendance();

    DateTime? parse(Map<String, dynamic> row, String key) {
      final value = row[key];
      if (value == null) return null;
      return DateTime.tryParse(value.toString())?.toLocal();
    }

    // 등원 시각이 있는 행을 우선 (여러 수업이면 가장 이른 등원).
    Map<String, dynamic>? best;
    DateTime? bestArrival;
    for (final row in rows) {
      final arrival = parse(row, 'arrival_time');
      if (arrival == null) continue;
      if (bestArrival == null || arrival.isBefore(bestArrival)) {
        best = row;
        bestArrival = arrival;
      }
    }
    final row = best ?? rows.first;
    final reason = (row['early_leave_reason'] as String?)?.trim();
    return TodayAttendance(
      arrival: parse(row, 'arrival_time'),
      departure: parse(row, 'departure_time'),
      classDateTime: parse(row, 'class_date_time'),
      classEndTime: parse(row, 'class_end_time'),
      plannedDepartureAt: parse(row, 'planned_departure_at'),
      earlyLeaveReason: (reason == null || reason.isEmpty) ? null : reason,
    );
  }

  /// 최근 N회 출결(등원 편차). 최신이 앞.
  Future<List<RecentAttendanceSession>> listRecentAttendance({
    int limit = 10,
  }) async {
    final rows = await _client.rpc(
      'student_list_recent_attendance_v1',
      params: {'p_limit': limit},
    ) as List<dynamic>;
    return rows
        .whereType<Map>()
        .map((r) => RecentAttendanceSession.fromRow(
              Map<String, dynamic>.from(r),
            ))
        .whereType<RecentAttendanceSession>()
        .toList(growable: false);
  }

  // ---------------------------------------------------------------- 기록

  /// 그룹 전환. from_phase: 1(시작)/2/4(확인→대기)/99(제출).
  Future<Map<String, dynamic>> groupTransition({
    required String groupId,
    required int fromPhase,
  }) async {
    final requestId =
        '${DateTime.now().millisecondsSinceEpoch}-$groupId-$fromPhase';
    final result = await _client.rpc('student_group_transition', params: {
      'p_group_id': groupId,
      'p_from_phase': fromPhase,
      'p_request_id': requestId,
    });
    return (result as Map<String, dynamic>?) ?? const {'ok': false};
  }

  Future<void> pauseAll() => _client.rpc('student_pause_all');

  /// 수행 중임을 서버에 알린다 (30초 주기).
  /// 신호가 끊기면 서버가 마지막 신호 시점으로 타이머를 마감하므로,
  /// 앱이 갑자기 죽어도 그때까지의 학습 시간은 남는다.
  Future<void> homeworkBeat() => _client.rpc('student_homework_beat');

  /// 앱이 죽었다 돌아온 경우 — 마지막 신호 시점까지만 인정하고 멈춘다.
  Future<void> homeworkRewind({String reason = 'app_closed'}) =>
      _client.rpc('student_homework_rewind', params: {'p_reason': reason});

  Future<void> raiseQuestion() => _client.rpc('student_raise_question');

  Future<Map<String, dynamic>> createDescriptiveWriting() async {
    final result = await _client.rpc('student_create_descriptive_writing');
    return (result as Map<String, dynamic>?) ?? const {};
  }

  Future<void> recordArrival() => _client.rpc('student_record_arrival');

  Future<void> recordDeparture() => _client.rpc('student_record_departure');

  /// 오늘 예정 귀가 시각 설정. [plannedDepartureAt]이 null이면 해제.
  /// 정규 종료보다 이르면 [reason] 필수(서버 `early_leave_reason_required`).
  Future<void> setPlannedDeparture({
    DateTime? plannedDepartureAt,
    String? reason,
  }) async {
    await _client.rpc(
      'student_set_planned_departure',
      params: {
        'p_planned_departure_at': plannedDepartureAt?.toUtc().toIso8601String(),
        'p_reason': reason,
      },
    );
  }
}

class StudentApiException implements Exception {
  StudentApiException(this.message);
  final String message;

  @override
  String toString() => message;
}
