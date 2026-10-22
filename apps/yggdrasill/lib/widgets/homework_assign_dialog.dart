import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
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
import '../services/todo_sheet_snapshot_service.dart';
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

Map<String, dynamic> _todoSheetPayloadToSnapshotJson(
  _TodoSheetPayload payload,
) {
  String? iso(DateTime? value) => value?.toUtc().toIso8601String();
  return <String, dynamic>{
    'academy_name': payload.academyName,
    'student_name': payload.studentName,
    'class_date_time': iso(payload.classDateTime),
    'due_date': iso(payload.dueDate),
    'arrival_time': iso(payload.arrivalTime),
    'departure_time': iso(payload.departureTime),
    'class_name': payload.className,
    'class_time_text': payload.classTimeText,
    'learning_time_text': payload.learningTimeText,
    'learning_ms': payload.learningMs,
    'check_rates': [
      for (final entry in payload.checkRates)
        <String, dynamic>{
          'title': entry.title,
          'progress': entry.progress,
          'previous_progress': entry.previousProgress,
          'today_progress': entry.todayProgress,
          'book_and_course': entry.bookAndCourse,
          'page': entry.page,
          'count': entry.count,
          'assigned_at': iso(entry.assignedAt),
          'due_date': iso(entry.dueDate),
          'checked_at': iso(entry.checkedAt),
          'outcome': entry.outcome,
          'reason': entry.reason,
          'is_extra': entry.isExtra,
        },
    ],
    'class_work_entries': [
      for (final entry in payload.classWorkEntries)
        <String, dynamic>{
          'title': entry.title,
          'book_and_course': entry.bookAndCourse,
          'page': entry.page,
          'count': entry.count,
          'assigned_at': iso(entry.assignedAt),
          'study_ms': entry.studyMs,
          'today_check_count': entry.todayCheckCount,
          'total_check_count': entry.totalCheckCount,
          'passed': entry.passed,
          'total_accumulated_ms': entry.totalAccumulatedMs,
          'sub_entries': [
            for (final sub in entry.subEntries)
              <String, dynamic>{
                'title': sub.title,
                'page': sub.page,
                'count': sub.count,
              },
          ],
        },
    ],
    'completed_summaries': [
      for (final entry in payload.completedSummaries)
        <String, dynamic>{
          'group_title': entry.groupTitle,
          'book_and_course': entry.bookAndCourse,
          'total_ms': entry.totalMs,
          'assignment_count': entry.assignmentCount,
          'check_count': entry.checkCount,
          'progress_pct': entry.progressPct,
          'previous_progress_pct': entry.previousProgressPct,
          'total_progress_pct': entry.totalProgressPct,
          'eta_text': entry.etaText,
        },
    ],
    'completed_entries': [
      for (final entry in payload.completedEntries) _todoEntryToJson(entry),
    ],
    'todo_entries': [
      for (final entry in payload.todoEntries) _todoEntryToJson(entry),
    ],
    'behavior_entries': [
      for (final entry in payload.behaviorEntries) _todoEntryToJson(entry),
    ],
    'behavior_feedback': payload.behaviorFeedback,
    'lesson_record': payload.lessonRecord?.toJson(),
    'special_notes': payload.specialNotes,
  };
}

Map<String, dynamic> _todoEntryToJson(_TodoListEntry entry) =>
    <String, dynamic>{
      'primary': entry.primary,
      'secondary': entry.secondary,
      'tertiary': entry.tertiary,
      'book_title': entry.bookTitle,
      'item_title': entry.itemTitle,
      'right_primary': entry.rightPrimary,
      'right_secondary': entry.rightSecondary,
      'right_tertiary': entry.rightTertiary,
    };

