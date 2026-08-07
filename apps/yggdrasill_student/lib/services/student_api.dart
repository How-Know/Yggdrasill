import 'dart:convert';
import 'dart:typed_data';

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

  bool get isInClass => listKind == HomeworkListKind.inClass;
  bool get isHomework => listKind == HomeworkListKind.homework;
  bool get isDueForCheck => inspectionStatus == 'due_for_check';

  String get inspectionLabel {
    if (!isDueForCheck) return '';
    if (absenceCarryover) return '결석 이월 · 오늘 검사';
    final original = originalDueDate;
    if (original != null) {
      final local = original.toLocal();
      final originalDay = DateTime(local.year, local.month, local.day);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      if (originalDay.isBefore(today)) {
        return '미검사 이월 · 오늘 검사';
      }
    }
    return '오늘 검사';
  }

  String get assignmentOriginLabel {
    switch (assignmentOrigin) {
      case HomeworkAssignmentOrigin.direct:
        return '직접 숙제';
      case HomeworkAssignmentOrigin.classCarryover:
        return '수업 이월';
      case HomeworkAssignmentOrigin.unknown:
        return '';
    }
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
  final int attemptCount;

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
  const TodayAttendance({this.arrival, this.departure, this.classDateTime});

  final DateTime? arrival;
  final DateTime? departure;
  final DateTime? classDateTime;
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

/// 오늘 완료된 과제 그룹 (진행률 상세 카드용, completed_at 기준).
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

  Future<void> signOut() => _client.auth.signOut();

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

  /// 출결 점수 + 학원 내 상위 퍼센트.
  Future<AttendanceScoreInfo?> getAttendanceScore() async {
    final rows =
        await _client.rpc('student_get_attendance_score_v1') as List<dynamic>;
    if (rows.isEmpty) return null;
    return AttendanceScoreInfo.fromRow(
      Map<String, dynamic>.from(rows.first as Map),
    );
  }

  /// 오늘 완료한 과제 그룹 (completed_at 기준, 상세 카드·수행속도용).
  Future<List<TodayCompletedHomework>> listTodayCompletedHomework() async {
    final rows = await _client.rpc('student_list_today_completed_homework_v1')
        as List<dynamic>;
    return rows
        .whereType<Map>()
        .map((r) => TodayCompletedHomework.fromRow(
              Map<String, dynamic>.from(r),
            ))
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
    all.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    return all;
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
    return TodayAttendance(
      arrival: parse(row, 'arrival_time'),
      departure: parse(row, 'departure_time'),
      classDateTime: parse(row, 'class_date_time'),
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

  Future<void> raiseQuestion() => _client.rpc('student_raise_question');

  Future<Map<String, dynamic>> createDescriptiveWriting() async {
    final result = await _client.rpc('student_create_descriptive_writing');
    return (result as Map<String, dynamic>?) ?? const {};
  }

  Future<void> recordArrival() => _client.rpc('student_record_arrival');

  Future<void> recordDeparture() => _client.rpc('student_record_departure');
}

class StudentApiException implements Exception {
  StudentApiException(this.message);
  final String message;

  @override
  String toString() => message;
}
