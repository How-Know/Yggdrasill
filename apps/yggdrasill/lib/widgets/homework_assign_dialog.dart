import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import '../models/attendance_record.dart';
import '../models/student_time_block.dart';
import '../services/data_manager.dart';
import '../services/homework_assignment_store.dart';
import '../services/homework_store.dart';
import '../services/print_routing_service.dart';
import '../services/student_behavior_assignment_store.dart';
import '../services/tag_store.dart';
import '../widgets/dialog_tokens.dart';

class HomeworkAssignSelection {
  final List<String> itemIds;
  final DateTime? dueDate;
  final bool printTodoOnConfirm;
  final List<String> selectedBehaviorIds;
  final Map<String, int> irregularBehaviorCounts;
  const HomeworkAssignSelection({
    required this.itemIds,
    required this.dueDate,
    this.printTodoOnConfirm = false,
    this.selectedBehaviorIds = const <String>[],
    this.irregularBehaviorCounts = const <String, int>{},
  });
}

class _SessionOption {
  final DateTime dateTime;
  final String label;
  const _SessionOption(this.dateTime, this.label);
}

class _TodoListEntry {
  final String primary;
  final String? secondary;
  const _TodoListEntry({required this.primary, this.secondary});
}

class _CheckRateEntry {
  final String title;
  final int? progress;
  final String bookAndCourse;
  final String page;
  final String count;
  final DateTime? assignedAt;
  const _CheckRateEntry({
    required this.title,
    required this.progress,
    required this.bookAndCourse,
    required this.page,
    required this.count,
    required this.assignedAt,
  });
}

class _ClassWorkEntry {
  final String title;
  final String bookAndCourse;
  final String page;
  final String count;
  final DateTime? assignedAt;
  final int studyMs;
  const _ClassWorkEntry({
    required this.title,
    required this.bookAndCourse,
    required this.page,
    required this.count,
    required this.assignedAt,
    required this.studyMs,
  });
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
  final List<_CheckRateEntry> checkRates;
  final List<_ClassWorkEntry> classWorkEntries;
  final List<_TodoListEntry> completedEntries;
  final List<_TodoListEntry> todoEntries;
  final List<_TodoListEntry> behaviorEntries;
  final String behaviorFeedback;

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
    required this.checkRates,
    required this.classWorkEntries,
    required this.completedEntries,
    required this.todoEntries,
    required this.behaviorEntries,
    required this.behaviorFeedback,
  });
}

