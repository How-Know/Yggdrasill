import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import 'pdf/todo_sheet_math.dart';
import '../models/attendance_record.dart';
import '../models/student_time_block.dart';
import '../services/data_manager.dart';
import '../services/homework_assignment_store.dart';
import '../services/homework_store.dart';
import '../services/homework_time_defaults_service.dart';
import '../services/lesson_record_service.dart';
import '../services/next_class_start_resolver.dart';
import '../services/print_routing_service.dart';
import '../services/resource_service.dart';
import '../services/student_behavior_assignment_store.dart';
import '../services/tag_store.dart';
import '../services/tenant_service.dart';
import '../utils/homework_card_label.dart';
import '../utils/homework_page_text.dart';
part 'pdf/todo_sheet_refined.dart';
part 'pdf/todo_sheet_sample.dart';

class HomeworkAssignSelection {
  final List<String> itemIds;
  final DateTime? dueDate;
  final List<String> selectableItemIds;
  final bool printTodoOnConfirm;
  final List<String> selectedBehaviorIds;
  final Map<String, int> irregularBehaviorCounts;
  final Map<String, DateTime> dueDateByItemId;
  final List<String> planHomeworkItemIds;
  const HomeworkAssignSelection({
    required this.itemIds,
    required this.dueDate,
    this.selectableItemIds = const <String>[],
    this.printTodoOnConfirm = false,
    this.selectedBehaviorIds = const <String>[],
    this.irregularBehaviorCounts = const <String, int>{},
    this.dueDateByItemId = const <String, DateTime>{},
    this.planHomeworkItemIds = const <String>[],
  });
}

class _TodoListEntry {
  final String primary;
  final String? secondary;
  final String? tertiary;
  final String? bookTitle;
  final String? itemTitle;
  final String? rightPrimary;
  final String? rightSecondary;
  final String? rightTertiary;
  const _TodoListEntry({
    required this.primary,
    this.secondary,
    this.tertiary,
    this.bookTitle,
    this.itemTitle,
    this.rightPrimary,
    this.rightSecondary,
    this.rightTertiary,
  });
}

class _CheckRateEntry {
  final String title;
  final int? progress;
  final int? previousProgress;
  final int? todayProgress;
  final String bookAndCourse;
  final String page;
  final String count;
  final DateTime? assignedAt;
  final DateTime? dueDate;
  final DateTime? checkedAt;
  final String? outcome;
  final String? reason;

  /// 학생이 자의로 미리 해온 과제(추가검사 마커)인지 여부.
  /// 검사율 합계에서 분자(오늘 추가분)에는 포함하되 분모(남은%)에서는 제외한다.
  final bool isExtra;
  const _CheckRateEntry({
    required this.title,
    required this.progress,
    this.previousProgress,
    this.todayProgress,
    required this.bookAndCourse,
    required this.page,
    required this.count,
    required this.assignedAt,
    this.dueDate,
    this.checkedAt,
    this.outcome,
    this.reason,
    this.isExtra = false,
  });
}

class _SubWorkEntry {
  final String title;
  final String page;
  final String count;
  const _SubWorkEntry(
      {required this.title, required this.page, required this.count});
}

class _ClassWorkEntry {
  final String title;
  final String bookAndCourse;
  final String page;
  final String count;
  final DateTime? assignedAt;
  final int studyMs;
  final int todayCheckCount;

  /// 학습앱 카드의 '검사 N회'와 같은 누적 검사 횟수.
  final int totalCheckCount;

  /// 그룹의 모든 하위과제가 완료됨.
  final bool passed;

  /// 하위과제 누적 수행시간 합(학습앱 완료 카드의 '총 …'와 같은 기준).
  final int totalAccumulatedMs;
  final List<_SubWorkEntry> subEntries;
  const _ClassWorkEntry({
    required this.title,
    required this.bookAndCourse,
    required this.page,
    required this.count,
    required this.assignedAt,
    required this.studyMs,
    this.todayCheckCount = 0,
    this.totalCheckCount = 0,
    this.passed = false,
    this.totalAccumulatedMs = 0,
    this.subEntries = const <_SubWorkEntry>[],
  });
}

({int checks, bool passed, int totalMs}) _groupCheckPassTotals({
  required HomeworkGroup? group,
  required List<HomeworkItem> children,
  required DateTime departureTime,
}) {
  final now = DateTime.now();
  final cap = departureTime.isAfter(now) ? now : departureTime;
  int maxChildChecks = 0;
  int totalMs = 0;
  for (final child in children) {
    if (child.checkCount > maxChildChecks) maxChildChecks = child.checkCount;
    final runStart = child.runStart;
    final runningMs = runStart != null && cap.isAfter(runStart)
        ? cap.difference(runStart).inMilliseconds
        : 0;
    totalMs += math.max(0, child.accumulatedMs + runningMs);
  }
  final runtimeChecks = group?.runtimeCheckCount ?? 0;
  return (
    checks: runtimeChecks > 0 ? runtimeChecks : maxChildChecks,
    passed: children.isNotEmpty &&
        children.every((c) => c.status == HomeworkStatus.completed),
    totalMs: totalMs,
  );
}

class _CompletedSummaryEntry {
  final String groupTitle;
  final String bookAndCourse;
  final int totalMs;
  final int assignmentCount;
  final int checkCount;
  final double progressPct;
  final double previousProgressPct;
  final double totalProgressPct;
  final String? etaText;
  const _CompletedSummaryEntry({
    required this.groupTitle,
    required this.bookAndCourse,
    required this.totalMs,
    this.assignmentCount = 0,
    required this.checkCount,
    required this.progressPct,
    this.previousProgressPct = 0,
    double? totalProgressPct,
    this.etaText,
  }) : totalProgressPct = totalProgressPct ?? progressPct;
}

class _TodoSheetPayload {
  final String academyName;
  final Uint8List? academyLogo;
  final String studentName;
  final DateTime classDateTime;
  final DateTime? dueDate;
  final DateTime? arrivalTime;
  final DateTime departureTime;
  final String className;
  final String classTimeText;
  final String learningTimeText;
  final int learningMs;
  final List<_CheckRateEntry> checkRates;
  final List<_ClassWorkEntry> classWorkEntries;
  final List<_CompletedSummaryEntry> completedSummaries;
  final List<_TodoListEntry> completedEntries;
  final List<_TodoListEntry> todoEntries;
  final List<_TodoListEntry> behaviorEntries;
  final String behaviorFeedback;
  final LessonRecordSummary? lessonRecord;
  final List<String> specialNotes;

  const _TodoSheetPayload({
    required this.academyName,
    required this.academyLogo,
    required this.studentName,
    required this.classDateTime,
    required this.dueDate,
    required this.arrivalTime,
    required this.departureTime,
    required this.className,
    required this.classTimeText,
    required this.learningTimeText,
    required this.learningMs,
    required this.checkRates,
    required this.classWorkEntries,
    this.completedSummaries = const <_CompletedSummaryEntry>[],
    required this.completedEntries,
    required this.todoEntries,
    required this.behaviorEntries,
    required this.behaviorFeedback,
    this.lessonRecord,
    this.specialNotes = const <String>[],
  });
}

List<String> _buildSpecialNotes({
  required String studentId,
  required DateTime classDateTime,
  DateTime? arrivalTime,
}) {
  final notes = <String>[];
  final arrival = arrivalTime?.toLocal();
  if (arrival != null) {
    final threshold =
        DataManager.instance.getStudentPaymentInfo(studentId)?.latenessThreshold ??
            10;
    if (arrival.isAfter(classDateTime.add(Duration(minutes: threshold)))) {
      final lateMinutes = arrival.difference(classDateTime).inMinutes;
      notes.add('$lateMinutes분 지각 (등원 ${_formatTime(arrival)})');
    }
  }
  return notes;
}

class _HomeworkPhaseEvent {
  final String itemId;
  final int phase;
  final DateTime at;
  const _HomeworkPhaseEvent({
    required this.itemId,
    required this.phase,
    required this.at,
  });
}

/// 하원 다이얼로그의 "기본 선택"을 UI 없이 그대로 재현한다.
/// 키오스크 하원 → PC 자동 인쇄 경로에서 사용한다. (미완료 숙제 전체 +
/// 다음 예정 수업 마감일 + 정기 행동) 인쇄 대상이 없으면 null 을 반환한다.
Future<HomeworkAssignSelection?> buildDefaultHomeworkAssignSelection(
  String studentId, {
  DateTime? anchorTime,
  Set<String>? initialSelectedGroupIds,
  Set<String>? initialSelectedItemIds,
  Set<String> excludedItemIds = const <String>{},
  Map<String, DateTime> initialDueDateByGroupId = const <String, DateTime>{},
}) async {
  final allItems = HomeworkStore.instance.items(studentId);
  if (allItems.isEmpty) return null;

  final activeAssignments =
      await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
  final hiddenAssignedItemIds = activeAssignments
      .map((a) => a.homeworkItemId.trim())
      .where((id) => id.isNotEmpty)
      .toSet();

  final allGroups = HomeworkStore.instance.groups(studentId);
  final allGroupChildIds = <String>[];
  final selectedGroupChildIds = <String>[];
  final groupIdByChildId = <String, String>{};
  for (final group in allGroups) {
    final children = HomeworkStore.instance
        .itemsInGroup(studentId, group.id, includeCompleted: true)
        .where((e) => e.status != HomeworkStatus.completed)
        .where((e) => !hiddenAssignedItemIds.contains(e.id))
        .where((e) => !excludedItemIds.contains(e.id))
        .toList();
    for (final c in children) {
      allGroupChildIds.add(c.id);
      groupIdByChildId[c.id] = group.id;
      if (initialSelectedItemIds != null
          ? initialSelectedItemIds.contains(c.id)
          : (initialSelectedGroupIds == null ||
              initialSelectedGroupIds.contains(group.id))) {
        selectedGroupChildIds.add(c.id);
      }
    }
  }

  final behaviorAssignments = await StudentBehaviorAssignmentStore.instance
      .loadForStudent(studentId, force: true);
  behaviorAssignments.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));

  // 다음 예정 수업 시각 = 마감일 기본값
  final anchor = anchorTime ?? DateTime.now();
  final Set<int> seenKeys = <int>{};
  int keyOf(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day, dt.hour, dt.minute)
          .millisecondsSinceEpoch;
  final List<DateTime> optionTimes = [];
  void addOption(DateTime dt) {
    if (!dt.isAfter(anchor)) return;
    final key = keyOf(dt);
    if (seenKeys.contains(key)) return;
    seenKeys.add(key);
    optionTimes.add(dt);
  }

  final records = DataManager.instance.attendanceRecords
      .where((r) => r.studentId == studentId)
      .toList()
    ..sort((a, b) => a.classDateTime.compareTo(b.classDateTime));
  for (final r in records) {
    addOption(r.classDateTime);
  }

  final day = DateTime(anchor.year, anchor.month, anchor.day);
  final dayIdx = day.weekday - 1;
  bool isActiveOn(StudentTimeBlock b, DateTime date) {
    final target = DateTime(date.year, date.month, date.day);
    final start =
        DateTime(b.startDate.year, b.startDate.month, b.startDate.day);
    final end = b.endDate != null
        ? DateTime(b.endDate!.year, b.endDate!.month, b.endDate!.day)
        : null;
    return !start.isAfter(target) && (end == null || !end.isBefore(target));
  }

  final blocks = DataManager.instance.studentTimeBlocks
      .where((b) =>
          b.studentId == studentId &&
          b.dayIndex == dayIdx &&
          isActiveOn(b, day))
      .toList();
  final Map<String, List<StudentTimeBlock>> blocksBySessionKey =
      <String, List<StudentTimeBlock>>{};
  for (final b in blocks) {
    final setId = (b.setId ?? '').trim();
    final key = setId.isNotEmpty ? 'set:$setId' : 'single:${b.id}';
    blocksBySessionKey.putIfAbsent(key, () => <StudentTimeBlock>[]).add(b);
  }
  for (final group in blocksBySessionKey.values) {
    group.sort((a, b) {
      if (a.startHour != b.startHour) return a.startHour - b.startHour;
      return a.startMinute - b.startMinute;
    });
    final first = group.first;
    addOption(
      DateTime(
          day.year, day.month, day.day, first.startHour, first.startMinute),
    );
  }

  optionTimes.sort((a, b) => a.compareTo(b));
  final DateTime? dueDate = NextClassStartResolver.next(
    studentId,
    after: anchor,
  );

  final selectedBehaviorIds = behaviorAssignments
      .where((b) => !b.isIrregular)
      .map((b) => b.id)
      .toList();
  final irregularBehaviorCounts = <String, int>{
    for (final b in behaviorAssignments.where((e) => e.isIrregular)) b.id: 1,
  };

  return HomeworkAssignSelection(
    itemIds: List<String>.from(selectedGroupChildIds),
    dueDate: dueDate,
    dueDateByItemId: <String, DateTime>{
      for (final itemId in selectedGroupChildIds)
        if ((initialDueDateByGroupId[groupIdByChildId[itemId]] ?? dueDate) !=
            null)
          itemId:
              (initialDueDateByGroupId[groupIdByChildId[itemId]] ?? dueDate)!,
    },
    selectableItemIds: List<String>.from(allGroupChildIds),
    planHomeworkItemIds: initialSelectedItemIds == null
        ? const <String>[]
        : selectedGroupChildIds
            .where(initialSelectedItemIds.contains)
            .toList(growable: false),
    printTodoOnConfirm: true,
    selectedBehaviorIds: selectedBehaviorIds,
    irregularBehaviorCounts: irregularBehaviorCounts,
  );
}

Future<void> printHomeworkTodoSheet({
  required String studentId,
  required String studentName,
  required DateTime classDateTime,
  DateTime? arrivalTime,
  required DateTime departureTime,
  required List<String> selectedHomeworkIds,
  List<String>? additionalHomeworkIds,
  List<String>? selectedBehaviorIds,
  Map<String, int>? irregularBehaviorCounts,
  DateTime? dueDate,
  String? className,
  DateTime? classEndTime,
  String? setId,
}) async {
  final payload = await _prepareTodoSheetPayload(
    studentId: studentId,
    studentName: studentName,
    classDateTime: classDateTime,
    arrivalTime: arrivalTime,
    departureTime: departureTime,
    selectedHomeworkIds: selectedHomeworkIds,
    additionalHomeworkIds: additionalHomeworkIds,
    selectedBehaviorIds: selectedBehaviorIds,
    irregularBehaviorCounts: irregularBehaviorCounts,
    dueDate: dueDate,
    className: className,
    classEndTime: classEndTime,
    setId: setId,
  );
  final outPath = await _buildHomeworkTodoPdf(payload: payload);
  await _openPrintDialogForPath(outPath);
  _scheduleTempDelete(outPath);
  _refreshLessonRecordAfterPrint(
    studentId: studentId,
    classDateTime: classDateTime,
  );
}

AttendanceRecord? _findTodoSheetAttendanceRecord({
  required String studentId,
  required DateTime classDateTime,
}) {
  AttendanceRecord? matched;
  for (final rec in DataManager.instance.attendanceRecords) {
    if (rec.studentId != studentId) continue;
    if (!_isSameDay(rec.classDateTime, classDateTime)) continue;
    matched = rec;
    if (rec.classDateTime == classDateTime) break;
  }
  return matched;
}

/// 하원 뒤 알림장을 다시 뽑으면 그 사이 채점·검사가 반영되도록 요약을 다시 계산한다.
void _refreshLessonRecordAfterPrint({
  required String studentId,
  required DateTime classDateTime,
}) {
  final record = _findTodoSheetAttendanceRecord(
    studentId: studentId,
    classDateTime: classDateTime,
  );
  final attendanceId = (record?.id ?? '').trim();
  if (attendanceId.isEmpty || record?.departureTime == null) return;
  unawaited(LessonRecordService.instance.refresh(attendanceId));
}