_TodoSheetPayload _todoSheetPayloadFromSnapshotJson(
  Map<String, dynamic> json, {
  Uint8List? academyLogo,
}) {
  String text(String key) => '${json[key] ?? ''}';
  int integer(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  double decimal(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
  DateTime? date(dynamic value) {
    final parsed = DateTime.tryParse('${value ?? ''}');
    return parsed?.toLocal();
  }

  List<Map<String, dynamic>> maps(String key) {
    final raw = json[key];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
  }

  _TodoListEntry todoEntry(Map<String, dynamic> entry) => _TodoListEntry(
        primary: '${entry['primary'] ?? ''}',
        secondary: entry['secondary'] as String?,
        tertiary: entry['tertiary'] as String?,
        bookTitle: entry['book_title'] as String?,
        itemTitle: entry['item_title'] as String?,
        rightPrimary: entry['right_primary'] as String?,
        rightSecondary: entry['right_secondary'] as String?,
        rightTertiary: entry['right_tertiary'] as String?,
      );

  final lessonJson = json['lesson_record'];
  return _TodoSheetPayload(
    academyName: text('academy_name'),
    academyLogo: academyLogo,
    studentName: text('student_name'),
    classDateTime: date(json['class_date_time']) ?? DateTime.now(),
    dueDate: date(json['due_date']),
    arrivalTime: date(json['arrival_time']),
    departureTime: date(json['departure_time']) ?? DateTime.now(),
    className: text('class_name'),
    classTimeText: text('class_time_text'),
    learningTimeText: text('learning_time_text'),
    learningMs: integer(json['learning_ms']),
    checkRates: [
      for (final entry in maps('check_rates'))
        _CheckRateEntry(
          title: '${entry['title'] ?? ''}',
          progress:
              entry['progress'] == null ? null : integer(entry['progress']),
          previousProgress: entry['previous_progress'] == null
              ? null
              : integer(entry['previous_progress']),
          todayProgress: entry['today_progress'] == null
              ? null
              : integer(entry['today_progress']),
          bookAndCourse: '${entry['book_and_course'] ?? ''}',
          page: '${entry['page'] ?? ''}',
          count: '${entry['count'] ?? ''}',
          assignedAt: date(entry['assigned_at']),
          dueDate: date(entry['due_date']),
          checkedAt: date(entry['checked_at']),
          outcome: entry['outcome'] as String?,
          reason: entry['reason'] as String?,
          isExtra: entry['is_extra'] == true,
        ),
    ],
    classWorkEntries: [
      for (final entry in maps('class_work_entries'))
        _ClassWorkEntry(
          title: '${entry['title'] ?? ''}',
          bookAndCourse: '${entry['book_and_course'] ?? ''}',
          page: '${entry['page'] ?? ''}',
          count: '${entry['count'] ?? ''}',
          assignedAt: date(entry['assigned_at']),
          studyMs: integer(entry['study_ms']),
          todayCheckCount: integer(entry['today_check_count']),
          totalCheckCount: integer(entry['total_check_count']),
          passed: entry['passed'] == true,
          totalAccumulatedMs: integer(entry['total_accumulated_ms']),
          subEntries: [
            for (final sub
                in (entry['sub_entries'] as List? ?? const <dynamic>[])
                    .whereType<Map>())
              _SubWorkEntry(
                title: '${sub['title'] ?? ''}',
                page: '${sub['page'] ?? ''}',
                count: '${sub['count'] ?? ''}',
              ),
          ],
        ),
    ],
    completedSummaries: [
      for (final entry in maps('completed_summaries'))
        _CompletedSummaryEntry(
          groupTitle: '${entry['group_title'] ?? ''}',
          bookAndCourse: '${entry['book_and_course'] ?? ''}',
          totalMs: integer(entry['total_ms']),
          assignmentCount: integer(entry['assignment_count']),
          checkCount: integer(entry['check_count']),
          progressPct: decimal(entry['progress_pct']),
          previousProgressPct: decimal(entry['previous_progress_pct']),
          totalProgressPct: decimal(entry['total_progress_pct']),
          etaText: entry['eta_text'] as String?,
        ),
    ],
    completedEntries: [
      for (final entry in maps('completed_entries')) todoEntry(entry),
    ],
    todoEntries: [
      for (final entry in maps('todo_entries')) todoEntry(entry),
    ],
    behaviorEntries: [
      for (final entry in maps('behavior_entries')) todoEntry(entry),
    ],
    behaviorFeedback: text('behavior_feedback'),
    lessonRecord: lessonJson is Map
        ? LessonRecordSummary.fromJson(
            Map<String, dynamic>.from(lessonJson),
          )
        : null,
    specialNotes: (json['special_notes'] as List? ?? const <dynamic>[])
        .map((entry) => '$entry')
        .toList(growable: false),
  );
}

List<String> _buildSpecialNotes({
  required String studentId,
  required DateTime classDateTime,
  DateTime? arrivalTime,
}) {
  final notes = <String>[];
  final arrival = arrivalTime?.toLocal();
  if (arrival != null) {
    final threshold = DataManager.instance
            .getStudentPaymentInfo(studentId)
            ?.latenessThreshold ??
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
  bool saveSnapshotIfDeparted = true,
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
  final attendance = _findTodoSheetAttendanceRecord(
    studentId: studentId,
    classDateTime: classDateTime,
  );
  final attendanceId = (attendance?.id ?? '').trim();
  if (saveSnapshotIfDeparted &&
      attendanceId.isNotEmpty &&
      attendance?.departureTime != null) {
    try {
      await TodoSheetSnapshotService.instance.finalize(
        attendanceId: attendanceId,
        payload: _todoSheetPayloadToSnapshotJson(payload),
      );
    } catch (error, stackTrace) {
      debugPrint('[TODO_SHEET_SNAPSHOT][PRINT_FALLBACK][ERROR] '
          '$error\n$stackTrace');
    }
  }
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

/// 하원 확정 뒤 알림장을 다시 계산하지 않아도 되도록 의미 데이터를 고정한다.
///
/// 미리보기에서는 호출하지 않는다. 서버 함수도 하원 시간이 없는 출결은 거부한다.
Future<void> finalizeHomeworkTodoSheetSnapshot({
  required String attendanceId,
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
  await TodoSheetSnapshotService.instance.finalize(
    attendanceId: attendanceId,
    payload: _todoSheetPayloadToSnapshotJson(payload),
  );
}

Future<void> previewSavedHomeworkTodoSheet(String snapshotId) async {
  final json =
      await TodoSheetSnapshotService.instance.loadPayload(snapshotId.trim());
  final payload = _todoSheetPayloadFromSnapshotJson(
    json,
    academyLogo: DataManager.instance.academySettings.logo,
  );
  final outPath = await _buildHomeworkTodoPdf(payload: payload);
  await OpenFilex.open(outPath);
  _scheduleTempDelete(outPath);
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// [day]의 검사 중 등원 전에 배정된 숙제의 첫 검사가 있는지.
///
/// 수업 중 생성된 assignment의 첫 검사는 숙제가 아니라 수업 과제 검사다.
/// 서버 `_lesson_record_compute`와 동일하게 배정 시각이 수업 시작보다 이른
/// assignment만 숙제로 인정한다.
@visibleForTesting
bool hasFirstPreClassAssignmentCheckOn({
  required List<HomeworkAssignmentCheck> checks,
  required Map<String, HomeworkAssignmentBrief> assignmentsById,
  required DateTime day,
  required DateTime sessionStart,
}) {
  for (final c in checks) {
    if (!_isSameDay(c.checkedAt, day)) continue;
    final assignmentId = (c.assignmentId ?? '').trim();
    if (assignmentId.isEmpty) continue;
    final assignment = assignmentsById[assignmentId];
    if (assignment == null || !assignment.assignedAt.isBefore(sessionStart)) {
      continue;
    }
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
      msByGroup[key] =
          (msByGroup[key] ?? 0) + to.difference(from).inMilliseconds;
    }

    for (final ev in events) {
      final key = groupKeyByItem[ev.itemId];
      if (key == null) continue;
      if (ev.phase == 2) {
        for (final other in cycleStartByGroup.keys.toList()) {
          if (other != key) closeCycle(other, ev.at);
        }
        runningChildrenByGroup
            .putIfAbsent(key, () => <String>{})
            .add(ev.itemId);
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
  final assignmentsById = <String, HomeworkAssignmentBrief>{
    for (final assignments in assignmentsByItem.values)
      for (final assignment in assignments) assignment.id: assignment,
  };
  final sessionStart = arrivalTime ?? classDateTime;
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
      final hasFirstCheckToday = hasFirstPreClassAssignmentCheckOn(
        checks: checks,
        assignmentsById: assignmentsById,
        day: classDateTime,
        sessionStart: sessionStart,
      );
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
        !hasFirstPreClassAssignmentCheckOn(
          checks: checks,
          assignmentsById: assignmentsById,
          day: classDateTime,
          sessionStart: sessionStart,
        )) {
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
      final isActive =
          assignment.status == 'assigned' || assignment.status == 'in_progress';
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
    final bookText = bookAndCourse.trim().isEmpty ? '-' : bookAndCourse.trim();
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
  final bytes = await _renderTodoSheetRefined(payload);
  final dir = await getTemporaryDirectory();
  final outPath = p.join(
    dir.path,
    'homework_todo_${DateTime.now().millisecondsSinceEpoch}.pdf',
  );
  await File(outPath).writeAsBytes(bytes, flush: true);
  return outPath;
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