Future<HomeworkAssignSelection?> showHomeworkAssignDialog(
  BuildContext context,
  String studentId, {
  DateTime? anchorTime,
}) async {
  final allItems = HomeworkStore.instance.items(studentId);
  if (allItems.isEmpty) return null;
  final behaviorAssignments = await StudentBehaviorAssignmentStore.instance
      .loadForStudent(studentId, force: true);
  behaviorAssignments.sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
  String two(int v) => v.toString().padLeft(2, '0');
  const week = ['월', '화', '수', '목', '금', '토', '일'];
  String formatSessionLabel(DateTime dt, {int? order}) {
    final orderText = order != null ? ' · ${order}회차' : '';
    return '${two(dt.month)}.${two(dt.day)} (${week[dt.weekday - 1]}) ${two(dt.hour)}:${two(dt.minute)}$orderText';
  }

  final anchor = anchorTime ?? DateTime.now();
  final Set<int> seenKeys = <int>{};
  int keyOf(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day, dt.hour, dt.minute)
          .millisecondsSinceEpoch;

  final List<_SessionOption> options = [];
  void addOption(DateTime dt, {int? order}) {
    if (!dt.isAfter(anchor)) return;
    final key = keyOf(dt);
    if (seenKeys.contains(key)) return;
    seenKeys.add(key);
    options.add(_SessionOption(dt, formatSessionLabel(dt, order: order)));
  }

  final records = DataManager.instance.attendanceRecords
      .where((r) => r.studentId == studentId)
      .toList()
    ..sort((a, b) => a.classDateTime.compareTo(b.classDateTime));
  for (final r in records) {
    addOption(r.classDateTime, order: r.sessionOrder);
  }

  // Fallback: 같은 날짜(오늘) 블록을 직접 후보에 추가
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
  final groupedStarts = <DateTime>[];
  final groupedOrderByMinuteKey = <int, int?>{};
  for (final group in blocksBySessionKey.values) {
    group.sort((a, b) {
      if (a.startHour != b.startHour) return a.startHour - b.startHour;
      return a.startMinute - b.startMinute;
    });
    final first = group.first;
    final dt = DateTime(
      day.year,
      day.month,
      day.day,
      first.startHour,
      first.startMinute,
    );
    groupedStarts.add(dt);
    groupedOrderByMinuteKey[keyOf(dt)] = first.number ?? first.weeklyOrder;
  }
  groupedStarts.sort((a, b) => a.compareTo(b));
  for (int i = 0; i < groupedStarts.length; i++) {
    final dt = groupedStarts[i];
    final order = groupedOrderByMinuteKey[keyOf(dt)];
    addOption(dt, order: order ?? (i + 1));
  }

  options.sort((a, b) => a.dateTime.compareTo(b.dateTime));
  final nextSessions = options.length > 12 ? options.sublist(0, 12) : options;
  DateTime? selectedDueDate =
      nextSessions.isNotEmpty ? nextSessions.first.dateTime : null;
  final Map<String, bool> selected = {
    for (final e in allItems) e.id: e.status != HomeworkStatus.completed,
  };
  final Map<String, bool> selectedBehaviors = {
    for (final b in behaviorAssignments) b.id: !b.isIrregular,
  };
  final Map<String, int> irregularBehaviorCounts = {
    for (final b in behaviorAssignments.where((e) => e.isIrregular)) b.id: 1,
  };
  bool printTodoOnConfirm = false;
  bool previewing = false;
  return showDialog<HomeworkAssignSelection>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          final List<HomeworkItem> visibleItems =
              List<HomeworkItem>.from(allItems);
          final media = MediaQuery.of(ctx);
          final homeworkListMaxHeight = math.max(
            180.0,
            math.min(430.0, media.size.height * 0.42),
          );
          final behaviorListMaxHeight = math.max(
            160.0,
            math.min(360.0, media.size.height * 0.34),
          );
          final dialogContentMaxHeight = math.max(
            420.0,
            math.min(media.size.height * 0.78, 920.0),
          );
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('숙제 선택',
                style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
            content: SizedBox(
              width: 520,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: dialogContentMaxHeight),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  const YggDialogSectionHeader(
                    icon: Icons.event,
                    title: '검사 날짜',
                  ),
                  if (nextSessions.isEmpty)
                    const Text(
                      '예정 수업이 없습니다. 검사 날짜는 미정으로 처리됩니다.',
                      style: TextStyle(color: kDlgTextSub),
                    )
                  else
                    DropdownButtonFormField<DateTime?>(
                      value: selectedDueDate,
                      items: [
                        for (final opt in nextSessions)
                          DropdownMenuItem<DateTime?>(
                            value: opt.dateTime,
                            child: Text(
                              opt.label,
                              style: const TextStyle(
                                color: kDlgText,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        setState(() {
                          selectedDueDate = v;
                        });
                      },
                      dropdownColor: kDlgBg,
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: kDlgFieldBg,
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(color: kDlgBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: const BorderSide(
                            color: kDlgAccent,
                            width: 1.4,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                      iconEnabledColor: kDlgTextSub,
                    ),
                  const SizedBox(height: 16),
                  const YggDialogSectionHeader(
                      icon: Icons.assignment_turned_in, title: '등록된 과제'),
                  if (visibleItems.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: kDlgPanelBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: kDlgBorder),
                      ),
                      child: const Text(
                        '표시할 과제가 없습니다.',
                        style: TextStyle(color: kDlgTextSub, fontSize: 13),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: homeworkListMaxHeight),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: visibleItems.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (ctx, idx) {
                          final hw = visibleItems[idx];
                          final bool isCompleted =
                              hw.status == HomeworkStatus.completed;
                          final String type = (hw.type ?? '').trim();
                          final String page = (hw.page ?? '').trim();
                          final String count =
                              hw.count != null ? hw.count.toString() : '';
                          final String title = hw.title.trim();
                          final String meta = [
                            if (isCompleted) '완료 ${hw.checkCount}회',
                            if (type.isNotEmpty) type,
                            if (page.isNotEmpty) 'p.$page',
                            if (count.isNotEmpty) '${count}문항',
                          ].join(' · ');
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: kDlgPanelBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: kDlgBorder),
                            ),
                            child: CheckboxListTile(
                              value: selected[hw.id] ?? false,
                              onChanged: (v) {
                                setState(() {
                                  selected[hw.id] = v ?? false;
                                });
                              },
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              activeColor: kDlgAccent,
                              checkColor: Colors.white,
                              title: Text(
                                title,
                                style: TextStyle(
                                  color: isCompleted
                                      ? kDlgTextSub
                                      : kDlgText,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: meta.isEmpty
                                  ? null
                                  : Text(
                                      meta,
                                      style: const TextStyle(
                                        color: kDlgTextSub,
                                        fontSize: 12,
                                      ),
                                    ),
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 16),
                  const YggDialogSectionHeader(
                    icon: Icons.self_improvement_rounded,
                    title: '행동 리스트',
                  ),
                  if (behaviorAssignments.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: kDlgPanelBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: kDlgBorder),
                      ),
                      child: const Text(
                        '학생에게 부여된 행동이 없습니다.',
                        style: TextStyle(color: kDlgTextSub, fontSize: 13),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: behaviorListMaxHeight),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: behaviorAssignments.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (ctx, idx) {
                          final behavior = behaviorAssignments[idx];
                          final bool selectedNow =
                              selectedBehaviors[behavior.id] ?? false;
                          final int level = behavior.safeSelectedLevelIndex + 1;
                          final String levelText =
                              behavior.selectedLevelText.trim();
                          final int count =
                              irregularBehaviorCounts[behavior.id] ?? 1;
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: kDlgPanelBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: kDlgBorder),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Checkbox(
                                  value: selectedNow,
                                  onChanged: (v) {
                                    setState(() {
                                      selectedBehaviors[behavior.id] =
                                          v ?? false;
                                    });
                                  },
                                  activeColor: kDlgAccent,
                                  checkColor: Colors.white,
                                ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Row(
                                                children: [
                                                  Flexible(
                                                    child: Text(
                                                      behavior.name,
                                                      style: const TextStyle(
                                                        color: kDlgText,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 14,
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                  if (behavior.isIrregular) ...[
                                                    const SizedBox(width: 8),
                                                    const Text(
                                                      '비정기',
                                                      style: TextStyle(
                                                        color:
                                                            Color(0xFFF2B56B),
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                            if (!behavior.isIrregular)
                                              Text(
                                                '${behavior.repeatDays}일 주기',
                                                style: const TextStyle(
                                                  color: kDlgTextSub,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'lv.$level${levelText.isEmpty ? '' : ' · $levelText'}',
                                          style: const TextStyle(
                                            color: kDlgTextSub,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                if (behavior.isIrregular) ...[
                                  const SizedBox(width: 8),
                                  Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      IconButton(
                                        onPressed: selectedNow && count < 20
                                            ? () {
                                                setState(() {
                                                  irregularBehaviorCounts[
                                                      behavior.id] = count + 1;
                                                });
                                              }
                                            : null,
                                        icon: const Icon(
                                          Icons.keyboard_arrow_up_rounded,
                                          size: 18,
                                        ),
                                        color: kDlgTextSub,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                            minWidth: 24, minHeight: 24),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      Text(
                                        '${count}회',
                                        style: TextStyle(
                                          color: selectedNow
                                              ? kDlgText
                                              : kDlgTextSub,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: selectedNow && count > 1
                                            ? () {
                                                setState(() {
                                                  irregularBehaviorCounts[
                                                      behavior.id] = count - 1;
                                                });
                                              }
                                            : null,
                                        icon: const Icon(
                                          Icons.keyboard_arrow_down_rounded,
                                          size: 18,
                                        ),
                                        color: kDlgTextSub,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(
                                            minWidth: 24, minHeight: 24),
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: CheckboxListTile(
                          value: printTodoOnConfirm,
                          onChanged: (v) {
                            setState(() {
                              printTodoOnConfirm = v ?? false;
                            });
                          },
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          activeColor: kDlgAccent,
                          checkColor: Colors.white,
                          title: const Text(
                            '알림장 인쇄',
                            style: TextStyle(
                              color: kDlgText,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: const Text(
                            '확인 시 학습 리포트 + 숙제/행동 리스트를 바로 인쇄합니다.',
                            style: TextStyle(
                              color: kDlgTextSub,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 128,
                        height: 45,
                        child: OutlinedButton.icon(
                          onPressed: previewing
                              ? null
                              : () async {
                                  setState(() {
                                    previewing = true;
                                  });
                                  try {
                                    final ids = selected.entries
                                        .where((e) => e.value)
                                        .map((e) => e.key)
                                        .toList();
                                    final selectedBehaviorIds =
                                        selectedBehaviors.entries
                                            .where((e) => e.value)
                                            .map((e) => e.key)
                                            .toList();
                                    final irregularCounts = <String, int>{};
                                    for (final behavior
                                        in behaviorAssignments) {
                                      if (!behavior.isIrregular) continue;
                                      if (!(selectedBehaviors[behavior.id] ??
                                          false)) {
                                        continue;
                                      }
                                      irregularCounts[behavior.id] =
                                          (irregularBehaviorCounts[
                                                      behavior.id] ??
                                                  1)
                                              .clamp(1, 20)
                                              .toInt();
                                    }
                                    final baseDate = anchorTime ??
                                        selectedDueDate ??
                                        DateTime.now();
                                    DateTime? arrival;
                                    DateTime? classEnd;
                                    String? className;
                                    String? setId;
                                    for (final rec in DataManager
                                        .instance.attendanceRecords) {
                                      if (rec.studentId != studentId) continue;
                                      if (!_isSameDay(
                                          rec.classDateTime, baseDate))
                                        continue;
                                      arrival = rec.arrivalTime;
                                      classEnd = rec.classEndTime;
                                      className = rec.className;
                                      setId = rec.setId;
                                      break;
                                    }
                                    await previewHomeworkTodoSheet(
                                      studentId: studentId,
                                      studentName:
                                          _resolveStudentName(studentId),
                                      classDateTime: baseDate,
                                      arrivalTime: arrival,
                                      departureTime: DateTime.now(),
                                      selectedHomeworkIds: ids,
                                      selectedBehaviorIds: selectedBehaviorIds,
                                      irregularBehaviorCounts: irregularCounts,
                                      dueDate: selectedDueDate,
                                      className: className,
                                      classEndTime: classEnd,
                                      setId: setId,
                                    );
                                  } finally {
                                    if (ctx.mounted) {
                                      setState(() {
                                        previewing = false;
                                      });
                                    }
                                  }
                                },
                          icon: Icon(
                            previewing
                                ? Icons.hourglass_bottom_rounded
                                : Icons.preview_outlined,
                            size: 16,
                          ),
                          label: Text(previewing ? '준비중' : '미리보기'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: kDlgTextSub,
                            side: const BorderSide(color: kDlgBorder),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () {
                  final ids = selected.entries
                      .where((e) => e.value)
                      .map((e) => e.key)
                      .toList();
                  final selectedBehaviorIds = selectedBehaviors.entries
                      .where((e) => e.value)
                      .map((e) => e.key)
                      .toList();
                  final irregularCounts = <String, int>{};
                  for (final behavior in behaviorAssignments) {
                    if (!behavior.isIrregular) continue;
                    if (!(selectedBehaviors[behavior.id] ?? false)) continue;
                    irregularCounts[behavior.id] =
                        (irregularBehaviorCounts[behavior.id] ?? 1)
                            .clamp(1, 20)
                            .toInt();
                  }
                  Navigator.of(ctx).pop(HomeworkAssignSelection(
                    itemIds: ids,
                    dueDate: selectedDueDate,
                    printTodoOnConfirm: printTodoOnConfirm,
                    selectedBehaviorIds: selectedBehaviorIds,
                    irregularBehaviorCounts: irregularCounts,
                  ));
                },
                style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
                child: const Text('확인'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<void> printHomeworkTodoSheet({
  required String studentId,
  required String studentName,
  required DateTime classDateTime,
  DateTime? arrivalTime,
  required DateTime departureTime,
  required List<String> selectedHomeworkIds,
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
}

Future<void> previewHomeworkTodoSheet({
  required String studentId,
  required String studentName,
  required DateTime classDateTime,
  DateTime? arrivalTime,
  required DateTime departureTime,
  required List<String> selectedHomeworkIds,
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

String _resolveStudentName(String studentId) {
  try {
    final row = DataManager.instance.students.firstWhere(
      (s) => s.student.id == studentId,
    );
    final name = row.student.name.trim();
    if (name.isNotEmpty) return name;
  } catch (_) {}
  return '학생';
}

bool _isSameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

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

String _formatDurationKorean(int ms) {
  if (ms <= 0) return '0분';
  final d = Duration(milliseconds: ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0) return '$h시간 ${m}분';
  return '${d.inMinutes}분';
}

String _formatDate(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}.${two(dt.month)}.${two(dt.day)}';
}

String _formatMonthDay(DateTime dt) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.month)}.${two(dt.day)}';
}

String _formatPageText(String rawPage) {
  final page = rawPage.trim();
  if (page.isEmpty || page == '-') return '-';
  return 'p. $page';
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
  if (dt == null) return '--.-- --:--';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.month)}.${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

String _formatTime(DateTime? dt) {
  if (dt == null) return '--:--';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(dt.hour)}:${two(dt.minute)}';
}

String _formatWeekdayKorean(DateTime dt) {
  const week = ['월', '화', '수', '목', '금', '토', '일'];
  return week[dt.weekday - 1];
}

String _formatClassTimeRange(DateTime start, DateTime? end) {
  final endText = _formatTime(end ?? start.add(const Duration(hours: 2)));
  return '${_formatWeekdayKorean(start)}요일 ${_formatTime(start)} - $endText';
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

int _estimateLearningMsForDate({
  required String studentId,
  required DateTime classDateTime,
  required DateTime departureTime,
}) {
  int total = 0;
  for (final hw in HomeworkStore.instance.items(studentId)) {
    final started = hw.firstStartedAt;
    final submitted = hw.submittedAt;
    if (started != null &&
        submitted != null &&
        _isSameDay(started, classDateTime) &&
        _isSameDay(submitted, classDateTime) &&
        submitted.isAfter(started)) {
      total += submitted.difference(started).inMilliseconds;
      continue;
    }
    if (hw.runStart != null && _isSameDay(hw.runStart!, classDateTime)) {
      total += departureTime.difference(hw.runStart!).inMilliseconds;
      continue;
    }
    final touched = (hw.submittedAt != null &&
            _isSameDay(hw.submittedAt!, classDateTime)) ||
        (hw.confirmedAt != null &&
            _isSameDay(hw.confirmedAt!, classDateTime)) ||
        (hw.waitingAt != null && _isSameDay(hw.waitingAt!, classDateTime)) ||
        (hw.completedAt != null && _isSameDay(hw.completedAt!, classDateTime));
    if (touched && hw.accumulatedMs > 0) {
      total += hw.accumulatedMs;
    }
  }
  return total.clamp(0, 1000 * 60 * 60 * 24);
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
  final started = hw.firstStartedAt;
  if (started != null && _isSameDay(started, classDateTime)) {
    final endCandidates = <DateTime>[
      if (hw.submittedAt != null) hw.submittedAt!,
      if (hw.completedAt != null) hw.completedAt!,
      if (hw.confirmedAt != null) hw.confirmedAt!,
      if (hw.waitingAt != null) hw.waitingAt!,
    ]..sort((a, b) => a.compareTo(b));
    final end = endCandidates.isNotEmpty ? endCandidates.first : departureTime;
    if (end.isAfter(started)) {
      return end.difference(started).inMilliseconds.clamp(0, 1000 * 60 * 60 * 24);
    }
  }
  final running = hw.runStart;
  if (running != null && _isSameDay(running, classDateTime)) {
    return departureTime.difference(running).inMilliseconds.clamp(0, 1000 * 60 * 60 * 24);
  }
  if (_hasTodayHomeworkActivity(hw, classDateTime) && hw.accumulatedMs > 0) {
    return hw.accumulatedMs.clamp(0, 1000 * 60 * 60 * 24);
  }
  return 0;
}

Future<_TodoSheetPayload> _prepareTodoSheetPayload({
  required String studentId,
  required String studentName,
  required DateTime classDateTime,
  DateTime? arrivalTime,
  required DateTime departureTime,
  required List<String> selectedHomeworkIds,
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
  final assignmentsByItem =
      await HomeworkAssignmentStore.instance.loadAssignmentsForStudent(studentId);
  final latestAssignmentByItem = <String, HomeworkAssignmentBrief>{};
  final assignmentById = <String, HomeworkAssignmentBrief>{};
  for (final entry in assignmentsByItem.entries) {
    final sorted = List<HomeworkAssignmentBrief>.from(entry.value)
      ..sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
    if (sorted.isNotEmpty) {
      latestAssignmentByItem[entry.key] = sorted.last;
    }
    for (final brief in sorted) {
      assignmentById[brief.id] = brief;
    }
  }

  final checkRates = <_CheckRateEntry>[];
  for (final entry in checksByItem.entries) {
    final todays = entry.value
        .where((c) => _isSameDay(c.checkedAt, classDateTime))
        .toList()
      ..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
    if (todays.isEmpty) continue;
    final latest = todays.last;
    final hw = HomeworkStore.instance.getById(studentId, entry.key);
    final latestAssignmentId = (latest.assignmentId ?? '').trim();
    final assignedBrief = latestAssignmentId.isNotEmpty
        ? assignmentById[latestAssignmentId] ?? latestAssignmentByItem[entry.key]
        : latestAssignmentByItem[entry.key];
    final title =
        (hw?.title.trim().isNotEmpty ?? false) ? hw!.title.trim() : '과제';
    final bookAndCourse = hw == null ? '교재 미기재' : _formatBookAndCourseFromHomework(hw);
    final page = (hw?.page ?? '').trim();
    final hwCount = hw?.count;
    final count = (hwCount != null && hwCount > 0) ? hwCount.toString() : '-';
    checkRates.add(
      _CheckRateEntry(
        title: title,
        progress: latest.progress,
        bookAndCourse: bookAndCourse,
        page: page.isEmpty ? '-' : page,
        count: count,
        assignedAt: assignedBrief?.assignedAt,
      ),
    );
  }
  if (checkRates.isEmpty) {
    checkRates.add(
      const _CheckRateEntry(
        title: '숙제 없음',
        progress: null,
        bookAndCourse: '',
        page: '-',
        count: '-',
        assignedAt: null,
      ),
    );
  }

  final classWorkEntries = <_ClassWorkEntry>[];
  for (final hw in HomeworkStore.instance.items(studentId)) {
    final studyMs = _estimateLearningMsForItemToday(
      hw: hw,
      classDateTime: classDateTime,
      departureTime: departureTime,
    );
    if (!_hasTodayHomeworkActivity(hw, classDateTime) && studyMs <= 0) continue;
    final title = hw.title.trim().isEmpty ? '과제' : hw.title.trim();
    final page = (hw.page ?? '').trim();
    final count = (hw.count != null && hw.count! > 0) ? hw.count!.toString() : '-';
    classWorkEntries.add(
      _ClassWorkEntry(
        title: title,
        bookAndCourse: _formatBookAndCourseFromHomework(hw),
        page: page.isEmpty ? '-' : page,
        count: count,
        assignedAt: latestAssignmentByItem[hw.id]?.assignedAt,
        studyMs: studyMs,
      ),
    );
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
    final pageText =
        (hw.page ?? '').trim().isEmpty ? 'p.-' : 'p.${hw.page!.trim()}';
    final attempts = hw.checkCount <= 0 ? 1 : hw.checkCount;
    completedEntries.add(
      _TodoListEntry(
        primary: '• ${_extractBookNameFromHomework(hw)} · $pageText',
        secondary:
            '  출제 ${_formatDateTime(hw.createdAt)} · ${attempts}번째 검사 통과',
      ),
    );
  }
  if (completedEntries.isEmpty) {
    completedEntries.add(const _TodoListEntry(primary: '• 숙제 없음'));
  }

  final todoEntries = <_TodoListEntry>[];
  for (final id in selectedHomeworkIds) {
    final hw = HomeworkStore.instance.getById(studentId, id);
    if (hw == null) continue;
    final title = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
    final pageRaw = (hw.page ?? '').trim();
    final bookAndCourse = _formatBookAndCourseFromHomework(hw);
    final countText = (hw.count != null && hw.count! > 0) ? hw.count.toString() : '-';
    final assignedAt = latestAssignmentByItem[id]?.assignedAt;
    final assignedDateText = assignedAt == null ? '--.--' : _formatMonthDay(assignedAt);
    final details = [
      _formatPageText(pageRaw),
      _formatCountText(countText),
      assignedDateText,
    ].join(' · ');
    todoEntries.add(
      _TodoListEntry(
        primary: '□ $bookAndCourse · $title',
        secondary: '  $details',
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

  final learningMs = _estimateLearningMsForDate(
    studentId: studentId,
    classDateTime: classDateTime,
    departureTime: departureTime,
  );

  AttendanceRecord? matchedRecord;
  for (final rec in DataManager.instance.attendanceRecords) {
    if (rec.studentId != studentId) continue;
    if (!_isSameDay(rec.classDateTime, classDateTime)) continue;
    matchedRecord = rec;
    if (rec.classDateTime == classDateTime) break;
  }
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
  final resolvedArrival = arrivalTime ?? matchedRecord?.arrivalTime;
  final explicitSetId = (setId ?? '').trim();
  final resolvedSetId = explicitSetId.isNotEmpty
      ? explicitSetId
      : (matchedRecord?.setId ?? '').trim();

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
    checkRates: checkRates,
    classWorkEntries: classWorkEntries,
    completedEntries: completedEntries,
    todoEntries: todoEntries,
    behaviorEntries: behaviorTodoEntries,
    behaviorFeedback: _buildBehaviorFeedback(
      studentId: studentId,
      classDateTime: classDateTime,
      setId: resolvedSetId,
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

Future<String> _buildHomeworkTodoPdf({
  required _TodoSheetPayload payload,
}) async {
  final doc = sf.PdfDocument();
  doc.pageSettings.orientation = sf.PdfPageOrientation.portrait;
  doc.pageSettings.margins.all = 18;
  final page = doc.pages.add();
  final size = page.getClientSize();
  final graphics = page.graphics;
  final titleFont = await _loadTodoPdfFont(16, bold: true);
  final sectionFont = await _loadTodoPdfFont(12.2, bold: true);
  final bodyFont = await _loadTodoPdfFont(10.2);
  final subFont = await _loadTodoPdfFont(9.2);
  final labelFont = await _loadTodoPdfFont(9.8);
  final valueFont = await _loadTodoPdfFont(11.2, bold: true);
  final textBrush = sf.PdfSolidBrush(sf.PdfColor(28, 28, 28));
  final subBrush = sf.PdfSolidBrush(sf.PdfColor(95, 95, 95));
  final linePen = sf.PdfPen(sf.PdfColor(178, 178, 178), width: 1.05);
  final weakLinePen = sf.PdfPen(sf.PdfColor(222, 222, 222), width: 0.6);

  final left = 10.0;
  final right = size.width - 10;
  final contentWidth = right - left;
  final top = 6.0;
  final bottom = size.height - 6;

  void drawLabelValue({
    required String label,
    required String value,
    required double x,
    required double y,
    required double maxWidth,
    double valueGap = 4,
  }) {
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

  const double headerH = 116;
  final headerBottom = top + headerH;
  graphics.drawLine(
      linePen, Offset(left, headerBottom), Offset(right, headerBottom));

  double headerTextX = left + 2;
  if (payload.academyLogo != null && payload.academyLogo!.isNotEmpty) {
    try {
      final logo = sf.PdfBitmap(payload.academyLogo!);
      const boxW = 40.0;
      const boxH = 40.0;
      final rawW = logo.width.toDouble();
      final rawH = logo.height.toDouble();
      final scale = math.min(boxW / rawW, boxH / rawH);
      final drawW = rawW * scale;
      final drawH = rawH * scale;
      final drawX = left + 1 + (boxW - drawW) / 2;
      final drawY = top + 2 + (boxH - drawH) / 2;
      graphics.drawImage(logo, Rect.fromLTWH(drawX, drawY, drawW, drawH));
      headerTextX = left + 48;
    } catch (_) {}
  }
  graphics.drawString(
    payload.academyName,
    titleFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(headerTextX, top + 2, right - headerTextX, 22),
  );
  graphics.drawString(
    '학습 리포트',
    bodyFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(headerTextX, top + 24, right - headerTextX, 16),
  );

  graphics.drawString(
    '일자 ${_formatDate(payload.classDateTime)}',
    labelFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(right - 130, top + 8, 130, 14),
    format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right),
  );

  // 타이틀-학생/수업 간격은 늘리고, 학생/수업-등하원 간격은 줄인 배치
  final infoY1 = top + 52;
  final infoY3 = top + 80;
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
  final classNameMaxW = rightInfoW * 0.30;
  graphics.drawString(
    payload.className,
    valueFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(classNameX, infoY1 - 1, classNameMaxW, 18),
  );
  final measuredClassNameW = valueFont.measureString(payload.className).width;
  final classNameUsedW = math.min(measuredClassNameW, classNameMaxW);
  final classTimeXRaw = classNameX + classNameUsedW + 14;
  final classTimeX = math.min(classTimeXRaw, rightInfoX + rightInfoW - 176);
  graphics.drawString(
    payload.classTimeText,
    bodyFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(
      classTimeX,
      infoY1 + 1,
      rightInfoX + rightInfoW - classTimeX,
      16,
    ),
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

  final contentTop = headerBottom + 10;
  final contentBottom = bottom;
  final foldY = size.height / 2;
  final topBottomLimit = foldY - 6;

  graphics.drawString(
    '학습 내역',
    sectionFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(left, contentTop, contentWidth, 18),
  );

  final topSectionTop = contentTop + 30;
  const topColGap = 12.0;
  final topColWidth = (contentWidth - topColGap) / 2;
  final topLeftX = left;
  final topRightX = left + topColWidth + topColGap;
  const topTitleHeight = 16.0;
  const topRowHeight = 31.0;
  const topRowGap = 5.0;
  final topRowsBottomLimit = topBottomLimit - 4;

  void drawTopRow({
    required double x,
    required double y,
    required double colWidth,
    required String leftTop,
    required String rightTop,
    required String leftBottom,
    required String rightBottom,
  }) {
    final rightCellW = colWidth * 0.40;
    final leftCellW = colWidth - rightCellW - 8;
    graphics.drawString(
      leftTop,
      bodyFont,
      brush: textBrush,
      bounds: Rect.fromLTWH(x + 2, y, leftCellW, 14),
    );
    graphics.drawString(
      rightTop,
      bodyFont,
      brush: textBrush,
      bounds: Rect.fromLTWH(x + leftCellW + 10, y, rightCellW - 2, 14),
      format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right),
    );
    graphics.drawString(
      leftBottom,
      subFont,
      brush: subBrush,
      bounds: Rect.fromLTWH(x + 2, y + 14, leftCellW, 13),
    );
    graphics.drawString(
      rightBottom,
      subFont,
      brush: subBrush,
      bounds: Rect.fromLTWH(x + leftCellW + 10, y + 14, rightCellW - 2, 13),
      format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right),
    );
    graphics.drawLine(
      weakLinePen,
      Offset(x, y + topRowHeight),
      Offset(x + colWidth, y + topRowHeight),
    );
  }

  graphics.drawString(
    '숙제',
    valueFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(topLeftX, topSectionTop, topColWidth, topTitleHeight),
  );
  graphics.drawString(
    '수업',
    valueFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(topRightX, topSectionTop, topColWidth, topTitleHeight),
  );
  graphics.drawLine(
    weakLinePen,
    Offset(topLeftX, topSectionTop + topTitleHeight),
    Offset(topLeftX + topColWidth, topSectionTop + topTitleHeight),
  );
  graphics.drawLine(
    weakLinePen,
    Offset(topRightX, topSectionTop + topTitleHeight),
    Offset(topRightX + topColWidth, topSectionTop + topTitleHeight),
  );
  graphics.drawLine(
    weakLinePen,
    Offset(topRightX - (topColGap / 2), topSectionTop),
    Offset(topRightX - (topColGap / 2), topBottomLimit),
  );

  double leftRowsY = topSectionTop + topTitleHeight + 4;
  for (final line in payload.checkRates) {
    if (leftRowsY + topRowHeight > topRowsBottomLimit) break;
    final pageValue = _formatPageText(line.page);
    final countValue = _formatCountText(line.count);
    final dateValue =
        line.assignedAt == null ? '--.--' : _formatMonthDay(line.assignedAt!);
    drawTopRow(
      x: topLeftX,
      y: leftRowsY,
      colWidth: topColWidth,
      leftTop: line.bookAndCourse.trim().isEmpty ? '-' : line.bookAndCourse.trim(),
      rightTop: line.title.trim().isEmpty ? '-' : line.title.trim(),
      leftBottom: '$pageValue · $countValue · $dateValue',
      rightBottom: line.progress == null ? '-' : '${line.progress}%',
    );
    leftRowsY += topRowHeight + topRowGap;
  }

  double rightRowsY = topSectionTop + topTitleHeight + 4;
  if (payload.classWorkEntries.isEmpty) {
    graphics.drawString(
      '• 오늘 수행 기록 없음',
      bodyFont,
      brush: subBrush,
      bounds: Rect.fromLTWH(topRightX + 2, rightRowsY + 4, topColWidth - 4, 14),
    );
  } else {
    for (final line in payload.classWorkEntries) {
      if (rightRowsY + topRowHeight > topRowsBottomLimit) break;
      final pageValue = _formatPageText(line.page);
      final countValue = _formatCountText(line.count);
      final timeValue =
          line.assignedAt == null ? '--:--' : _formatTime(line.assignedAt);
      drawTopRow(
        x: topRightX,
        y: rightRowsY,
        colWidth: topColWidth,
        leftTop: line.bookAndCourse.trim().isEmpty ? '-' : line.bookAndCourse.trim(),
        rightTop: line.title.trim().isEmpty ? '-' : line.title.trim(),
        leftBottom: '$pageValue · $countValue · $timeValue',
        rightBottom: line.studyMs > 0 ? _formatDurationKorean(line.studyMs) : '-',
      );
      rightRowsY += topRowHeight + topRowGap;
    }
  }

  final todoTop = foldY + 26;
  final colGap = 10.0;
  final colWidth = (contentWidth - colGap) / 2;
  final leftColX = left;
  final rightColX = left + colWidth + colGap;

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
  graphics.drawLine(weakLinePen, Offset(leftColX, todoTop + 18),
      Offset(leftColX + colWidth, todoTop + 18));
  graphics.drawLine(weakLinePen, Offset(rightColX, todoTop + 18),
      Offset(rightColX + colWidth, todoTop + 18));
  graphics.drawLine(weakLinePen, Offset(rightColX - (colGap / 2), todoTop),
      Offset(rightColX - (colGap / 2), contentBottom));

  double leftY = todoTop + 24;
  for (final entry in payload.todoEntries) {
    graphics.drawString(
      entry.primary,
      bodyFont,
      brush: textBrush,
      bounds: Rect.fromLTWH(leftColX + 2, leftY, colWidth - 4, 14),
    );
    leftY += 14;
    if (entry.secondary != null && entry.secondary!.trim().isNotEmpty) {
      graphics.drawString(
        entry.secondary!,
        subFont,
        brush: subBrush,
        bounds: Rect.fromLTWH(leftColX + 2, leftY, colWidth - 4, 13),
      );
      leftY += 13;
    }
    leftY += 8;
    if (leftY > contentBottom - 8) break;
  }

  double rightY = todoTop + 24;
  final behaviorEntries = payload.behaviorEntries;
  if (behaviorEntries.isEmpty) {
    graphics.drawString(
      '• 행동 없음',
      bodyFont,
      brush: subBrush,
      bounds: Rect.fromLTWH(rightColX + 2, rightY, colWidth - 4, 14),
    );
  } else {
    for (final entry in behaviorEntries) {
      graphics.drawString(
        entry.primary,
        bodyFont,
        brush: textBrush,
        bounds: Rect.fromLTWH(rightColX + 2, rightY, colWidth - 4, 14),
      );
      rightY += 14;
      if (entry.secondary != null && entry.secondary!.trim().isNotEmpty) {
        graphics.drawString(
          entry.secondary!,
          subFont,
          brush: subBrush,
          bounds: Rect.fromLTWH(rightColX + 2, rightY, colWidth - 4, 13),
        );
        rightY += 13;
      }
      rightY += 8;
      if (rightY > contentBottom - 8) break;
    }
  }

  final bytes = await doc.save();
  doc.dispose();
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
  await PrintRoutingService.instance.printFile(
    path: path,
    channel: PrintRoutingChannel.todoSheet,
    debugSource: 'homework.todo_sheet',
  );
}