Future<void> previewHomeworkTodoSheet({
  required String studentId,
  required String studentName,
  required DateTime classDateTime,
  DateTime? arrivalTime,
  required DateTime departureTime,
  required List<String> selectedHomeworkIds,
  List<String>? additionalHomeworkIds,
  List<String>? selectedBehaviorIds,
  Map<String, int>? irregularBehaviorCounts,
  DateTime? dueDate,
  String? className,
  DateTime? classEndTime,
  String? setId,
}) async {
  final payload = await _prepareTodoSheetPayload(
    studentId: studentId,
    studentName: studentName,
    classDateTime: classDateTime,
    arrivalTime: arrivalTime,
    departureTime: departureTime,
    selectedHomeworkIds: selectedHomeworkIds,
    additionalHomeworkIds: additionalHomeworkIds,
    selectedBehaviorIds: selectedBehaviorIds,
    irregularBehaviorCounts: irregularBehaviorCounts,
    dueDate: dueDate,
    className: className,
    classEndTime: classEndTime,
    setId: setId,
  );
  final outPath = await _buildHomeworkTodoPdf(payload: payload);
  await OpenFilex.open(outPath);
  _scheduleTempDelete(outPath);
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// [day]의 검사 중 그 숙제 배정의 첫 검사가 있는지 (서버 _lesson_record_compute 와 같은 기준).
bool _hasFirstAssignmentCheckOn(
  List<HomeworkAssignmentCheck> checks,
  DateTime day,
) {
  for (final c in checks) {
    if (!_isSameDay(c.checkedAt, day)) continue;
    final assignmentId = (c.assignmentId ?? '').trim();
    if (assignmentId.isEmpty) return true;
    final checkedBefore = checks.any(
      (p) =>
          (p.assignmentId ?? '').trim() == assignmentId &&
          p.checkedAt.isBefore(c.checkedAt),
    );
    if (!checkedBefore) return true;
  }
  return false;
}

String _extractBookNameFromHomework(HomeworkItem hw) {
  final contentRaw = (hw.content ?? '').trim();
  final fromContent = RegExp(r'(?:^|\n)\s*교재:\s*([^\n]+)')
          .firstMatch(contentRaw)
          ?.group(1)
          ?.trim() ??
      '';
  if (fromContent.isNotEmpty) return fromContent;

  final title = hw.title.trim();
  if (title.contains('·')) {
    final candidate = title.split('·').first.trim();
    if (candidate.isNotEmpty) return candidate;
  }
  if (title.isNotEmpty) return title;
  final type = (hw.type ?? '').trim();
  if (type.isNotEmpty) return type;
  return '교재 미기재';
}

String _extractCourseNameFromHomework(HomeworkItem hw) {
  final contentRaw = (hw.content ?? '').trim();
  final fromContent = RegExp(r'(?:^|\n)\s*과정:\s*([^\n]+)')
          .firstMatch(contentRaw)
          ?.group(1)
          ?.trim() ??
      '';
  if (fromContent.isNotEmpty) return fromContent;
  final gradeLabel = (hw.gradeLabel ?? '').trim();
  if (gradeLabel.isNotEmpty) return gradeLabel;
  return '';
}

String _formatBookAndCourseFromHomework(HomeworkItem hw) {
  final bookName = _extractBookNameFromHomework(hw);
  final courseName = _extractCourseNameFromHomework(hw);
  if (courseName.isEmpty) return bookName;
  if (bookName.contains('($courseName)')) return bookName;
  return '$bookName ($courseName)';
}

int _countTotalPagesFromPayload(dynamic payload) {
  if (payload is! Map) return 0;
  final unitsRaw = payload['units'];
  if (unitsRaw is! List) return 0;
  final pages = <int>{};
  for (final big in unitsRaw) {
    if (big is! Map) continue;
    final mids = big['middles'];
    if (mids is! List) continue;
    for (final mid in mids) {
      if (mid is! Map) continue;
      final smalls = mid['smalls'];
      if (smalls is! List) continue;
      for (final small in smalls) {
        if (small is! Map) continue;
        final start = small['start_page'];
        final end = small['end_page'];
        if (start is int && end is int && start > 0 && end >= start) {
          for (int p = start; p <= end; p++) pages.add(p);
        }
        final counts = small['page_counts'];
        if (counts is Map) {
          for (final key in counts.keys) {
            final p = int.tryParse(key.toString());
            if (p != null && p > 0) pages.add(p);
          }
        }
      }
    }
  }
  return pages.length;
}

void _addPagesFromItem(Set<int> pages, HomeworkItem item) {
  final raw = (item.page ?? '').trim();
  if (raw.isEmpty) return;
  for (final part in raw.split(',')) {
    final trimmed = part.trim().replaceAll(RegExp(r'[pP.]'), '').trim();
    if (trimmed.contains('-')) {
      final parts = trimmed.split('-');
      final a = int.tryParse(parts.first.trim());
      final b = int.tryParse(parts.last.trim());
      if (a != null && b != null) {
        for (int i = a; i <= b; i++) pages.add(i);
      }
    } else {
      final p = int.tryParse(trimmed);
      if (p != null && p > 0) pages.add(p);
    }
  }
}

({int previous, int current, int today}) _progressWindowForChecks(
  List<HomeworkAssignmentCheck> checks,
  DateTime classDateTime,
) {
  int previous = 0;
  int current = 0;
  for (final check in checks) {
    final progress = check.progress.clamp(0, 150).toInt();
    if (_isSameDay(check.checkedAt, classDateTime)) {
      if (progress > current) current = progress;
    } else if (check.checkedAt.isBefore(classDateTime) && progress > previous) {
      previous = progress;
    }
  }
  if (current < previous) current = previous;
  return (
    previous: previous,
    current: current,
    today: math.max(0, current - previous),
  );
}

String _formatDurationKorean(int ms) {
  if (ms <= 0) return '0분';
  final d = Duration(milliseconds: ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0) return '$h시간 ${m}분';
  return '${d.inMinutes}분';
}

int _groupEstimatedMinutes(Iterable<HomeworkItem> items) {
  var raw = 0;
  var counted = 0;
  for (final item in items) {
    final confirmed = item.recommendedMinutes ?? 0;
    final minutes =
        confirmed > 0 ? confirmed : (item.recommendedMinutesAuto ?? 0);
    if (minutes <= 0) continue;
    raw += minutes;
    counted += 1;
  }
  if (counted == 0) return 0;
  return math.max(
    0,
    raw -
        math.max(0, counted - 1) *
            HomeworkTimeDefaultsService.initialAlphaMinutes,
  );
}

String _formatEstimatedDurationLabel(int minutes) {
  if (minutes <= 0) return '';
  final hours = minutes ~/ 60;
  final remain = minutes % 60;
  if (hours <= 0) return '예상시간 ${remain}분';
  if (remain == 0) return '예상시간 ${hours}시간';
  return '예상시간 ${hours}시간 $remain분';
}

String _formatDate(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}.${two(dt.month)}.${two(dt.day)}';
}

String _formatMonthDay(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.month)}.${two(dt.day)}';
}

String _formatPageTextCompact(String rawPage) {
  final page = rawPage.trim();
  if (page.isEmpty || page == '-') return '-';
  return 'p.$page';
}

String _formatCountText(String rawCount) {
  final count = rawCount.trim();
  if (count.isEmpty || count == '-') return '-';
  return '${count}문항';
}

String _formatDueDateForTitle(DateTime? dt) {
  if (dt == null) return '검사일 미정';
  String two(int v) => v.toString().padLeft(2, '0');
  final yy = (dt.year % 100).toString().padLeft(2, '0');
  return '$yy.${two(dt.month)}.${two(dt.day)} (${_formatWeekdayKorean(dt)})까지';
}

String _formatDateTime(DateTime? dt) {
  if (dt == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.month)}.${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

String _formatTime(DateTime? dt) {
  if (dt == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}';
}

String _formatWeekdayKorean(DateTime dt) {
  const week = ['월', '화', '수', '목', '금', '토', '일'];
  return week[dt.weekday - 1];
}

String _formatClassTimeRange(DateTime start, DateTime? end) {
  final endText = _formatTime(end ?? start.add(const Duration(hours: 2)));
  return '(${_formatWeekdayKorean(start)} ${_formatTime(start)} - $endText)';
}

String _behaviorDegreeLabel(int count) {
  if (count >= 5) return '많이';
  if (count >= 3) return '자주';
  return '조금';
}

String _buildBehaviorFeedback({
  required String studentId,
  required DateTime classDateTime,
  String? setId,
}) {
  final events = <TagEvent>[];
  final primarySetId = (setId ?? '').trim();
  if (primarySetId.isNotEmpty) {
    events.addAll(TagStore.instance.getEventsForSet(primarySetId));
  }
  if (events.isEmpty) {
    final seen = <String>{};
    for (final rec in DataManager.instance.attendanceRecords) {
      if (rec.studentId != studentId) continue;
      if (!_isSameDay(rec.classDateTime, classDateTime)) continue;
      final sid = (rec.setId ?? '').trim();
      if (sid.isEmpty || !seen.add(sid)) continue;
      events.addAll(TagStore.instance.getEventsForSet(sid));
    }
  }

  if (events.isEmpty) {
    return '태도: 집중하여 공부했습니다.';
  }

  final counts = <String, int>{};
  final noteTexts = <String>[];
  for (final e in events) {
    final tag = e.tagName.trim();
    if (tag.isNotEmpty && tag != '기록') {
      counts[tag] = (counts[tag] ?? 0) + 1;
    }
    final note = (e.note ?? '').trim();
    if (note.isNotEmpty) noteTexts.add(note);
  }

  if (counts.isEmpty) {
    if (noteTexts.isNotEmpty) {
      return '태도: ${noteTexts.first}';
    }
    return '태도: 집중하여 공부했습니다.';
  }

  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final parts = <String>[];
  for (final entry in sorted.take(3)) {
    final tag = entry.key;
    final degree = _behaviorDegreeLabel(entry.value);
    if (tag.contains('졸')) {
      parts.add('수업시간에 $degree 졸았습니다.');
      continue;
    }
    if (tag.contains('스마트') || tag.contains('폰')) {
      parts.add('스마트폰을 $degree 사용했습니다.');
      continue;
    }
    if (tag.contains('딴짓')) {
      parts.add('딴짓을 $degree 했습니다.');
      continue;
    }
    if (tag.contains('떠듬')) {
      parts.add('산만한 발화가 $degree 있었습니다.');
      continue;
    }
    parts.add('$tag 행동이 $degree 있었습니다.');
  }
  if (parts.isEmpty) {
    return '태도: 집중하여 공부했습니다.';
  }
  return '태도: ${parts.join(' ')}';
}

bool _hasTodayHomeworkActivity(HomeworkItem hw, DateTime classDateTime) {
  bool isToday(DateTime? ts) => ts != null && _isSameDay(ts, classDateTime);
  return isToday(hw.firstStartedAt) ||
      isToday(hw.runStart) ||
      isToday(hw.submittedAt) ||
      isToday(hw.confirmedAt) ||
      isToday(hw.waitingAt) ||
      isToday(hw.completedAt);
}

int _estimateLearningMsForItemToday({
  required HomeworkItem hw,
  required DateTime classDateTime,
  required DateTime departureTime,
}) {
  if (!_hasTodayHomeworkActivity(hw, classDateTime)) return 0;
  int totalMs = 0;
  final cycleMs = hw.accumulatedMs - hw.cycleBaseAccumulatedMs;
  if (cycleMs > 0) totalMs += cycleMs;
  final running = hw.runStart;
  if (running != null && _isSameDay(running, classDateTime)) {
    final now = DateTime.now();
    final cap = departureTime.isAfter(now) ? now : departureTime;
    if (cap.isAfter(running)) {
      totalMs += cap.difference(running).inMilliseconds;
    }
  }
  return totalMs.clamp(0, 1000 * 60 * 60 * 24).toInt();
}

String _learningGroupKeyOf(HomeworkItem hw) {
  final groupId = (HomeworkStore.instance.groupIdOfItem(hw.id) ?? '').trim();
  return groupId.isNotEmpty ? groupId : hw.id.trim();
}

/// 그룹(그룹이 없으면 과제) 단위 오늘 수행시간.
///
/// 회차 = 하위과제 중 하나라도 수행(phase 2)에 들어간 시점부터 모두 수행을
/// 벗어날 때까지. 다른 그룹이 수행을 시작하면 서버가 나머지를 이벤트 없이
/// 멈추므로 그 시점에 닫는다. 등원~하원 밖은 잘라내고, 그룹 누적 총 시간을
/// 넘지 않는다.
Future<Map<String, int>> _computeTodayLearningMsByGroupFromPhaseEvents({
  required String studentId,
  required DateTime classDateTime,
  required DateTime departureTime,
  DateTime? arrivalTime,
  required List<HomeworkItem> allItems,
}) async {
  if (allItems.isEmpty) return const <String, int>{};
  final itemById = <String, HomeworkItem>{
    for (final hw in allItems)
      if (hw.id.trim().isNotEmpty) hw.id.trim(): hw,
  };
  final itemIds = itemById.keys.toList();
  if (itemIds.isEmpty) return const <String, int>{};
  final groupKeyByItem = <String, String>{
    for (final hw in itemById.values) hw.id.trim(): _learningGroupKeyOf(hw),
  };

  final dayStart =
      DateTime(classDateTime.year, classDateTime.month, classDateTime.day);
  final dayEnd = DateTime(
    classDateTime.year,
    classDateTime.month,
    classDateTime.day,
    23,
    59,
    59,
    999,
  );
  final now = DateTime.now();
  var capEnd = departureTime.isAfter(now) ? now : departureTime;
  if (capEnd.isAfter(dayEnd)) capEnd = dayEnd;
  var windowStart = dayStart;
  if (arrivalTime != null && arrivalTime.isAfter(windowStart)) {
    windowStart = arrivalTime;
  }
  if (!capEnd.isAfter(windowStart)) return const <String, int>{};

  int groupTotalCapMs(String key) {
    final group = HomeworkStore.instance.groupById(studentId, key);
    final children = group == null
        ? <HomeworkItem>[if (itemById[key] != null) itemById[key]!]
        : HomeworkStore.instance
            .itemsInGroup(studentId, group.id, includeCompleted: true);
    int total = 0;
    for (final child in children) {
      final runStart = child.runStart;
      final runningMs = runStart != null && now.isAfter(runStart)
          ? now.difference(runStart).inMilliseconds
          : 0;
      total += math.max(0, child.accumulatedMs + runningMs);
    }
    return total;
  }

  Map<String, int> finalize(Map<String, int> raw) {
    final out = <String, int>{};
    for (final e in raw.entries) {
      if (e.value <= 0) continue;
      final cap = groupTotalCapMs(e.key);
      final ms = cap > 0 ? math.min(e.value, cap) : e.value;
      out[e.key] = ms.clamp(0, 1000 * 60 * 60 * 24).toInt();
    }
    return out;
  }

  List<List<String>> chunksOf(List<String> source, int size) {
    final out = <List<String>>[];
    for (int i = 0; i < source.length; i += size) {
      final end = math.min(source.length, i + size);
      out.add(source.sublist(i, end));
    }
    return out;
  }

  try {
    final academyId = (await TenantService.instance.getActiveAcademyId()) ??
        await TenantService.instance.ensureActiveAcademy();
    final events = <_HomeworkPhaseEvent>[];
    for (final chunk in chunksOf(itemIds, 120)) {
      final raw = await Supabase.instance.client
          .from('homework_item_phase_events')
          .select('item_id, phase, at')
          .eq('academy_id', academyId)
          .inFilter('item_id', chunk)
          .gte('at', dayStart.toUtc().toIso8601String())
          .lte('at', capEnd.toUtc().toIso8601String())
          .order('at', ascending: true);
      for (final row in (raw as List<dynamic>).cast<Map<String, dynamic>>()) {
        final itemId = '${row['item_id'] ?? ''}'.trim();
        final phase = int.tryParse('${row['phase'] ?? ''}');
        final at = DateTime.tryParse('${row['at'] ?? ''}')?.toLocal();
        if (itemId.isEmpty || phase == null || at == null) continue;
        events.add(_HomeworkPhaseEvent(itemId: itemId, phase: phase, at: at));
      }
    }
    events.sort((a, b) {
      final byAt = a.at.compareTo(b.at);
      if (byAt != 0) return byAt;
      if (a.phase == b.phase) return 0;
      if (a.phase == 2) return 1;
      if (b.phase == 2) return -1;
      return a.phase.compareTo(b.phase);
    });

    final msByGroup = <String, int>{};
    final runningChildrenByGroup = <String, Set<String>>{};
    final cycleStartByGroup = <String, DateTime>{};

    void closeCycle(String key, DateTime end) {
      final start = cycleStartByGroup.remove(key);
      runningChildrenByGroup.remove(key);
      if (start == null) return;
      var from = start.isBefore(windowStart) ? windowStart : start;
      var to = end.isAfter(capEnd) ? capEnd : end;
      if (!to.isAfter(from)) return;
      msByGroup[key] = (msByGroup[key] ?? 0) + to.difference(from).inMilliseconds;
    }

    for (final ev in events) {
      final key = groupKeyByItem[ev.itemId];
      if (key == null) continue;
      if (ev.phase == 2) {
        for (final other in cycleStartByGroup.keys.toList()) {
          if (other != key) closeCycle(other, ev.at);
        }
        runningChildrenByGroup.putIfAbsent(key, () => <String>{}).add(ev.itemId);
        cycleStartByGroup.putIfAbsent(key, () => ev.at);
        continue;
      }
      final running = runningChildrenByGroup[key];
      if (running == null) continue;
      running.remove(ev.itemId);
      if (running.isEmpty) closeCycle(key, ev.at);
    }
    for (final key in cycleStartByGroup.keys.toList()) {
      closeCycle(key, capEnd);
    }

    // 수행 시작 이벤트가 누락된 채 지금 수행 중인 그룹만 최소 보정한다.
    for (final hw in itemById.values) {
      final runStart = hw.runStart;
      if (runStart == null || runStart.isAfter(capEnd)) continue;
      final key = groupKeyByItem[hw.id.trim()]!;
      if (msByGroup.containsKey(key)) continue;
      final from = runStart.isBefore(windowStart) ? windowStart : runStart;
      if (!capEnd.isAfter(from)) continue;
      msByGroup[key] = capEnd.difference(from).inMilliseconds;
    }

    return finalize(msByGroup);
  } catch (_) {
    final fallback = <String, int>{};
    for (final hw in itemById.values) {
      final ms = _estimateLearningMsForItemToday(
        hw: hw,
        classDateTime: classDateTime,
        departureTime: departureTime,
      );
      if (ms <= 0) continue;
      final key = groupKeyByItem[hw.id.trim()]!;
      if (ms > (fallback[key] ?? 0)) fallback[key] = ms;
    }
    return finalize(fallback);
  }
}

int _computeClassWindowMs({
  required DateTime classDateTime,
  required DateTime departureTime,
  DateTime? arrivalTime,
}) {
  final dayStart =
      DateTime(classDateTime.year, classDateTime.month, classDateTime.day);
  final dayEnd = DateTime(
    classDateTime.year,
    classDateTime.month,
    classDateTime.day,
    23,
    59,
    59,
    999,
  );
  final now = DateTime.now();
  var capDeparture = departureTime;
  if (capDeparture.isAfter(now)) capDeparture = now;
  if (capDeparture.isAfter(dayEnd)) capDeparture = dayEnd;
  var baseArrival = arrivalTime ?? classDateTime;
  if (baseArrival.isBefore(dayStart)) baseArrival = dayStart;
  if (!capDeparture.isAfter(baseArrival)) return 0;
  return capDeparture
      .difference(baseArrival)
      .inMilliseconds
      .clamp(0, 1000 * 60 * 60 * 24)
      .toInt();
}

Future<_TodoSheetPayload> _prepareTodoSheetPayload({
  required String studentId,
  required String studentName,
  required DateTime classDateTime,
  DateTime? arrivalTime,
  required DateTime departureTime,
  required List<String> selectedHomeworkIds,
  List<String>? additionalHomeworkIds,
  List<String>? selectedBehaviorIds,
  Map<String, int>? irregularBehaviorCounts,
  DateTime? dueDate,
  String? className,
  DateTime? classEndTime,
  String? setId,
}) async {
  final settings = DataManager.instance.academySettings;
  final academyName = settings.name.trim().isNotEmpty
      ? settings.name.trim()
      : 'Yggdrasill Academy';

  final checksByItem =
      await HomeworkAssignmentStore.instance.loadChecksForStudent(studentId);
  final assignmentsByItem = await HomeworkAssignmentStore.instance
      .loadAssignmentsForStudent(studentId);
  final latestAssignmentByItem = <String, HomeworkAssignmentBrief>{};
  for (final entry in assignmentsByItem.entries) {
    final sorted = List<HomeworkAssignmentBrief>.from(entry.value)
      ..sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
    if (sorted.isNotEmpty) {
      latestAssignmentByItem[entry.key] = sorted.last;
    }
  }

  final allHomeworkItems = HomeworkStore.instance.items(studentId);
  final checkRates = <_CheckRateEntry>[];
  final coveredDueItemIds = <String>{};
  // 오늘 완료되어 보관된 그룹도 포함한다. 보관 그룹을 빼면
  // 숙제 검사 목록이 하위과제마다 한 줄로 갈라진다.
  final groupsForCheckRates = HomeworkStore.instance.groups(
    studentId,
    includeArchived: true,
  );
  for (final group in groupsForCheckRates) {
    final children = HomeworkStore.instance
        .itemsInGroup(studentId, group.id, includeCompleted: true);
    if (children.isEmpty) continue;
    final includedItems = <HomeworkItem>[];
    int groupCount = 0;
    int dueCount = 0;
    int previousProgress = 0;
    int currentProgress = 0;
    bool groupHasRegularDue = false;
    bool groupHasPreDone = false;
    bool groupHasTodayCheckItem = false;
    DateTime? earliestAssigned;
    DateTime? groupDueDate;
    DateTime? groupCheckedAt;
    String? groupOutcome;
    String? groupReason;
    String? firstBookAndCourse;
    for (final hw in children) {
      coveredDueItemIds.add(hw.id);
      final dueAssignments = (assignmentsByItem[hw.id] ??
              const <HomeworkAssignmentBrief>[])
          .where(
              (a) => a.dueDate != null && _isSameDay(a.dueDate!, classDateTime))
          .toList()
        ..sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
      final preDone = hw.preDoneProgress ?? 0;
      final checks = checksByItem[hw.id] ?? const <HomeworkAssignmentCheck>[];
      final hasTodayCheck =
          checks.any((c) => _isSameDay(c.checkedAt, classDateTime));
      final hasFirstCheckToday =
          _hasFirstAssignmentCheckOn(checks, classDateTime);
      // 포함 조건: ①오늘 정규 검사예정 ②오늘 검사가 그 배정의 첫 검사
      // (지난 시간 결석분 / 오늘 완료되어 마감정보가 사라진 과제) ③미리 해온(추가검사) 기록.
      // 이미 검사한 배정을 오늘 다시 채점한 과제는 숙제가 아니다.
      if (dueAssignments.isEmpty && !hasFirstCheckToday && preDone <= 0) {
        continue;
      }
      final window = _progressWindowForChecks(checks, classDateTime);
      HomeworkAssignmentBrief? repAssign;
      int itemPrevious;
      int itemCurrent;
      bool itemIsRegular;
      if (dueAssignments.isNotEmpty) {
        dueCount += dueAssignments.length;
        itemIsRegular = dueAssignments.any((a) => !a.isSelfExtra);
        final latestDue = dueAssignments.last;
        repAssign = latestDue;
        itemPrevious = hasTodayCheck
            ? window.previous
            : math.max(window.previous, latestDue.progress);
        itemCurrent = hasTodayCheck
            ? math.max(window.current, latestDue.progress)
            : itemPrevious;
      } else if (hasFirstCheckToday) {
        // 오늘 첫 검사를 했지만 오늘 마감이 아닌 과제: 정규 숙제로 본다(분모 포함).
        groupHasTodayCheckItem = true;
        itemIsRegular = true;
        repAssign = latestAssignmentByItem[hw.id];
        itemPrevious = window.previous;
        itemCurrent = window.current;
      } else {
        // 미리 해온 숙제(아직 정식으로 내주지 않은 추가검사분): 분자에만 포함.
        groupHasPreDone = true;
        itemIsRegular = false;
        repAssign = latestAssignmentByItem[hw.id];
        itemPrevious = window.previous;
        itemCurrent = math.max(window.current, preDone);
      }
      // 확인 검사 없이 오늘 완료 처리된 과제는 100%로 본다
      // (서버 _lesson_record_compute 의 숙제 완료 기준과 같다).
      if (!hasTodayCheck &&
          hw.completedAt != null &&
          _isSameDay(hw.completedAt!, classDateTime)) {
        itemCurrent = math.max(itemCurrent, 100);
      }
      if (itemIsRegular) groupHasRegularDue = true;
      // 내준 날짜/마감 날짜: 가장 이른 내준 시점의 대표 assignment 기준.
      final repAssignedAt = repAssign?.assignedAt ?? hw.preDoneAt;
      if (repAssignedAt != null &&
          (earliestAssigned == null ||
              repAssignedAt.isBefore(earliestAssigned))) {
        earliestAssigned = repAssignedAt;
        groupDueDate = repAssign?.dueDate;
      }
      // 검사일: 오늘 검사 중 가장 늦은 시각.
      for (final c in checks) {
        if (_isSameDay(c.checkedAt, classDateTime)) {
          if (groupCheckedAt == null || c.checkedAt.isAfter(groupCheckedAt)) {
            groupCheckedAt = c.checkedAt;
            groupOutcome = c.outcome;
            groupReason = c.reason;
          }
        }
      }
      if (itemPrevious > previousProgress) {
        previousProgress = itemPrevious;
      }
      if (itemCurrent > currentProgress) {
        currentProgress = itemCurrent;
      }
      includedItems.add(hw);
      final count = hw.count;
      if (count != null && count > 0) groupCount += count;
      firstBookAndCourse ??= _formatBookAndCourseFromHomework(hw);
    }
    if (dueCount <= 0 && !groupHasPreDone && !groupHasTodayCheckItem) continue;
    final pageSummary = homeworkGroupPageSummary(
      includedItems.map(
        (hw) => (page: hw.page, unitMappings: hw.unitMappings),
      ),
    );
    final title = group.title.trim().isNotEmpty
        ? group.title.trim()
        : children.first.title.trim();
    checkRates.add(
      _CheckRateEntry(
        title: title.isEmpty ? '그룹 과제' : title,
        progress: currentProgress,
        previousProgress: previousProgress,
        todayProgress: math.max(0, currentProgress - previousProgress),
        bookAndCourse: firstBookAndCourse ?? '교재 미기재',
        page: pageSummary.isEmpty ? '-' : pageSummary,
        count: groupCount > 0 ? groupCount.toString() : '-',
        assignedAt: earliestAssigned,
        dueDate: groupDueDate,
        checkedAt: groupCheckedAt,
        outcome: groupOutcome,
        reason: groupReason,
        isExtra: !groupHasRegularDue,
      ),
    );
  }
  for (final entry in assignmentsByItem.entries) {
    if (coveredDueItemIds.contains(entry.key)) continue;
    final dueAssignments = entry.value
        .where(
            (a) => a.dueDate != null && _isSameDay(a.dueDate!, classDateTime))
        .toList()
      ..sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
    final checks = checksByItem[entry.key] ?? const <HomeworkAssignmentCheck>[];
    final hasTodayCheck =
        checks.any((c) => _isSameDay(c.checkedAt, classDateTime));
    // 오늘 마감이거나, 오늘 검사가 그 배정의 첫 검사면 포함.
    if (dueAssignments.isEmpty &&
        !_hasFirstAssignmentCheckOn(checks, classDateTime)) {
      continue;
    }
    final HomeworkAssignmentBrief? repAssign = dueAssignments.isNotEmpty
        ? dueAssignments.last
        : latestAssignmentByItem[entry.key];
    final hw = HomeworkStore.instance.getById(studentId, entry.key);
    final title =
        (hw?.title.trim().isNotEmpty ?? false) ? hw!.title.trim() : '과제';
    final bookAndCourse =
        hw == null ? '교재 미기재' : _formatBookAndCourseFromHomework(hw);
    final page = hw == null
        ? ''
        : homeworkGroupPageSummary(
            <({String? page, List<Map<String, dynamic>>? unitMappings})>[
              (page: hw.page, unitMappings: hw.unitMappings),
            ],
          );
    final hwCount = hw?.count;
    final count = (hwCount != null && hwCount > 0) ? hwCount.toString() : '-';
    final window = _progressWindowForChecks(checks, classDateTime);
    final int latestDueProgress =
        dueAssignments.isEmpty ? 0 : dueAssignments.last.progress;
    final previousProgress = hasTodayCheck
        ? window.previous
        : math.max(window.previous, latestDueProgress);
    final completedTodayWithoutCheck = !hasTodayCheck &&
        hw?.completedAt != null &&
        _isSameDay(hw!.completedAt!, classDateTime);
    final currentProgress = hasTodayCheck
        ? math.max(window.current, latestDueProgress)
        : completedTodayWithoutCheck
            ? math.max(previousProgress, 100)
            : previousProgress;
    DateTime? checkedAt;
    String? checkOutcome;
    String? checkReason;
    for (final c in checks) {
      if (_isSameDay(c.checkedAt, classDateTime)) {
        if (checkedAt == null || c.checkedAt.isAfter(checkedAt)) {
          checkedAt = c.checkedAt;
          checkOutcome = c.outcome;
          checkReason = c.reason;
        }
      }
    }
    final bool isExtraEntry = dueAssignments.isNotEmpty
        ? dueAssignments.every((a) => a.isSelfExtra)
        : false;
    checkRates.add(
      _CheckRateEntry(
        title: title,
        progress: currentProgress,
        previousProgress: previousProgress,
        todayProgress: math.max(0, currentProgress - previousProgress),
        bookAndCourse: bookAndCourse,
        page: page.isEmpty ? '-' : page,
        count: count,
        assignedAt: repAssign?.assignedAt,
        dueDate: repAssign?.dueDate,
        checkedAt: checkedAt,
        outcome: checkOutcome,
        reason: checkReason,
        isExtra: isExtraEntry,
      ),
    );
  }
  if (checkRates.isEmpty) {
    checkRates.add(
      const _CheckRateEntry(
        title: '숙제 없음',
        progress: null,
        previousProgress: null,
        todayProgress: null,
        bookAndCourse: '',
        page: '-',
        count: '-',
        assignedAt: null,
      ),
    );
  }

  final matchedRecord = _findTodoSheetAttendanceRecord(
    studentId: studentId,
    classDateTime: classDateTime,
  );
  final resolvedArrival = arrivalTime ?? matchedRecord?.arrivalTime;
  final todayLearningMsByGroup =
      await _computeTodayLearningMsByGroupFromPhaseEvents(
    studentId: studentId,
    classDateTime: classDateTime,
    departureTime: departureTime,
    arrivalTime: resolvedArrival,
    allItems: allHomeworkItems,
  );

  final classWorkEntries = <_ClassWorkEntry>[];
  final coveredDonutItemIds = <String>{};
  final donutGroups = HomeworkStore.instance.groups(studentId);
  for (final group in donutGroups) {
    final children = HomeworkStore.instance
        .itemsInGroup(studentId, group.id, includeCompleted: true);
    if (children.isEmpty) continue;
    final int groupStudyMs = todayLearningMsByGroup[group.id] ?? 0;
    int groupCheckCount = 0;
    int groupTotalCount = 0;
    bool hasActivity = false;
    DateTime? earliestAssigned;
    String? firstBookAndCourse;
    for (final hw in children) {
      coveredDonutItemIds.add(hw.id);
      if (_hasTodayHomeworkActivity(hw, classDateTime)) hasActivity = true;
      final todayChecks = (checksByItem[hw.id] ?? [])
          .where((c) => _isSameDay(c.checkedAt, classDateTime))
          .length;
      groupCheckCount += todayChecks;
      final hwCount = hw.count;
      if (hwCount != null && hwCount > 0) groupTotalCount += hwCount;
      firstBookAndCourse ??= _formatBookAndCourseFromHomework(hw);
      final assignedAt = latestAssignmentByItem[hw.id]?.assignedAt;
      if (assignedAt != null &&
          (earliestAssigned == null || assignedAt.isBefore(earliestAssigned))) {
        earliestAssigned = assignedAt;
      }
    }
    if (!hasActivity && groupStudyMs <= 0) continue;
    final groupTitle = group.title.trim().isNotEmpty
        ? group.title.trim()
        : children.first.title.trim();
    final mergedGroupPages = mergeHomeworkItemPageRanges(
      children.map(
        (hw) => (page: hw.page, unitMappings: hw.unitMappings),
      ),
    );
    final subs = <_SubWorkEntry>[];
    for (final hw in children) {
      final t = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
      // 개념원리 하위과제는 page 를 비우므로 문항수만 보이게 '-' 유지.
      final pg = (hw.page ?? '').trim();
      final ct =
          (hw.count != null && hw.count! > 0) ? hw.count.toString() : '-';
      subs.add(_SubWorkEntry(title: t, page: pg.isEmpty ? '-' : pg, count: ct));
    }
    final totals = _groupCheckPassTotals(
      group: group,
      children: children,
      departureTime: departureTime,
    );
    classWorkEntries.add(
      _ClassWorkEntry(
        title: groupTitle,
        bookAndCourse: firstBookAndCourse ?? '',
        page: mergedGroupPages.isEmpty ? '-' : mergedGroupPages,
        count: groupTotalCount > 0 ? groupTotalCount.toString() : '-',
        assignedAt: earliestAssigned,
        studyMs: groupStudyMs,
        todayCheckCount: groupCheckCount,
        totalCheckCount: totals.checks,
        passed: totals.passed,
        totalAccumulatedMs: totals.totalMs,
        subEntries: subs,
      ),
    );
  }

  // 완료되어 그룹 링크가 사라진 과제라도, 오늘 수행시간이 있으면 수업 요약에 반영한다.
  // (총 학습시간 합계는 이미 이런 과제를 포함하므로, 도넛 세그먼트/요약 줄과 일치시킨다.)
  final donutLeftoverCompleted = HomeworkStore.instance
      .items(studentId)
      .where((e) =>
          e.completedAt != null &&
          _isSameDay(e.completedAt!, classDateTime) &&
          !coveredDonutItemIds.contains(e.id) &&
          (todayLearningMsByGroup[_learningGroupKeyOf(e)] ?? 0) > 0)
      .toList(growable: false);
  if (donutLeftoverCompleted.isNotEmpty) {
    final leftoverByGroupKey = <String, List<HomeworkItem>>{};
    for (final hw in donutLeftoverCompleted) {
      // 오늘 모두 끝나 보관(archived)된 그룹도 그룹 단위로 묶는다.
      final matchedGroupId =
          (HomeworkStore.instance.groupIdOfItem(hw.id) ?? '').trim();
      final key = matchedGroupId.isNotEmpty ? matchedGroupId : hw.id;
      leftoverByGroupKey.putIfAbsent(key, () => <HomeworkItem>[]).add(hw);
    }
    for (final entry in leftoverByGroupKey.entries) {
      final items = entry.value;
      final int groupStudyMs = todayLearningMsByGroup[entry.key] ?? 0;
      int groupCheckCount = 0;
      int groupTotalCount = 0;
      DateTime? earliestAssigned;
      final groupPages = <String>[];
      String? firstBookAndCourse;
      final subs = <_SubWorkEntry>[];
      for (final hw in items) {
        groupCheckCount += (checksByItem[hw.id] ?? const [])
            .where((c) => _isSameDay(c.checkedAt, classDateTime))
            .length;
        final hwCount = hw.count;
        if (hwCount != null && hwCount > 0) groupTotalCount += hwCount;
        final p = (hw.page ?? '').trim();
        if (p.isNotEmpty) groupPages.add(p);
        firstBookAndCourse ??= _formatBookAndCourseFromHomework(hw);
        final assignedAt = latestAssignmentByItem[hw.id]?.assignedAt;
        if (assignedAt != null &&
            (earliestAssigned == null ||
                assignedAt.isBefore(earliestAssigned))) {
          earliestAssigned = assignedAt;
        }
        final t = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
        final ct =
            (hw.count != null && hw.count! > 0) ? hw.count.toString() : '-';
        subs.add(_SubWorkEntry(title: t, page: p.isEmpty ? '-' : p, count: ct));
      }
      if (groupStudyMs <= 0) continue;
      final groupObj = HomeworkStore.instance.groupById(studentId, entry.key);
      final groupTitle = groupObj != null && groupObj.title.trim().isNotEmpty
          ? groupObj.title.trim()
          : items.first.title.trim();
      final groupChildren = groupObj == null
          ? items
          : HomeworkStore.instance
              .itemsInGroup(studentId, groupObj.id, includeCompleted: true);
      final totals = _groupCheckPassTotals(
        group: groupObj,
        children: groupChildren.isEmpty ? items : groupChildren,
        departureTime: departureTime,
      );
      classWorkEntries.add(
        _ClassWorkEntry(
          title: groupTitle,
          bookAndCourse: firstBookAndCourse ?? '',
          page: groupPages.isEmpty ? '-' : groupPages.join(', '),
          count: groupTotalCount > 0 ? groupTotalCount.toString() : '-',
          assignedAt: earliestAssigned,
          studyMs: groupStudyMs,
          todayCheckCount: groupCheckCount,
          totalCheckCount: totals.checks,
          passed: totals.passed,
          totalAccumulatedMs: totals.totalMs,
          subEntries: subs,
        ),
      );
    }
  }

  classWorkEntries.sort((a, b) {
    final left = a.assignedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final right = b.assignedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return right.compareTo(left);
  });

  final completedEntries = <_TodoListEntry>[];
  final completedItems = HomeworkStore.instance
      .items(studentId)
      .where((e) =>
          e.completedAt != null && _isSameDay(e.completedAt!, classDateTime))
      .toList()
    ..sort((a, b) => (a.completedAt ?? DateTime(1900))
        .compareTo(b.completedAt ?? DateTime(1900)));
  for (final hw in completedItems) {
    final resolvedPage = homeworkItemPageRangeText(
      page: hw.page,
      unitMappings: hw.unitMappings,
    );
    final pageText = resolvedPage.isEmpty ? 'p.-' : 'p.$resolvedPage';
    final attempts = hw.checkCount <= 0 ? 1 : hw.checkCount;
    completedEntries.add(
      _TodoListEntry(
        primary: '• ${_extractBookNameFromHomework(hw)} · $pageText',
        secondary:
            '  ${_formatDateTime(hw.createdAt).isNotEmpty ? "출제 ${_formatDateTime(hw.createdAt)} · " : ""}${attempts}번째 검사 통과',
      ),
    );
  }
  if (completedEntries.isEmpty) {
    completedEntries.add(const _TodoListEntry(primary: '• 숙제 없음'));
  }

  final completedSummaries = <_CompletedSummaryEntry>[];
  if (completedItems.isNotEmpty) {
    final completedByGroup = <String, List<HomeworkItem>>{};
    for (final hw in completedItems) {
      final groups = HomeworkStore.instance.groups(studentId);
      String? matchedGroupId;
      for (final g in groups) {
        final children = HomeworkStore.instance
            .itemsInGroup(studentId, g.id, includeCompleted: true);
        if (children.any((c) => c.id == hw.id)) {
          matchedGroupId = g.id;
          break;
        }
      }
      final key = matchedGroupId ?? hw.id;
      completedByGroup.putIfAbsent(key, () => <HomeworkItem>[]).add(hw);
    }
    for (final entry in completedByGroup.entries) {
      final items = entry.value;
      final first = items.first;
      final representative = items.firstWhere(
        (it) =>
            (it.bookId ?? '').trim().isNotEmpty &&
            (it.gradeLabel ?? '').trim().isNotEmpty,
        orElse: () => first,
      );
      var bookId = (representative.bookId ?? '').trim();
      var gradeLabel = (representative.gradeLabel ?? '').trim();
      final flowId = (representative.flowId ?? '').trim();
      if ((bookId.isEmpty || gradeLabel.isEmpty) && flowId.isNotEmpty) {
        try {
          final links =
              await DataManager.instance.loadFlowTextbookLinks(flowId);
          if (links.isNotEmpty) {
            final selected = links.first;
            if (bookId.isEmpty) {
              bookId = '${selected['book_id'] ?? ''}'.trim();
            }
            if (gradeLabel.isEmpty) {
              gradeLabel = '${selected['grade_label'] ?? ''}'.trim();
            }
          }
        } catch (_) {}
      }
      final groupObj = HomeworkStore.instance.groupById(studentId, entry.key);
      final gTitle = groupObj != null && groupObj.title.trim().isNotEmpty
          ? groupObj.title.trim()
          : first.title.trim();
      final bookCourse = _formatBookAndCourseFromHomework(representative);
      final totalMs = <String>{for (final e in items) _learningGroupKeyOf(e)}
          .fold<int>(0, (s, key) => s + (todayLearningMsByGroup[key] ?? 0));
      final assignmentRoundIndexes = <int>{};
      final assignmentIdsFallback = <String>{};
      for (final item in items) {
        final briefs =
            assignmentsByItem[item.id] ?? const <HomeworkAssignmentBrief>[];
        for (final brief in briefs) {
          if (brief.repeatIndex > 0) {
            assignmentRoundIndexes.add(brief.repeatIndex);
          }
          final assignmentId = brief.id.trim();
          if (assignmentId.isNotEmpty) {
            assignmentIdsFallback.add(assignmentId);
          }
        }
      }
      final assignmentCount = assignmentRoundIndexes.isNotEmpty
          ? assignmentRoundIndexes.length
          : assignmentIdsFallback.length;
      final totalChecks = items.fold<int>(0, (s, e) => s + e.checkCount);
      int previousProgress = 0;
      int currentProgress = 0;
      for (final item in items) {
        final window = _progressWindowForChecks(
          checksByItem[item.id] ?? const <HomeworkAssignmentCheck>[],
          classDateTime,
        );
        if (window.previous > previousProgress) {
          previousProgress = window.previous;
        }
        if (window.current > currentProgress) {
          currentProgress = window.current;
        }
      }
      double progressPct = 0;
      if (bookId.isNotEmpty && gradeLabel.isNotEmpty) {
        try {
          final meta = await ResourceService.instance
              .loadTextbookMetadataPayload(
                  bookId: bookId, gradeLabel: gradeLabel);
          if (meta != null) {
            final payload = meta['payload'];
            final totalPages = _countTotalPagesFromPayload(payload);
            if (totalPages > 0) {
              final donePagesInCompletedGroup = <int>{};
              for (final it in items) {
                _addPagesFromItem(donePagesInCompletedGroup, it);
              }
              progressPct =
                  ((donePagesInCompletedGroup.length / totalPages) * 100)
                      .clamp(0.0, 100.0)
                      .toDouble();
              if (currentProgress <= 0 && progressPct > 0) {
                currentProgress = progressPct.round();
              }
            }
          }
        } catch (_) {}
      }
      final previousProgressPct =
          math.min(previousProgress, currentProgress).clamp(0, 150).toDouble();
      final totalProgressPct = currentProgress.clamp(0, 150).toDouble();
      final todayProgressPct = math
          .max(0, currentProgress - previousProgress)
          .clamp(0, 150)
          .toDouble();
      completedSummaries.add(_CompletedSummaryEntry(
        groupTitle: gTitle,
        bookAndCourse: bookCourse,
        totalMs: totalMs,
        assignmentCount: assignmentCount,
        checkCount: totalChecks,
        progressPct: todayProgressPct > 0 ? todayProgressPct : progressPct,
        previousProgressPct: previousProgressPct,
        totalProgressPct: totalProgressPct,
        etaText: null,
      ));
    }
  }

  // 계획에서 '오늘'로 둔 과제는 하원 선택 목록에서 제외되고 하원 확정 RPC가
  // 자동으로 숙제로 넘긴다. 그 항목도 오늘 내준 숙제이므로 알림장에 함께 찍는다.
  final printableHomeworkIds = <String>[];
  final printedHomeworkIds = <String>{};
  void addPrintableHomeworkId(String rawId) {
    final id = rawId.trim();
    if (id.isEmpty || !printedHomeworkIds.add(id)) return;
    final hw = HomeworkStore.instance.getById(studentId, id);
    if (hw == null || hw.status == HomeworkStatus.completed) return;
    printableHomeworkIds.add(id);
  }

  for (final id in selectedHomeworkIds) {
    addPrintableHomeworkId(id);
  }
  for (final id in additionalHomeworkIds ?? const <String>[]) {
    addPrintableHomeworkId(id);
  }
  for (final entry in assignmentsByItem.entries) {
    if (printedHomeworkIds.contains(entry.key)) continue;
    final assignedToday = entry.value.any((assignment) {
      final isActive = assignment.status == 'assigned' ||
          assignment.status == 'in_progress';
      if (!isActive) return false;
      // 기존 assignment를 재사용한 자동숙제(assigned_at이 과거)도 포함.
      if (assignment.note == '__session_plan_departure__') return true;
      return _isSameDay(assignment.assignedAt, departureTime) ||
          _isSameDay(assignment.assignedAt, classDateTime);
    });
    final deferredToday =
        (checksByItem[entry.key] ?? const <HomeworkAssignmentCheck>[]).any(
      (check) =>
          (_isSameDay(check.checkedAt, departureTime) ||
              _isSameDay(check.checkedAt, classDateTime)) &&
          (check.outcome == 'not_done' || check.outcome == 'left_behind'),
    );
    if (!assignedToday && !deferredToday) continue;
    addPrintableHomeworkId(entry.key);
  }

  // 숙제 리스트는 하위과제(아이템)가 아니라 그룹 과제 단위로 표시한다.
  final todoEntries = <_TodoListEntry>[];
  final todoGroupOrder = <String>[];
  final todoGroupChildren = <String, List<HomeworkItem>>{};
  for (final id in printableHomeworkIds) {
    final hw = HomeworkStore.instance.getById(studentId, id);
    if (hw == null) continue;
    final groupId = (HomeworkStore.instance.groupIdOfItem(id) ?? '').trim();
    final key = groupId.isNotEmpty ? groupId : id;
    if (!todoGroupChildren.containsKey(key)) {
      todoGroupOrder.add(key);
      todoGroupChildren[key] = <HomeworkItem>[];
    }
    todoGroupChildren[key]!.add(hw);
  }
  for (final key in todoGroupOrder) {
    final children = todoGroupChildren[key] ?? const <HomeworkItem>[];
    if (children.isEmpty) continue;
    final group = HomeworkStore.instance.groupById(studentId, key);
    final groupTitle = (() {
      final fromGroup = (group?.title ?? '').trim();
      if (fromGroup.isNotEmpty) return fromGroup;
      final fromItem = children.first.title.trim();
      return fromItem.isEmpty ? '(제목 없음)' : fromItem;
    })();
    // 학습앱 그룹 카드는 진행 중인 첫 하위과제로 1행을 만든다.
    final cardSource = (group == null
            ? null
            : HomeworkStore.instance
                .itemsInGroup(studentId, group.id)
                .firstOrNull) ??
        children.first;
    final bookAndCourse = homeworkCardFirstLine(cardSource);
    int totalCount = 0;
    final memos = <String>[];
    DateTime? earliestAssigned;
    for (final hw in children) {
      totalCount += homeworkItemProblemCount(
        count: hw.count,
        unitMappings: hw.unitMappings,
      );
      final memo = (hw.memo ?? '').trim();
      if (memo.isNotEmpty && !memos.contains(memo)) memos.add(memo);
      final assignedAt = latestAssignmentByItem[hw.id]?.assignedAt;
      if (assignedAt != null &&
          (earliestAssigned == null || assignedAt.isBefore(earliestAssigned))) {
        earliestAssigned = assignedAt;
      }
    }
    final mergedPages = homeworkGroupPageSummary(
      children.map(
        (hw) => (page: hw.page, unitMappings: hw.unitMappings),
      ),
    );
    final bookText =
        bookAndCourse.trim().isEmpty ? '-' : bookAndCourse.trim();
    final assignedAt = earliestAssigned ?? classDateTime;
    final assignedDateText = _formatMonthDay(assignedAt);
    final countText = totalCount > 0 ? totalCount.toString() : '-';
    final details = [
      _formatPageTextCompact(mergedPages.isEmpty ? '-' : mergedPages),
      _formatCountText(countText),
    ].join(' · ');
    final memoText = memos.join(', ');
    final estimateLabel =
        _formatEstimatedDurationLabel(_groupEstimatedMinutes(children));
    todoEntries.add(
      _TodoListEntry(
        primary: '□ $bookText',
        secondary: groupTitle,
        tertiary: details,
        bookTitle: bookText,
        rightPrimary: assignedDateText.isEmpty ? null : assignedDateText,
        rightSecondary: estimateLabel.isEmpty ? null : estimateLabel,
        rightTertiary: memoText.isEmpty ? null : memoText,
      ),
    );
  }
  final behaviorTodoEntries = await _buildBehaviorTodoEntries(
    studentId: studentId,
    classDateTime: classDateTime,
    selectedBehaviorIds: selectedBehaviorIds,
    irregularBehaviorCounts: irregularBehaviorCounts,
    dueDate: dueDate,
  );
  if (todoEntries.isEmpty) {
    todoEntries.add(const _TodoListEntry(primary: '• 숙제 없음'));
  }

  final rawLearningMs = todayLearningMsByGroup.values
      .fold<int>(0, (s, ms) => s + ms)
      .clamp(0, 1000 * 60 * 60 * 24)
      .toInt();

  final resolvedClassName = (() {
    String normalize(String raw) {
      final v = raw.trim();
      if (v.isEmpty) return '';
      if (v == '수업' || v == '정규수업' || v == '정규 수업') {
        return '정규 수업';
      }
      return v;
    }

    final explicit = normalize(className ?? '');
    if (explicit.isNotEmpty) return explicit;
    final fromRecord = normalize(matchedRecord?.className ?? '');
    if (fromRecord.isNotEmpty) return fromRecord;
    return '정규 수업';
  })();
  final resolvedClassEnd = classEndTime ?? matchedRecord?.classEndTime;
  final explicitSetId = (setId ?? '').trim();
  final resolvedSetId = explicitSetId.isNotEmpty
      ? explicitSetId
      : (matchedRecord?.setId ?? '').trim();
  final lessonAttendanceId = (matchedRecord?.id ?? '').trim();
  final lessonRecord = lessonAttendanceId.isEmpty
      ? null
      : await LessonRecordService.instance.fetchLive(lessonAttendanceId);
  final classWindowMs = _computeClassWindowMs(
    classDateTime: classDateTime,
    departureTime: departureTime,
    arrivalTime: resolvedArrival,
  );
  final learningMs = classWindowMs > 0
      ? math.min(rawLearningMs, classWindowMs)
      : rawLearningMs;
  final normalizedCompletedSummaries = classWindowMs <= 0
      ? completedSummaries
      : completedSummaries
          .map(
            (entry) => _CompletedSummaryEntry(
              groupTitle: entry.groupTitle,
              bookAndCourse: entry.bookAndCourse,
              totalMs: math.min(entry.totalMs, classWindowMs),
              assignmentCount: entry.assignmentCount,
              checkCount: entry.checkCount,
              progressPct: entry.progressPct,
              previousProgressPct: entry.previousProgressPct,
              totalProgressPct: entry.totalProgressPct,
              etaText: entry.etaText,
            ),
          )
          .toList(growable: false);

  return _TodoSheetPayload(
    academyName: academyName,
    academyLogo: settings.logo,
    studentName: studentName,
    classDateTime: classDateTime,
    dueDate: dueDate,
    arrivalTime: resolvedArrival,
    departureTime: departureTime,
    className: resolvedClassName,
    classTimeText: _formatClassTimeRange(classDateTime, resolvedClassEnd),
    learningTimeText: _formatDurationKorean(learningMs),
    learningMs: learningMs,
    checkRates: checkRates,
    completedSummaries: normalizedCompletedSummaries,
    classWorkEntries: classWorkEntries,
    completedEntries: completedEntries,
    todoEntries: todoEntries,
    behaviorEntries: behaviorTodoEntries,
    behaviorFeedback: _buildBehaviorFeedback(
      studentId: studentId,
      classDateTime: classDateTime,
      setId: resolvedSetId,
    ),
    lessonRecord: lessonRecord,
    specialNotes: _buildSpecialNotes(
      studentId: studentId,
      classDateTime: classDateTime,
      arrivalTime: resolvedArrival,
    ),
  );
}

Future<List<_TodoListEntry>> _buildBehaviorTodoEntries({
  required String studentId,
  required DateTime classDateTime,
  List<String>? selectedBehaviorIds,
  Map<String, int>? irregularBehaviorCounts,
  DateTime? dueDate,
}) async {
  try {
    final Set<String>? selectedIdSet =
        selectedBehaviorIds == null ? null : selectedBehaviorIds.toSet();
    final Map<String, int> irregularCounts =
        irregularBehaviorCounts ?? const <String, int>{};
    final assignments = await StudentBehaviorAssignmentStore.instance
        .loadForStudent(studentId, force: true);
    final filtered = assignments.where((e) {
      if (selectedIdSet == null) return true;
      return selectedIdSet.contains(e.id);
    }).toList()
      ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
    if (filtered.isEmpty) return const <_TodoListEntry>[];

    final DateTime startDate =
        DateTime(classDateTime.year, classDateTime.month, classDateTime.day)
            .add(const Duration(days: 1));
    final DateTime? endDate = dueDate == null
        ? null
        : DateTime(dueDate.year, dueDate.month, dueDate.day);

    final out = <_TodoListEntry>[];
    for (final behavior in filtered) {
      if (behavior.isIrregular) {
        final int count =
            (irregularCounts[behavior.id] ?? 0).clamp(0, 20).toInt();
        if (count <= 0) continue;
        final int level = behavior.safeSelectedLevelIndex + 1;
        final String levelText = behavior.selectedLevelText.trim();
        for (int i = 0; i < count; i++) {
          out.add(
            _TodoListEntry(
              primary: '□ ${behavior.name} · lv.$level',
              secondary: levelText.isEmpty
                  ? '  비정기 ${i + 1}회'
                  : '  비정기 ${i + 1}회 · $levelText',
            ),
          );
        }
        continue;
      }
      if (endDate == null) continue;
      if (endDate.isBefore(startDate)) continue;
      for (DateTime day = startDate;
          !day.isAfter(endDate);
          day = day.add(const Duration(days: 1))) {
        final int dayOffset = day.difference(startDate).inDays;
        final int repeat = behavior.repeatDays.clamp(1, 3650).toInt();
        if (dayOffset % repeat != 0) continue;
        final int level = behavior.safeSelectedLevelIndex + 1;
        final String levelText = behavior.selectedLevelText.trim();
        out.add(
          _TodoListEntry(
            primary: '□ ${behavior.name} · lv.$level',
            secondary: levelText.isEmpty
                ? '  ${_formatMonthDay(day)}'
                : '  ${_formatMonthDay(day)} · $levelText',
          ),
        );
      }
    }
    return out;
  } catch (e, st) {
    // ignore: avoid_print
    print('[HomeworkTodo][BehaviorTodo] $e\n$st');
    return const <_TodoListEntry>[];
  }
}

Future<sf.PdfFont> _loadTodoPdfFont(
  double size, {
  bool bold = false,
}) async {
  if (Platform.isWindows) {
    final candidates = <String>[
      if (bold) r'C:\Windows\Fonts\malgunbd.ttf',
      r'C:\Windows\Fonts\malgun.ttf',
      if (!bold) r'C:\Windows\Fonts\malgunbd.ttf',
    ];
    for (final path in candidates) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        return sf.PdfTrueTypeFont(
          bytes,
          size,
          style: bold ? sf.PdfFontStyle.bold : sf.PdfFontStyle.regular,
        );
      } catch (_) {}
    }
  }
  return sf.PdfStandardFont(
    sf.PdfFontFamily.helvetica,
    size,
    style: bold ? sf.PdfFontStyle.bold : sf.PdfFontStyle.regular,
  );
}

final Map<String, Uint8List?> _todoEmojiBytesCache = <String, Uint8List?>{};

Future<sf.PdfBitmap?> _loadTodoEmojiBitmap(String assetPath) async {
  if (!_todoEmojiBytesCache.containsKey(assetPath)) {
    try {
      final data = await rootBundle.load(assetPath);
      _todoEmojiBytesCache[assetPath] = data.buffer.asUint8List();
    } catch (_) {
      _todoEmojiBytesCache[assetPath] = null;
    }
  }
  final bytes = _todoEmojiBytesCache[assetPath];
  if (bytes == null || bytes.isEmpty) return null;
  try {
    return sf.PdfBitmap(bytes);
  } catch (_) {
    return null;
  }
}

/// 오늘 검사예정 숙제의 (오늘 추가 퍼센트 합)/(남았던 퍼센트 합) 비율(%)에 따라
/// 표시할 이모지 에셋 경로와 문구를 반환한다.
({String asset, String label, bool fire}) _todoCheckMoodFor(int ratioPct) {
  if (ratioPct <= 0) {
    return (asset: 'assets/emoji/emoji_angry.png', label: '안함', fire: false);
  }
  if (ratioPct <= 15) {
    return (
      asset: 'assets/emoji/emoji_distressed.png',
      label: '거의 안함',
      fire: false
    );
  }
  if (ratioPct <= 40) {
    return (
      asset: 'assets/emoji/emoji_crying.png',
      label: '많이 덜함',
      fire: false
    );
  }
  if (ratioPct <= 60) {
    return (asset: 'assets/emoji/emoji_neutral.png', label: '덜함', fire: false);
  }
  if (ratioPct <= 85) {
    return (asset: 'assets/emoji/emoji_smile.png', label: '조금 덜함', fire: false);
  }
  if (ratioPct <= 100) {
    return (asset: 'assets/emoji/emoji_grin.png', label: '다함', fire: false);
  }
  return (asset: 'assets/emoji/emoji_cool.png', label: '추가 학습까지', fire: true);
}

Future<String> _buildHomeworkTodoPdf({
  required _TodoSheetPayload payload,
}) async {
  final design = await loadTodoSheetDesign();
  final bytes = design == TodoSheetDesign.refined
      ? await _renderTodoSheetRefined(payload)
      : await _renderTodoSheetClassic(payload);
  final dir = await getTemporaryDirectory();
  final outPath = p.join(
    dir.path,
    'homework_todo_${DateTime.now().millisecondsSinceEpoch}.pdf',
  );
  await File(outPath).writeAsBytes(bytes, flush: true);
  return outPath;
}

Future<List<int>> _renderTodoSheetClassic(_TodoSheetPayload payload) async {
  final doc = sf.PdfDocument();
  doc.pageSettings.orientation = sf.PdfPageOrientation.portrait;
  doc.pageSettings.margins.all = 18;
  // 상단 여백 0. 본문 높이가 8 늘어 접는 선은 4 내려가므로 숙제 리스트에서 되돌린다.
  doc.pageSettings.margins.top = 0;
  final page = doc.pages.add();
  final size = page.getClientSize();
  final graphics = page.graphics;
  final titleFont = await _loadTodoPdfFont(16, bold: true);
  final sectionFont = await _loadTodoPdfFont(12.2, bold: true);
  final bodyFont = await _loadTodoPdfFont(10.2);
  final bodyBoldFont = await _loadTodoPdfFont(10.2, bold: true);
  final subFont = await _loadTodoPdfFont(9.2);
  final labelFont = await _loadTodoPdfFont(9.8);
  final valueFont = await _loadTodoPdfFont(11.2, bold: true);
  final textBrush = sf.PdfSolidBrush(sf.PdfColor(28, 28, 28));
  final subBrush = sf.PdfSolidBrush(sf.PdfColor(95, 95, 95));
  const textColor = Color(0xFF1C1C1C);
  const subColor = Color(0xFF5F5F5F);

  /// 수식이 있으면 학습 화면과 같은 조판으로, 없으면 PDF 글꼴로 그린다.
  Future<void> drawLine(
    sf.PdfGraphics g,
    String text,
    sf.PdfFont font, {
    required double fontSize,
    required bool bold,
    required sf.PdfBrush brush,
    required Color color,
    required Rect bounds,
    sf.PdfStringFormat? format,
  }) async {
    final normalized = normalizeTodoSheetMath(text);
    if (!todoSheetMathNeedsPaint(normalized)) {
      g.drawString(text, font, brush: brush, bounds: bounds, format: format);
      return;
    }
    final shot = await rasterizeTodoSheetMath(
      text: normalized,
      fontSize: fontSize,
      bold: bold,
      color: color,
      maxWidth: bounds.width,
    );
    if (shot == null) {
      g.drawString(text, font, brush: brush, bounds: bounds, format: format);
      return;
    }
    // 분수는 글자보다 키가 커서 줄 칸을 조금 넘는다. 위아래 줄 간 여백까지만 허용하고,
    // 그보다 크면 줄 전체를 비율대로 줄인다.
    final maxH = bounds.height + 3;
    final scale = math.min(
      1.0,
      math.min(maxH / shot.height, bounds.width / shot.width),
    );
    final w = shot.width * scale;
    final h = shot.height * scale;
    final top = bounds.top + (bounds.height - h) / 2;
    final alignRight = format?.alignment == sf.PdfTextAlignment.right;
    final x = alignRight ? bounds.right - w : bounds.left;
    g.drawImage(sf.PdfBitmap(shot.bytes), Rect.fromLTWH(x, top, w, h));
  }
  final linePen = sf.PdfPen(sf.PdfColor(178, 178, 178), width: 1.05);
  final weakLinePen = sf.PdfPen(sf.PdfColor(222, 222, 222), width: 0.6);
  const overflowLineH = 14.0;
  final overflowBrush = sf.PdfSolidBrush(sf.PdfColor(150, 150, 150));
  void drawOverflow(
    sf.PdfGraphics g,
    double x,
    double y,
    double w,
    int count,
  ) {
    g.drawString(
      '외 $count개',
      subFont,
      brush: overflowBrush,
      bounds: Rect.fromLTWH(x, y, w, overflowLineH),
    );
  }

  final left = 10.0;
  final right = size.width - 10;
  final contentWidth = right - left;
  // 1페이지 학원명 글자 상단을 용지 끝에 붙인다. 2페이지는 기존 본문 여백을 유지한다.
  final top = -5.0;
  final page2Top = 6.0;
  final bottom = size.height - 6;

  void drawLabelValue({
    required String label,
    required String value,
    required double x,
    required double y,
    required double maxWidth,
    double valueGap = 4,
  }) {
    if (value.trim().isEmpty) return;
    graphics.drawString(
      label,
      labelFont,
      brush: subBrush,
      bounds: Rect.fromLTWH(x, y, maxWidth, 16),
    );
    final lw = labelFont.measureString(label).width;
    final remainingW = maxWidth - lw - valueGap;
    if (remainingW <= 0) return;
    graphics.drawString(
      value,
      valueFont,
      brush: textBrush,
      bounds: Rect.fromLTWH(x + lw + valueGap, y - 1, remainingW, 18),
    );
  }

  const double headerH = 100;
  final headerBottom = top + headerH;
  graphics.drawLine(
      linePen, Offset(left, headerBottom), Offset(right, headerBottom));

  double headerTextX = left + 2;
  const logoBoxW = 44.0;
  const logoBoxH = 44.0;
  final logoBoxY = top + 2;
  final logoCenterY = logoBoxY + logoBoxH / 2;
  final titleBlockY = logoCenterY - 19;
  if (payload.academyLogo != null && payload.academyLogo!.isNotEmpty) {
    try {
      final logo = sf.PdfBitmap(payload.academyLogo!);
      final rawW = logo.width.toDouble();
      final rawH = logo.height.toDouble();
      final scale = math.min(logoBoxW / rawW, logoBoxH / rawH);
      final drawW = rawW * scale;
      final drawH = rawH * scale;
      final drawX = left + 1 + (logoBoxW - drawW) / 2;
      final drawY = logoBoxY + (logoBoxH - drawH) / 2;
      graphics.drawImage(logo, Rect.fromLTWH(drawX, drawY, drawW, drawH));
      headerTextX = left + 52;
    } catch (_) {}
  }
  graphics.drawString(
    payload.academyName,
    titleFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(headerTextX, titleBlockY, right - headerTextX, 22),
  );
  graphics.drawString(
    '학습 리포트',
    bodyFont,
    brush: subBrush,
    bounds:
        Rect.fromLTWH(headerTextX, titleBlockY + 24, right - headerTextX, 16),
  );

  graphics.drawString(
    _formatDate(payload.classDateTime),
    labelFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(right - 130, top + 8, 130, 14),
    format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right),
  );
  graphics.drawString(
    payload.classTimeText,
    labelFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(right - 160, top + 23, 160, 14),
    format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right),
  );

  // 헤더 하단 디바이더는 유지하고 타이틀-정보 간격만 넓힌 배치
  final infoY1 = top + 58;
  final infoY3 = top + 78;
  final metricGap = contentWidth * 0.01;
  final metricW = (contentWidth - metricGap * 2) / 3;
  final leftInfoW = metricW;
  final rightInfoX = left + metricW + metricGap;
  final rightInfoW = right - rightInfoX;

  drawLabelValue(
    label: '학생 ',
    value: payload.studentName,
    x: left,
    y: infoY1,
    maxWidth: leftInfoW,
  );
  final classLabel = '수업 ';
  final classLabelW = labelFont.measureString(classLabel).width;
  graphics.drawString(
    classLabel,
    labelFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(rightInfoX, infoY1, rightInfoW, 16),
  );
  final classNameX = rightInfoX + classLabelW + 4;
  graphics.drawString(
    payload.className,
    valueFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(
        classNameX, infoY1 - 1, rightInfoX + rightInfoW - classNameX, 18),
  );

  drawLabelValue(
    label: '등원 ',
    value: _formatTime(payload.arrivalTime),
    x: left,
    y: infoY3,
    maxWidth: metricW,
  );
  drawLabelValue(
    label: '하원 ',
    value: _formatTime(payload.departureTime),
    x: left + metricW + metricGap,
    y: infoY3,
    maxWidth: metricW,
  );
  drawLabelValue(
    label: '학습시간 ',
    value: payload.learningTimeText,
    x: left + metricW * 2 + metricGap * 2,
    y: infoY3,
    maxWidth: metricW,
  );

  final contentTop = headerBottom + 8;
  final contentBottom = bottom;
  final foldY = size.height / 2;

  final donutEntries = payload.classWorkEntries;
  final totalLearningMs = payload.learningMs;
  final arrMs = payload.arrivalTime?.millisecondsSinceEpoch ?? 0;
  final depMs = payload.departureTime.millisecondsSinceEpoch;
  final stayMs = (arrMs > 0 && depMs > arrMs) ? depMs - arrMs : 0;
  final breakMs = math.max(0, stayMs - totalLearningMs);
  final donutCx = left + 80;
  // 타이틀(약 18) 바로 아래. 도넛·범례를 조금 줄여 학습 기록 칸은 그대로 둔다.
  const donutR = 72.0;
  const donutInnerR = 42.0;
  // '오늘 푼 문제' 제목과 같은 높이에서 도넛·수업 요약 목록이 시작한다.
  final recordTop = contentTop + 30;
  final donutTop = recordTop;
  final donutCy = donutTop + donutR;
  const legendGapFromDonut = 20.0;
  final legendX = donutCx + donutR + legendGapFromDonut;
  final legendTopY = recordTop;
  const legendW = 157.0;
  // 범례 끝과 학습 기록 글자 사이 27 = 이전 18의 1.5배.
  const columnGap = 27.0;
  final legendEnd = legendX + legendW;
  final summaryX = legendEnd + columnGap;
  final summaryDividerX = legendEnd + 12;
  final summaryW = math.max(0.0, right - summaryX - 2);
  final visibleCheckRateCount =
      payload.checkRates.where((e) => e.progress != null).length;

  // ── Page 1: 수업 요약 (Class Summary) + 숙제 검사 내역 ──
  final panelTitleFont = await _loadTodoPdfFont(11.4, bold: true);
  graphics.drawString(
    '수업 요약',
    panelTitleFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(left, contentTop, summaryDividerX - left - 8, 18),
  );
  if (summaryW > 48) {
    graphics.drawString('학습 기록', panelTitleFont,
        brush: textBrush,
        bounds: Rect.fromLTWH(summaryX, contentTop, summaryW, 18));
  }

  final hasDonut = !(donutEntries.isEmpty && totalLearningMs <= 0);
  double legendBottomY = contentTop;
  if (!hasDonut) {
    graphics.drawString(
      '• 오늘 수행 기록 없음',
      bodyFont,
      brush: subBrush,
      bounds: Rect.fromLTWH(left + 4, contentTop + 30, contentWidth - 8, 14),
    );
  } else {
    final palette = [
      sf.PdfColor(76, 175, 80),
      sf.PdfColor(33, 150, 243),
      sf.PdfColor(255, 152, 0),
      sf.PdfColor(156, 39, 176),
      sf.PdfColor(0, 188, 212),
      sf.PdfColor(244, 67, 54),
      sf.PdfColor(121, 85, 72),
      sf.PdfColor(63, 81, 181),
    ];
    final slices = <({
      String label,
      int ms,
      String? checkText,
      String? totalText,
      sf.PdfColor color
    })>[];
    for (int i = 0; i < donutEntries.length; i++) {
      final e = donutEntries[i];
      if (e.studyMs <= 0) continue;
      final checks = e.totalCheckCount;
      final checkText = checks <= 0
          ? (e.passed ? '검사 없이 통과' : '검사 전')
          : (e.passed ? '$checks회 검사 후 통과' : '$checks회 검사 · 진행 중');
      final totalMin = (e.totalAccumulatedMs / 60000).round();
      slices.add((
        label: e.title,
        ms: e.studyMs,
        checkText: checkText,
        totalText: totalMin > 0 ? '총 시간 $totalMin분' : null,
        color: palette[i % palette.length]
      ));
    }
    if (breakMs > 0) {
      slices.add((
        label: '휴식',
        ms: breakMs,
        checkText: null,
        totalText: null,
        color: sf.PdfColor(200, 200, 200)
      ));
    }
    final totalSliceMs = slices.fold<int>(0, (s, e) => s + e.ms);
    if (totalSliceMs > 0) {
      double startAngle = -90;
      for (final slice in slices) {
        final sweep = (slice.ms / totalSliceMs) * 360;
        graphics.drawPie(
          Rect.fromCircle(center: Offset(donutCx, donutCy), radius: donutR),
          startAngle,
          sweep,
          pen: sf.PdfPen(sf.PdfColor(255, 255, 255), width: 1.2),
          brush: sf.PdfSolidBrush(slice.color),
        );
        startAngle += sweep;
      }
      graphics.drawEllipse(
        Rect.fromCircle(center: Offset(donutCx, donutCy), radius: donutInnerR),
        pen: sf.PdfPen(sf.PdfColor(255, 255, 255), width: 0),
        brush: sf.PdfSolidBrush(sf.PdfColor(255, 255, 255)),
      );
      final totalMin = (totalLearningMs / 60000).round();
      final centerText = '$totalMin분';
      final centerFont = await _loadTodoPdfFont(16, bold: true);
      final centerW = centerFont.measureString(centerText).width;
      graphics.drawString(
        centerText,
        centerFont,
        brush: textBrush,
        bounds: Rect.fromLTWH(
            donutCx - centerW / 2, donutCy - 11, centerW + 4, 22),
      );
    }
    final legendFont = await _loadTodoPdfFont(9.4);
    final legendBoldFont = await _loadTodoPdfFont(9.4, bold: true);
    final legendSubFont = await _loadTodoPdfFont(8.2);
    final legendSubSmallFont = await _loadTodoPdfFont(7.4);
    final legendRight =
        sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right);
    double ly = legendTopY;
    // 1줄 색점 오른쪽이 그룹 과제명 시작. 2줄의 좌우 끝도 그 칸과 같다.
    const legendSwatch = 8.0;
    const legendNameGap = 6.0;
    const legendGutter = 2.0;
    const legendTimeW = 44.0;
    final legendNameX = legendX + legendSwatch + legendNameGap;
    final legendRowRight = legendX + legendW - legendGutter;
    final legendRowW = math.max(0.0, legendRowRight - legendNameX);
    final legendNameW =
        math.max(0.0, legendRowW - legendTimeW - legendGutter);
    for (int i = 0; i < slices.length; i++) {
      final slice = slices[i];
      final rowH =
          (slice.checkText != null || slice.totalText != null) ? 34.0 : 24.0;
      final remaining = slices.length - i;
      if (ly + rowH + (remaining > 1 ? overflowLineH : 0) > foldY) {
        drawOverflow(graphics, legendNameX, ly, legendRowW, remaining);
        ly += overflowLineH;
        break;
      }
      graphics.drawRectangle(
        brush: sf.PdfSolidBrush(slice.color),
        bounds: Rect.fromLTWH(legendX, ly + 2, legendSwatch, legendSwatch),
      );
      final mins = (slice.ms / 60000).round();
      final labelText = slice.label;
      final timeText = '$mins분';
      await drawLine(
        graphics,
        labelText,
        legendBoldFont,
        fontSize: 9.4,
        bold: true,
        brush: textBrush,
        color: textColor,
        bounds: Rect.fromLTWH(legendNameX, ly, legendNameW, 14),
      );
      graphics.drawString(timeText, legendFont,
          brush: subBrush,
          bounds: Rect.fromLTWH(
              legendNameX + legendNameW + legendGutter, ly, legendTimeW, 14),
          format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right));
      final checkText = slice.checkText;
      final totalText = slice.totalText;
      if (checkText != null || totalText != null) {
        double widthOf(sf.PdfFont font, String? text) =>
            text == null ? 0.0 : font.measureString(text).width + 2;
        final fits = widthOf(legendSubFont, checkText) +
                widthOf(legendSubFont, totalText) +
                legendGutter <=
            legendRowW;
        final line2Font = fits ? legendSubFont : legendSubSmallFont;
        final totalW =
            math.min(widthOf(line2Font, totalText), legendRowW * 0.55);
        final checkW =
            math.max(0.0, legendRowW - totalW - legendGutter);
        if (checkText != null) {
          graphics.drawString(checkText, line2Font,
              brush: subBrush,
              bounds: Rect.fromLTWH(legendNameX, ly + 14, checkW, 12));
        }
        if (totalText != null) {
          graphics.drawString(totalText, line2Font,
              brush: subBrush,
              bounds: Rect.fromLTWH(
                  legendNameX + checkW + legendGutter, ly + 14, totalW, 12),
              format: legendRight);
        }
        ly += 34;
      } else {
        ly += 24;
      }
    }
    legendBottomY = ly;
  }

  {
    // 도넛 옆 목록은 두 줄 항목 6개까지 특이 사항 위에 둔다.
    // 4개 이하면 도넛 아래 기존 자리, 5·6개면 목록 바로 아래까지 내린다.
    const legendRowPitch = 34.0;
    final notesUnderDonut = donutCy + donutR + 22;
    final notesBelowList = legendBottomY + 14;
    final notesClearOfSix = legendTopY + legendRowPitch * 6 + 14;
    final notesTop = hasDonut
        ? math.max(
            notesUnderDonut,
            math.min(notesBelowList, notesClearOfSix),
          )
        : contentTop + 56;
    final notesW = legendBottomY <= notesTop - 6
        ? summaryDividerX - left - 8
        : legendX - left - 10;
    final notesLimitY = foldY - 8;
    final notesTitleFont = await _loadTodoPdfFont(9.4, bold: true);
    final notesFont = await _loadTodoPdfFont(9.0);
    graphics.drawLine(weakLinePen, Offset(left, notesTop - 8),
        Offset(left + notesW, notesTop - 8));
    graphics.drawString('특이 사항', notesTitleFont,
        brush: textBrush, bounds: Rect.fromLTWH(left, notesTop, notesW, 14));
    double ny = notesTop + 18;
    if (payload.specialNotes.isEmpty) {
      graphics.drawString('특이 사항이 없습니다.', notesFont,
          brush: subBrush, bounds: Rect.fromLTWH(left, ny, notesW, 14));
    } else {
      for (int i = 0; i < payload.specialNotes.length; i++) {
        final note = payload.specialNotes[i];
        final remaining = payload.specialNotes.length - i;
        if (ny + 15 + (remaining > 1 ? overflowLineH : 0) > notesLimitY) {
          drawOverflow(graphics, left, ny, notesW, remaining);
          break;
        }
        graphics.drawString('• $note', notesFont,
            brush: textBrush, bounds: Rect.fromLTWH(left, ny, notesW, 14));
        ny += 15;
      }
    }
  }

  if (summaryW > 48) {
    graphics.drawLine(weakLinePen, Offset(summaryDividerX, contentTop),
        Offset(summaryDividerX, foldY - 8));
    final rightAlign = sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right);
    const heroSize = 26.0;
    const bigSize = 17.0;
    const unitSize = 9.4;
    const emptySize = 10.4;
    final recLabelFont = await _loadTodoPdfFont(8.8);
    final recHeroFont = await _loadTodoPdfFont(heroSize, bold: true);
    final recBigFont = await _loadTodoPdfFont(bigSize, bold: true);
    final recUnitFont = await _loadTodoPdfFont(unitSize);
    final recEmptyFont = await _loadTodoPdfFont(emptySize);
    final recNameFont = await _loadTodoPdfFont(9.2, bold: true);
    final recSubFont = await _loadTodoPdfFont(8.6);
    final recNoteFont = await _loadTodoPdfFont(7.4);
    final faintBrush = sf.PdfSolidBrush(sf.PdfColor(150, 150, 150));
    final accentBrush = sf.PdfSolidBrush(sf.PdfColor(33, 150, 243));
    final trackBrush = sf.PdfSolidBrush(sf.PdfColor(236, 236, 236));
    final progressGrayBrush = sf.PdfSolidBrush(sf.PdfColor(185, 185, 185));
    final recLimitY = foldY - 10;
    // 맑은 고딕: 글자 상단에서 기준선까지 = 글자 크기 × 1.06.
    // 크기가 다른 숫자와 단위를 같은 기준선에 놓을 때 쓴다.
    const ascentRatio = 1.06;
    double ry = recordTop;

    // 값: big 이 null 이면 small 만 흐리게(없음/기록 없음).
    ({String? big, String small}) countValue(int? n) =>
        n == null ? (big: null, small: '기록 없음') : (big: '$n', small: '문항');
    ({String? big, String small}) fractionValue(int done, int total,
            {String suffix = ''}) =>
        total > 0
            ? (big: '$done', small: '/ $total$suffix')
            : (big: null, small: '없음');

    void drawMetric({
      required double x,
      required double y,
      required double w,
      required String label,
      required ({String? big, String small}) value,
      required sf.PdfFont bigFont,
      required double bigFontSize,
    }) {
      graphics.drawString(label, recLabelFont,
          brush: subBrush, bounds: Rect.fromLTWH(x, y, w, 12));
      final valueY = y + 14;
      final big = value.big;
      if (big == null) {
        final emptyY = valueY + (bigFontSize - emptySize) * ascentRatio;
        graphics.drawString(value.small, recEmptyFont,
            brush: faintBrush, bounds: Rect.fromLTWH(x, emptyY, w, 14));
        return;
      }
      final bigW = math.min(bigFont.measureString(big).width + 1, w);
      graphics.drawString(big, bigFont,
          brush: textBrush,
          bounds: Rect.fromLTWH(x, valueY, bigW + 2, bigFontSize * 1.4));
      final unitX = x + bigW + 3;
      if (unitX < x + w) {
        graphics.drawString(value.small, recUnitFont,
            brush: subBrush,
            bounds: Rect.fromLTWH(
                unitX,
                valueY + (bigFontSize - unitSize) * ascentRatio,
                x + w - unitX,
                13));
      }
    }

    final rec = payload.lessonRecord;
    if (rec == null) {
      graphics.drawString('학습 기록 없음', recEmptyFont,
          brush: faintBrush,
          bounds: Rect.fromLTWH(summaryX, ry, summaryW, 14));
    } else {
      final corrTotal = rec.correctionRequiredCount;
      final corrDone = math.min(rec.correctionSuccessCount ?? 0, corrTotal ?? 0);
      final solved = rec.solvedProblemCount;
      final firstTry = rec.firstTryCorrectCount;
      final avgTries = rec.avgTriesToPass;

      const cellGap = 12.0;
      final cellW = (summaryW - cellGap) / 2;
      final heroCells = <(String, ({String? big, String small}))>[
        ('오늘 푼 문제', countValue(solved)),
        (
          '평균 시도',
          solved == null
              ? (big: null, small: '기록 없음')
              : avgTries == null
                  ? (big: null, small: '없음')
                  : (big: avgTries.toStringAsFixed(1), small: '회'),
        ),
      ];
      for (int i = 0; i < heroCells.length; i++) {
        drawMetric(
          x: summaryX + i * (cellW + cellGap),
          y: ry,
          w: cellW,
          label: heroCells[i].$1,
          value: heroCells[i].$2,
          bigFont: recHeroFont,
          bigFontSize: heroSize,
        );
      }
      ry += 72;

      final cells = <(String, ({String? big, String small}))>[
        (
          '정답률',
          solved == null || firstTry == null
              ? (big: null, small: '기록 없음')
              : solved <= 0
                  ? (big: null, small: '없음')
                  : (
                      big: '${(math.min(firstTry, solved) * 100 / solved).round()}',
                      small: '%',
                    ),
        ),
        (
          '수정',
          corrTotal == null
              ? (big: null, small: '기록 없음')
              : fractionValue(corrDone, corrTotal, suffix: ' 성공'),
        ),
        ('숙제', fractionValue(rec.homeworkCompleted, rec.homeworkTotal)),
        ('과제', fractionValue(rec.assignmentCompleted, rec.assignmentTotal)),
      ];
      // 줄 사이 빈칸만 1.5배. 행 간격 42 중 약 32는 글자 높이라,
      // 42를 그대로 1.5배 하면 빈칸(약 10)이 약 3배가 된다.
      const metricRowPitch = 47.0;
      for (int i = 0; i < cells.length; i++) {
        final col = i % 2;
        final row = i ~/ 2;
        drawMetric(
          x: summaryX + col * (cellW + cellGap),
          y: ry + row * metricRowPitch,
          w: cellW,
          label: cells[i].$1,
          value: cells[i].$2,
          bigFont: recBigFont,
          bigFontSize: bigSize,
        );
      }
      // 정답률 → 숙제 와 같은 행 간격. 그 사이의 구분선은 두지 않는다.
      ry += metricRowPitch * 2;
      graphics.drawString('학습 Flow', recLabelFont,
          brush: subBrush, bounds: Rect.fromLTWH(summaryX, ry, summaryW, 12));
      ry += 15;
      if (rec.problemRecordCoverage == 'partial') {
        graphics.drawString('* 문항 기록이 없는 교재는 문항 수에서 빠짐', recNoteFont,
            brush: faintBrush,
            bounds: Rect.fromLTWH(summaryX, ry, summaryW, 11));
        ry += 12;
      }
      if (rec.flows.isEmpty) {
        graphics.drawString('오늘 과제에 연결된 Flow 없음', recSubFont,
            brush: faintBrush,
            bounds: Rect.fromLTWH(summaryX, ry, summaryW, 13));
      } else {
        // 같은 Flow·교재명이 과정만 다르게 여러 줄이면 과정을 붙여 구분한다.
        final nameCounts = <String, int>{};
        for (final f in rec.flows) {
          final key = '${f.flowName}|${f.bookName ?? ''}';
          nameCounts[key] = (nameCounts[key] ?? 0) + 1;
        }
        String flowLabel(LessonRecordFlowProgress f) {
          final flowName = f.flowName.trim().isEmpty ? 'Flow' : f.flowName.trim();
          final book = (f.bookName ?? '').trim();
          if (book.isEmpty) return flowName;
          final grade = (f.gradeLabel ?? '').trim();
          final dup = (nameCounts['${f.flowName}|${f.bookName ?? ''}'] ?? 0) > 1;
          return dup && grade.isNotEmpty
              ? '$flowName - $book ($grade)'
              : '$flowName - $book';
        }

        for (int i = 0; i < rec.flows.length; i++) {
          final flow = rec.flows[i];
          final pct = flow.progressPercent;
          final rowH = pct != null ? 24.0 : 18.0;
          final remaining = rec.flows.length - i;
          if (ry + rowH + (remaining > 1 ? 14 : 0) > recLimitY) {
            graphics.drawString('외 $remaining개', recSubFont,
                brush: faintBrush,
                bounds: Rect.fromLTWH(summaryX, ry, summaryW, 13));
            break;
          }
          final stateText = flow.completed ? '완료' : '진행 중';
          final stateW = math.min(
            recSubFont.measureString(stateText).width + 2,
            summaryW * 0.4,
          );
          final nameW = math.max(0.0, summaryW - stateW - 6);
          graphics.drawString(flowLabel(flow), recNameFont,
              brush: textBrush,
              bounds: Rect.fromLTWH(summaryX, ry, nameW, 14));
          graphics.drawString(stateText, recSubFont,
              brush: flow.completed ? textBrush : subBrush,
              bounds: Rect.fromLTWH(summaryX + nameW + 6, ry + 1, stateW, 13),
              format: rightAlign);
          if (pct != null) {
            // 회색 = 등원 전까지 진도, 파랑 = 오늘 늘어난 만큼.
            const pctAreaW = 58.0;
            final barW = math.max(0.0, summaryW - pctAreaW - 6);
            final barY = ry + 16;
            const barH = 3.2;
            final beforePct = (flow.beforePercent ?? pct).clamp(0.0, 100.0);
            final todayPct =
                (flow.todayPercent ?? 0).clamp(0.0, 100.0 - beforePct);
            graphics.drawRectangle(
                brush: trackBrush,
                bounds: Rect.fromLTWH(summaryX, barY, barW, barH));
            final beforeW = barW * beforePct / 100;
            if (beforeW > 0) {
              graphics.drawRectangle(
                  brush: progressGrayBrush,
                  bounds: Rect.fromLTWH(summaryX, barY, beforeW, barH));
            }
            final todayW = barW * todayPct / 100;
            if (todayW > 0) {
              graphics.drawRectangle(
                  brush: accentBrush,
                  bounds:
                      Rect.fromLTWH(summaryX + beforeW, barY, todayW, barH));
            }
            final pctX = summaryX + barW + 6;
            final totalText = flow.todayPercent == null
                ? '${pct.round()}%'
                : '/${pct.round()}%';
            final totalTextW = math.min(
                recSubFont.measureString(totalText).width + 1, pctAreaW);
            graphics.drawString(totalText, recSubFont,
                brush: subBrush,
                bounds: Rect.fromLTWH(pctX + pctAreaW - totalTextW, barY - 5,
                    totalTextW, 13),
                format: rightAlign);
            if (flow.todayPercent != null) {
              graphics.drawString('+${todayPct.round()}%', recSubFont,
                  brush: accentBrush,
                  bounds: Rect.fromLTWH(
                      pctX, barY - 5, pctAreaW - totalTextW, 13),
                  format: rightAlign);
            }
          }
          ry += rowH;
        }
      }
    }
  }

  // ── Page 1 bottom half: 숙제 리스트 + 행동 리스트 ──
  // foldY는 상단 여백 0으로 4pt 내려간다. 숙제 리스트 용지상 Y는 이전과 같다.
  final todoTop = foldY + 30;
  // 수업 요약과 학습 기록 사이와 같은 칸 간격.
  final colWidth = (contentWidth - columnGap) / 2;
  final leftColX = left;
  final rightColX = left + colWidth + columnGap;
  graphics.drawString(
    '숙제 리스트',
    sectionFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(leftColX, todoTop, colWidth, 18),
  );
  graphics.drawString(
    _formatDueDateForTitle(payload.dueDate),
    labelFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(leftColX, todoTop + 2, colWidth, 16),
    format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right),
  );
  graphics.drawString(
    '행동 리스트',
    sectionFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(rightColX, todoTop, colWidth, 18),
  );
  graphics.drawLine(weakLinePen, Offset(rightColX - (columnGap / 2), todoTop),
      Offset(rightColX - (columnGap / 2), contentBottom));

  // 줄 사이 빈칸 4를 3.2로(20% 축소). 칸 전체 18을 줄이면 글자(14)가 겹친다.
  // 카드 사이 빈칸 4는 4.8로(20% 확대). 제목 아래 30은 수업 요약과 같다.
  const flowTextH = 14.0;
  const flowLineStep = 17.2;
  const flowCardGap = 4.8;
  const flowInlineGap = 6.0;
  const sectionBodyGap = 30.0;
  double leftY = todoTop + sectionBodyGap;
  final todoEntries = payload.todoEntries;
  for (int i = 0; i < todoEntries.length; i++) {
    final entry = todoEntries[i];
    const cardH = flowLineStep * 2 + flowTextH + flowCardGap;
    final remaining = todoEntries.length - i;
    if (leftY + cardH + (remaining > 1 ? overflowLineH : 0) > contentBottom - 8) {
      drawOverflow(graphics, leftColX, leftY, colWidth, remaining);
      break;
    }
    final prim = entry.primary;
    final bx = leftColX;
    final bw = colWidth;
    final hasCheckbox = prim.startsWith('□');
    final prefix = hasCheckbox ? '□ ' : '';
    final prefixW =
        prefix.isEmpty ? 0.0 : bodyFont.measureString(prefix).width;
    const checkboxGap = 4.0;
    final textX = bx + (prefixW > 0 ? prefixW + checkboxGap : 0.0);
    final textW = math.max(0.0, bw - (textX - bx));
    final rightPrimary = (entry.rightPrimary ?? '').trim();
    final rightPrimaryW =
        rightPrimary.isEmpty ? 0.0 : math.min(62.0, textW * 0.28);
    final line1TextW =
        rightPrimaryW > 0 ? math.max(0.0, textW - rightPrimaryW - flowInlineGap) : textW;
    final bookTitle = (entry.bookTitle ?? '').trim();
    final itemTop = leftY;

    // 1줄: □ (bx) + 교재/과정 (textX) · 내준날짜 (우)
    if (hasCheckbox) {
      graphics.drawString(prefix, bodyFont,
          brush: textBrush,
          bounds: Rect.fromLTWH(bx, itemTop, math.min(prefixW + 2, bw), flowTextH));
    }
    if (bookTitle.isNotEmpty) {
      await drawLine(
        graphics,
        bookTitle,
        bodyBoldFont,
        fontSize: 10.2,
        bold: true,
        brush: textBrush,
        color: textColor,
        bounds: Rect.fromLTWH(textX, itemTop, line1TextW, flowTextH),
      );
    } else {
      final fallback =
          hasCheckbox ? prim.replaceFirst(RegExp(r'^□\s*'), '') : prim;
      await drawLine(
        graphics,
        fallback,
        bodyFont,
        fontSize: 10.2,
        bold: false,
        brush: textBrush,
        color: textColor,
        bounds: Rect.fromLTWH(textX, itemTop, line1TextW, flowTextH),
      );
    }
    if (rightPrimaryW > 0) {
      graphics.drawString(rightPrimary, subFont,
          brush: subBrush,
          bounds: Rect.fromLTWH(
              textX + line1TextW + flowInlineGap, itemTop, rightPrimaryW, flowTextH),
          format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right));
    }

    // 2줄: 그룹 과제 제목 (좌) + 예상 수행시간 (우). 시작 x는 1줄 교재명과 같다.
    final secondary = (entry.secondary ?? '').trim();
    final rightSecondary = (entry.rightSecondary ?? '').trim();
    final rightSecondaryW = rightSecondary.isEmpty
        ? 0.0
        : math.min(
            subFont.measureString(rightSecondary).width + 2,
            textW * 0.55,
          );
    final line2LeftW = rightSecondaryW > 0
        ? math.max(0.0, textW - rightSecondaryW - flowInlineGap)
        : textW;
    if (secondary.isNotEmpty) {
      await drawLine(
        graphics,
        secondary,
        subFont,
        fontSize: 9.2,
        bold: false,
        brush: subBrush,
        color: subColor,
        bounds: Rect.fromLTWH(textX, itemTop + flowLineStep, line2LeftW, flowTextH),
      );
    }
    if (rightSecondaryW > 0) {
      graphics.drawString(rightSecondary, subFont,
          brush: subBrush,
          bounds: Rect.fromLTWH(textX + line2LeftW + flowInlineGap,
              itemTop + flowLineStep, rightSecondaryW, flowTextH),
          format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right));
    }

    // 3줄: 페이지 · 문항수 (좌) + 메모 (우)
    final tertiary = (entry.tertiary ?? '').trim();
    final rightTertiary = (entry.rightTertiary ?? '').trim();
    if (tertiary.isNotEmpty || rightTertiary.isNotEmpty) {
      final rightTertiaryW =
          rightTertiary.isEmpty ? 0.0 : math.min(112.0, textW * 0.46);
      final line3LeftW = rightTertiaryW > 0
          ? math.max(0.0, textW - rightTertiaryW - flowInlineGap)
          : textW;
      if (tertiary.isNotEmpty) {
        graphics.drawString(tertiary, subFont,
            brush: subBrush,
            bounds: Rect.fromLTWH(
                textX, itemTop + flowLineStep * 2, line3LeftW, flowTextH));
      }
      if (rightTertiaryW > 0) {
        graphics.drawString(rightTertiary, subFont,
            brush: subBrush,
            bounds: Rect.fromLTWH(textX + line3LeftW + flowInlineGap,
                itemTop + flowLineStep * 2, rightTertiaryW, flowTextH),
            format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right));
      }
    }

    leftY = itemTop + flowLineStep * 2 + flowTextH + flowCardGap;
  }

  double rightY = todoTop + sectionBodyGap;
  final behaviorEntries = payload.behaviorEntries;
  if (behaviorEntries.isEmpty) {
    graphics.drawString('• 행동 없음', bodyFont,
        brush: subBrush,
        bounds: Rect.fromLTWH(rightColX, rightY, colWidth, flowTextH));
  } else {
    for (int i = 0; i < behaviorEntries.length; i++) {
      final entry = behaviorEntries[i];
      final hasSecond =
          entry.secondary != null && entry.secondary!.trim().isNotEmpty;
      final rowH = (hasSecond ? flowLineStep : 0) + flowTextH + flowCardGap;
      final remaining = behaviorEntries.length - i;
      if (rightY + rowH + (remaining > 1 ? overflowLineH : 0) >
          contentBottom - 8) {
        drawOverflow(graphics, rightColX, rightY, colWidth, remaining);
        break;
      }
      graphics.drawString(entry.primary, bodyFont,
          brush: textBrush,
          bounds: Rect.fromLTWH(rightColX, rightY, colWidth, flowTextH));
      if (hasSecond) {
        graphics.drawString(entry.secondary!, subFont,
            brush: subBrush,
            bounds: Rect.fromLTWH(
                rightColX, rightY + flowLineStep, colWidth, flowTextH));
      }
      rightY += rowH;
    }
  }

  // ── Page 2: 학습 내역 (Learning History) ──
  final page2 = doc.pages.add();
  final g2 = page2.graphics;
  final size2 = page2.getClientSize();
  final right2 = size2.width - 10;
  final contentWidth2 = right2 - left;
  final bottom2 = size2.height - 6;

  g2.drawString('학습 내역', sectionFont,
      brush: subBrush,
      bounds: Rect.fromLTWH(left, page2Top + 6, contentWidth2, 18));

  final p2Top = page2Top + 36;
  final p2ColWidth = (contentWidth2 - columnGap) / 2;
  final p2LeftX = left;
  final p2RightX = left + p2ColWidth + columnGap;
  // 4분할: 위 두 칸(완료 과제 · 수업)은 접는 선 위, 아래 왼쪽은 숙제 검사 내역.
  final foldY2 = size2.height / 2;
  final p2RowsLimit = foldY2 - 10;
  final p2BottomTop = foldY2 + 30;
  final p2BottomLimit = bottom2 - 10;

  void drawProgressBar({
    required sf.PdfGraphics g,
    required double x,
    required double y,
    required double w,
    required double previousPct,
    required double todayPct,
  }) {
    const h = 5.0;
    final prev = previousPct.clamp(0.0, 100.0);
    final today = todayPct.clamp(0.0, math.max(0.0, 100.0 - prev));
    g.drawRectangle(
      pen: weakLinePen,
      brush: sf.PdfSolidBrush(sf.PdfColor(238, 238, 238)),
      bounds: Rect.fromLTWH(x, y, w, h),
    );
    if (prev > 0) {
      g.drawRectangle(
        brush: sf.PdfSolidBrush(sf.PdfColor(185, 185, 185)),
        bounds: Rect.fromLTWH(x, y, w * prev / 100, h),
      );
    }
    if (today > 0) {
      final prevW = w * prev / 100;
      g.drawRectangle(
        brush: sf.PdfSolidBrush(sf.PdfColor(76, 175, 80)),
        bounds: Rect.fromLTWH(x + prevW, y, w * today / 100, h),
      );
    }
  }

  g2.drawString('오늘 완료한 과제', sectionFont,
      brush: textBrush,
      bounds: Rect.fromLTWH(p2LeftX, p2Top, p2ColWidth, 18));
  g2.drawString('수업', sectionFont,
      brush: textBrush,
      bounds: Rect.fromLTWH(p2RightX, p2Top, p2ColWidth, 18));
  g2.drawLine(weakLinePen, Offset(p2RightX - (columnGap / 2), p2Top),
      Offset(p2RightX - (columnGap / 2), p2RowsLimit));

  double p2LeftY = p2Top + sectionBodyGap;
  if (payload.completedSummaries.isEmpty) {
    g2.drawString('완료 과제 없음', subFont,
        brush: subBrush,
        bounds: Rect.fromLTWH(p2LeftX, p2LeftY, p2ColWidth, flowTextH));
  } else {
    final completed = payload.completedSummaries;
    const cardH = flowLineStep * 2 + flowTextH + 7 + flowCardGap;
    for (int i = 0; i < completed.length; i++) {
      final cs = completed[i];
      final remaining = completed.length - i;
      if (p2LeftY + cardH + (remaining > 1 ? overflowLineH : 0) > p2RowsLimit) {
        drawOverflow(g2, p2LeftX, p2LeftY, p2ColWidth, remaining);
        break;
      }
      final bookText =
          cs.bookAndCourse.trim().isEmpty ? '-' : cs.bookAndCourse.trim();
      final groupText =
          cs.groupTitle.trim().isEmpty ? '(제목 없음)' : cs.groupTitle.trim();
      final totalMin = (cs.totalMs / 60000).round();
      final infoText = [
        '총 $totalMin분',
        '${cs.assignmentCount}회 출제',
        '${cs.checkCount}회 검사',
        '오늘 +${cs.progressPct.toStringAsFixed(0)}%',
        '전체 ${cs.totalProgressPct.toStringAsFixed(0)}%',
      ].join(' · ');
      final cardX = p2LeftX;
      final cardW = p2ColWidth;
      await drawLine(
        g2,
        bookText,
        bodyBoldFont,
        fontSize: 10.2,
        bold: true,
        brush: textBrush,
        color: textColor,
        bounds: Rect.fromLTWH(cardX, p2LeftY, cardW, flowTextH),
      );
      await drawLine(
        g2,
        groupText,
        subFont,
        fontSize: 9.2,
        bold: false,
        brush: subBrush,
        color: subColor,
        bounds: Rect.fromLTWH(cardX, p2LeftY + flowLineStep, cardW, flowTextH),
      );
      g2.drawString(infoText, subFont,
          brush: subBrush,
          bounds: Rect.fromLTWH(
              cardX, p2LeftY + flowLineStep * 2, cardW, flowTextH));
      final barY = p2LeftY + flowLineStep * 2 + flowTextH + 2;
      drawProgressBar(
        g: g2,
        x: cardX,
        y: barY,
        w: cardW,
        previousPct: cs.previousProgressPct,
        todayPct: cs.progressPct,
      );
      p2LeftY = barY + 5 + flowCardGap;
    }
  }

  double p2RightY = p2Top + sectionBodyGap;
  if (payload.classWorkEntries.isEmpty) {
    g2.drawString('• 오늘 수행 기록 없음', subFont,
        brush: subBrush,
        bounds: Rect.fromLTWH(p2RightX, p2RightY, p2ColWidth, flowTextH));
  } else {
    final classLines = payload.classWorkEntries;
    for (int i = 0; i < classLines.length; i++) {
      final line = classLines[i];
      final groupTitle = line.title.trim().isEmpty ? '' : line.title.trim();
      final subCount = line.subEntries.length;
      final lastOffset = subCount == 0
          ? (groupTitle.isNotEmpty ? flowLineStep : 0.0)
          : flowLineStep * (1 + subCount);
      final cardH = lastOffset + flowTextH + flowCardGap;
      final remaining = classLines.length - i;
      if (p2RightY + cardH + (remaining > 1 ? overflowLineH : 0) > p2RowsLimit) {
        drawOverflow(g2, p2RightX, p2RightY, p2ColWidth, remaining);
        break;
      }
      final bookText =
          line.bookAndCourse.trim().isEmpty ? '' : line.bookAndCourse.trim();
      final timeText =
          line.studyMs > 0 ? _formatDurationKorean(line.studyMs) : '';
      final cardX = p2RightX;
      final cardW = p2ColWidth;
      final timeW = timeText.isEmpty
          ? 0.0
          : math.min(bodyFont.measureString(timeText).width + 2, cardW * 0.4);
      final line1LeftW =
          timeW > 0 ? math.max(0.0, cardW - timeW - flowInlineGap) : cardW;
      final itemTop = p2RightY;
      if (bookText.isNotEmpty) {
        await drawLine(
          g2,
          bookText,
          bodyBoldFont,
          fontSize: 10.2,
          bold: true,
          brush: textBrush,
          color: textColor,
          bounds: Rect.fromLTWH(cardX, itemTop, line1LeftW, flowTextH),
        );
      }
      if (timeW > 0) {
        g2.drawString(timeText, subFont,
            brush: subBrush,
            bounds: Rect.fromLTWH(
                cardX + line1LeftW + flowInlineGap, itemTop, timeW, flowTextH),
            format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right));
      }
      if (groupTitle.isNotEmpty) {
        await drawLine(
          g2,
          groupTitle,
          subFont,
          fontSize: 9.2,
          bold: false,
          brush: subBrush,
          color: subColor,
          bounds: Rect.fromLTWH(
              cardX, itemTop + flowLineStep, cardW, flowTextH),
        );
      }
      var lineY = itemTop + flowLineStep * 2;
      for (final sub in line.subEntries) {
        if (lineY + flowTextH > p2RowsLimit) break;
        final subText = '${sub.title} · p.${sub.page} · ${sub.count}문항';
        await drawLine(
          g2,
          subText,
          subFont,
          fontSize: 9.2,
          bold: false,
          brush: subBrush,
          color: subColor,
          bounds: Rect.fromLTWH(cardX, lineY, cardW, flowTextH),
        );
        lineY += flowLineStep;
      }
      final lastLine = line.subEntries.isEmpty
          ? itemTop + (groupTitle.isNotEmpty ? flowLineStep : 0)
          : lineY - flowLineStep;
      p2RightY = lastLine + flowTextH + flowCardGap;
    }
  }

  // ── Page 2 bottom-left: 숙제 검사 내역 ──
  final csX = p2LeftX;
  final csW = p2ColWidth;
  final csLine1Font = await _loadTodoPdfFont(9.2, bold: true);
  final csLine2Font = await _loadTodoPdfFont(9.0);
  g2.drawString('숙제 검사 내역 $visibleCheckRateCount개', sectionFont,
      brush: textBrush,
      bounds: Rect.fromLTWH(p2LeftX, p2BottomTop, p2ColWidth, 18));
  double csY = p2BottomTop + sectionBodyGap;

  final hasCheckData = payload.checkRates.any((e) => e.progress != null);
  if (hasCheckData) {
    // 분자: 오늘 추가된 % 합(정규 오늘검사예정 + 자의 추가분 모두 포함)
    // 분모: 정규 오늘검사예정 과제의 "내준 시점 기준 남은 %"만 합산
    //       (자의 추가분은 분모에서 제외 -> 100% 초과 가능)
    int sumTodayPct = 0;
    int sumRemainingPct = 0;
    for (final cr in payload.checkRates) {
      if (cr.progress == null) continue;
      sumTodayPct += (cr.todayProgress ?? 0);
      if (!cr.isExtra) {
        sumRemainingPct += math.max(0, 100 - (cr.previousProgress ?? 0));
      }
    }
    final int ratioPct = sumRemainingPct > 0
        ? ((sumTodayPct * 100) / sumRemainingPct).round()
        : (sumTodayPct > 0 ? 101 : 0);
    final mood = _todoCheckMoodFor(ratioPct);
    const double emSize = 24.0;
    const double moodGap = 8.0;
    // 타이틀 하단과 이모지 사이 여백을, 이모지와 리스트 사이 간격(13)과 동일하게 맞춘다.
    const double moodVGap = 13.0;
    final double emY = p2BottomTop + sectionBodyGap;
    final moodFont = await _loadTodoPdfFont(10.8, bold: true);
    final moodText = '${mood.label}  $ratioPct%';
    final moodTextW = moodFont.measureString(moodText).width;
    final blockW = emSize + moodGap + moodTextW;
    final blockX = csX + math.max(0.0, (csW - blockW) / 2);
    final emojiBmp = await _loadTodoEmojiBitmap(mood.asset);
    if (emojiBmp != null) {
      g2.drawImage(emojiBmp, Rect.fromLTWH(blockX, emY, emSize, emSize));
      if (mood.fire) {
        final flameBmp = await _loadTodoEmojiBitmap('assets/emoji/flame.png');
        if (flameBmp != null) {
          g2.drawImage(
              flameBmp, Rect.fromLTWH(blockX + emSize - 11, emY - 7, 15, 15));
        }
      }
    }
    final moodTextX = blockX + emSize + moodGap;
    g2.drawString(moodText, moodFont,
        brush: textBrush,
        bounds: Rect.fromLTWH(moodTextX, emY + 5, moodTextW + 4, 18));
    csY = emY + emSize + moodVGap;
  }

  if (!hasCheckData) {
    g2.drawString('검사 내역 없음', subFont,
        brush: subBrush, bounds: Rect.fromLTWH(csX, csY, csW, 14));
  } else {
    final rightAlign = sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right);
    final checkRows = payload.checkRates;
    const cardH = flowLineStep * 2 + flowTextH + 7 + flowCardGap;
    for (int i = 0; i < checkRows.length; i++) {
      final cr = checkRows[i];
      final remaining = checkRows.length - i;
      if (csY + cardH + (remaining > 1 ? overflowLineH : 0) > p2BottomLimit) {
        drawOverflow(g2, csX, csY, csW, remaining);
        break;
      }
      final bookText = cr.bookAndCourse.trim();
      final groupText = cr.title.trim();
      final titleText = (() {
        if (bookText.isEmpty && groupText.isEmpty) return '(제목 없음)';
        if (bookText.isEmpty) return groupText;
        if (groupText.isEmpty) return bookText;
        return '$bookText · $groupText';
      })();
      final todayPct = cr.todayProgress ?? 0;
      final previousPct = cr.previousProgress ?? 0;
      // 2번째 줄: 페이지(좌) | 문항수 · +퍼센트(우)
      // 홈 그룹 카드와 같이 p.130-132 형식. 왼쪽이 오른쪽 문구를 덮지 않게 칸을 나눈다.
      final line2Left = _formatPageTextCompact(cr.page);
      final missedLabel = switch (cr.outcome) {
        'left_behind' => '숙제 안 함 (두고 옴) · 0%',
        'not_done' => '숙제 안 함 · 0%',
        _ => null,
      };
      final line2Right = missedLabel ??
          [
            if (_formatCountText(cr.count) != '-') _formatCountText(cr.count),
            '+$todayPct%',
          ].join(' · ');
      // 3번째 줄: 내준 날짜 · 마감 날짜(좌) | 검사일(우)
      final line3Left = [
        '내준 ${cr.assignedAt != null ? _formatMonthDay(cr.assignedAt!) : '-'}',
        '마감 ${cr.dueDate != null ? _formatMonthDay(cr.dueDate!) : '-'}',
      ].join(' · ');
      final line3Right =
          '검사 ${cr.checkedAt != null ? _formatMonthDay(cr.checkedAt!) : '-'}';
      await drawLine(
        g2,
        titleText,
        csLine1Font,
        fontSize: 9.2,
        bold: true,
        brush: textBrush,
        color: textColor,
        bounds: Rect.fromLTWH(csX, csY, csW, flowTextH),
      );
      final line2RightW = line2Right.isEmpty
          ? 0.0
          : math.min(
              csLine2Font.measureString(line2Right).width + 2,
              csW * 0.46,
            );
      final line2LeftW = line2RightW > 0
          ? math.max(0.0, csW - line2RightW - flowInlineGap)
          : csW;
      final line3RightW = math.min(
        csLine2Font.measureString(line3Right).width + 2,
        csW * 0.4,
      );
      final line3LeftW = math.max(0.0, csW - line3RightW - flowInlineGap);
      g2.drawString(line2Left, csLine2Font,
          brush: subBrush,
          bounds: Rect.fromLTWH(csX, csY + flowLineStep, line2LeftW, flowTextH));
      if (line2RightW > 0) {
        g2.drawString(line2Right, csLine2Font,
            brush: subBrush,
            bounds: Rect.fromLTWH(csX + line2LeftW + flowInlineGap,
                csY + flowLineStep, line2RightW, flowTextH),
            format: rightAlign);
      }
      g2.drawString(line3Left, csLine2Font,
          brush: subBrush,
          bounds: Rect.fromLTWH(
              csX, csY + flowLineStep * 2, line3LeftW, flowTextH));
      g2.drawString(line3Right, csLine2Font,
          brush: subBrush,
          bounds: Rect.fromLTWH(csX + line3LeftW + flowInlineGap,
              csY + flowLineStep * 2, line3RightW, flowTextH),
          format: rightAlign);
      final barY = csY + flowLineStep * 2 + flowTextH + 2;
      drawProgressBar(
        g: g2,
        x: csX,
        y: barY,
        w: csW,
        previousPct: previousPct.toDouble(),
        todayPct: todayPct.toDouble(),
      );
      final rowAdvance = barY - csY + 5 + flowCardGap;
      g2.drawLine(weakLinePen, Offset(csX, csY + rowAdvance - 3),
          Offset(csX + csW, csY + rowAdvance - 3));
      csY += rowAdvance;
    }
  }

  final bytes = await doc.save();
  doc.dispose();
  return bytes;
}

void _scheduleTempDelete(String path) {
  Future<void>.delayed(const Duration(minutes: 10), () async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  });
}

Future<void> _openPrintDialogForPath(String path) async {
  final accepted = await PrintRoutingService.instance.printFile(
    path: path,
    channel: PrintRoutingChannel.todoSheet,
    duplexMode: PrintDuplexMode.twoSidedLongEdge,
    preferredPaperSize: 'A4',
    debugSource: 'homework.todo_sheet',
  );
  if (!accepted) {
    throw StateError('알림장 인쇄 작업을 프린터에 전달하지 못했습니다.');
  }
}
