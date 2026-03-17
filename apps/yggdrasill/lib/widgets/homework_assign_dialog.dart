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
import '../services/resource_service.dart';
import '../services/student_behavior_assignment_store.dart';
import '../services/tag_store.dart';
import '../widgets/dialog_tokens.dart';

class HomeworkAssignSelection {
  final List<String> itemIds;
  final DateTime? dueDate;
  final List<String> selectableItemIds;
  final bool printTodoOnConfirm;
  final List<String> selectedBehaviorIds;
  final Map<String, int> irregularBehaviorCounts;
  const HomeworkAssignSelection({
    required this.itemIds,
    required this.dueDate,
    this.selectableItemIds = const <String>[],
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
  final List<_SubWorkEntry> subEntries;
  const _ClassWorkEntry({
    required this.title,
    required this.bookAndCourse,
    required this.page,
    required this.count,
    required this.assignedAt,
    required this.studyMs,
    this.todayCheckCount = 0,
    this.subEntries = const <_SubWorkEntry>[],
  });
}

class _CompletedSummaryEntry {
  final String groupTitle;
  final String bookAndCourse;
  final int totalMs;
  final int checkCount;
  final double progressPct;
  final String? etaText;
  const _CompletedSummaryEntry({
    required this.groupTitle,
    required this.bookAndCourse,
    required this.totalMs,
    required this.checkCount,
    required this.progressPct,
    this.etaText,
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
  final int learningMs;
  final List<_CheckRateEntry> checkRates;
  final List<_ClassWorkEntry> classWorkEntries;
  final List<_CompletedSummaryEntry> completedSummaries;
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
    required this.learningMs,
    required this.checkRates,
    required this.classWorkEntries,
    this.completedSummaries = const <_CompletedSummaryEntry>[],
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
  final activeAssignments =
      await HomeworkAssignmentStore.instance.loadActiveAssignments(studentId);
  final hiddenAssignedItemIds = activeAssignments
      .map((a) => a.homeworkItemId.trim())
      .where((id) => id.isNotEmpty)
      .toSet();
  // Build group-based selectable entries
  final allGroups = HomeworkStore.instance.groups(studentId);
  final groupEntries = <({HomeworkGroup group, List<HomeworkItem> children})>[];
  final allGroupChildIds = <String>{};
  for (final group in allGroups) {
    final children = HomeworkStore.instance
        .itemsInGroup(studentId, group.id, includeCompleted: true)
        .where((e) => !hiddenAssignedItemIds.contains(e.id))
        .toList();
    if (children.isEmpty) continue;
    groupEntries.add((group: group, children: children));
    for (final c in children) {
      allGroupChildIds.add(c.id);
    }
  }

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
  final Map<String, bool> selectedGroups = {
    for (final entry in groupEntries) entry.group.id: true,
  };
  final Map<String, bool> selected = {
    for (final entry in groupEntries)
      for (final c in entry.children) c.id: true,
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
          final visibleGroups = groupEntries;
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
                      if (visibleGroups.isEmpty)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                              color: kDlgPanelBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: kDlgBorder)),
                          child: const Text('표시할 과제가 없습니다.',
                              style:
                                  TextStyle(color: kDlgTextSub, fontSize: 13)),
                        )
                      else
                        ConstrainedBox(
                          constraints:
                              BoxConstraints(maxHeight: homeworkListMaxHeight),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: visibleGroups.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (ctx, idx) {
                              final entry = visibleGroups[idx];
                              final group = entry.group;
                              final children = entry.children;
                              final bool groupSelected =
                                  selectedGroups[group.id] ?? false;
                              final int totalCount = children.fold<int>(
                                  0, (sum, item) => sum + (item.count ?? 0));
                              final allPages = children
                                  .map((item) => (item.page ?? '').trim())
                                  .where((p) => p.isNotEmpty)
                                  .toList();
                              final String groupTitle =
                                  group.title.trim().isNotEmpty
                                      ? group.title.trim()
                                      : children.first.title.trim();
                              final String meta = [
                                if (children.length > 1)
                                  '하위 ${children.length}개',
                                if (allPages.isNotEmpty)
                                  'p.${allPages.join(", ")}',
                                if (totalCount > 0) '$totalCount문항',
                              ].join(' · ');
                              return Container(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8),
                                decoration: BoxDecoration(
                                    color: kDlgPanelBg,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: kDlgBorder)),
                                child: CheckboxListTile(
                                  value: groupSelected,
                                  onChanged: (v) {
                                    setState(() {
                                      selectedGroups[group.id] = v ?? false;
                                      for (final c in children) {
                                        selected[c.id] = v ?? false;
                                      }
                                    });
                                  },
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  activeColor: kDlgAccent,
                                  checkColor: Colors.white,
                                  title: Text(groupTitle,
                                      style: const TextStyle(
                                          color: kDlgText,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14)),
                                  subtitle: meta.isEmpty
                                      ? null
                                      : Text(meta,
                                          style: const TextStyle(
                                              color: kDlgTextSub,
                                              fontSize: 12)),
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
                          constraints:
                              BoxConstraints(maxHeight: behaviorListMaxHeight),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: behaviorAssignments.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (ctx, idx) {
                              final behavior = behaviorAssignments[idx];
                              final bool selectedNow =
                                  selectedBehaviors[behavior.id] ?? false;
                              final int level =
                                  behavior.safeSelectedLevelIndex + 1;
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
                                                          style:
                                                              const TextStyle(
                                                            color: kDlgText,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            fontSize: 14,
                                                          ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                      ),
                                                      if (behavior
                                                          .isIrregular) ...[
                                                        const SizedBox(
                                                            width: 8),
                                                        const Text(
                                                          '비정기',
                                                          style: TextStyle(
                                                            color: Color(
                                                                0xFFF2B56B),
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
                                                      fontWeight:
                                                          FontWeight.w700,
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
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          IconButton(
                                            onPressed: selectedNow && count < 20
                                                ? () {
                                                    setState(() {
                                                      irregularBehaviorCounts[
                                                              behavior.id] =
                                                          count + 1;
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
                                            visualDensity:
                                                VisualDensity.compact,
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
                                                              behavior.id] =
                                                          count - 1;
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
                                            visualDensity:
                                                VisualDensity.compact,
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
                                          if (!(selectedBehaviors[
                                                  behavior.id] ??
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
                                          if (rec.studentId != studentId)
                                            continue;
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
                                          selectedBehaviorIds:
                                              selectedBehaviorIds,
                                          irregularBehaviorCounts:
                                              irregularCounts,
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
                    selectableItemIds: allGroupChildIds.toList(),
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
  final coveredItemIds = <String>{};
  final groups = HomeworkStore.instance.groups(studentId);
  for (final group in groups) {
    final children = HomeworkStore.instance
        .itemsInGroup(studentId, group.id, includeCompleted: true);
    if (children.isEmpty) continue;
    int groupMs = 0;
    bool hasActivity = false;
    for (final hw in children) {
      coveredItemIds.add(hw.id);
      final ms = _estimateLearningMsForItemToday(
        hw: hw,
        classDateTime: classDateTime,
        departureTime: departureTime,
      );
      if (ms > groupMs) groupMs = ms;
      if (_hasTodayHomeworkActivity(hw, classDateTime) || ms > 0) {
        hasActivity = true;
      }
    }
    if (hasActivity && groupMs > 0) {
      total += groupMs;
    }
  }
  for (final hw in HomeworkStore.instance.items(studentId)) {
    if (coveredItemIds.contains(hw.id)) continue;
    final ms = _estimateLearningMsForItemToday(
      hw: hw,
      classDateTime: classDateTime,
      departureTime: departureTime,
    );
    if (ms > 0) total += ms;
  }
  return total.clamp(0, 1000 * 60 * 60 * 24).toInt();
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
  if (totalMs <= 0 && hw.accumulatedMs > 0) {
    totalMs = hw.accumulatedMs;
  }
  return totalMs.clamp(0, 1000 * 60 * 60 * 24).toInt();
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
  final assignmentsByItem = await HomeworkAssignmentStore.instance
      .loadAssignmentsForStudent(studentId);
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
        ? assignmentById[latestAssignmentId] ??
            latestAssignmentByItem[entry.key]
        : latestAssignmentByItem[entry.key];
    final title =
        (hw?.title.trim().isNotEmpty ?? false) ? hw!.title.trim() : '과제';
    final bookAndCourse =
        hw == null ? '교재 미기재' : _formatBookAndCourseFromHomework(hw);
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
  final donutGroups = HomeworkStore.instance.groups(studentId);
  for (final group in donutGroups) {
    final children = HomeworkStore.instance
        .itemsInGroup(studentId, group.id, includeCompleted: true);
    if (children.isEmpty) continue;
    int groupStudyMs = 0;
    int groupCheckCount = 0;
    int groupTotalCount = 0;
    bool hasActivity = false;
    DateTime? earliestAssigned;
    final groupPages = <String>[];
    String? firstBookAndCourse;
    for (final hw in children) {
      final studyMs = _estimateLearningMsForItemToday(
          hw: hw, classDateTime: classDateTime, departureTime: departureTime);
      if (studyMs > groupStudyMs) groupStudyMs = studyMs;
      if (_hasTodayHomeworkActivity(hw, classDateTime) || studyMs > 0)
        hasActivity = true;
      final todayChecks = (checksByItem[hw.id] ?? [])
          .where((c) => _isSameDay(c.checkedAt, classDateTime))
          .length;
      groupCheckCount += todayChecks;
      final hwCount = hw.count;
      if (hwCount != null && hwCount > 0) groupTotalCount += hwCount;
      final p = (hw.page ?? '').trim();
      if (p.isNotEmpty) groupPages.add(p);
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
    final subs = <_SubWorkEntry>[];
    for (final hw in children) {
      final t = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
      final pg = (hw.page ?? '').trim();
      final ct =
          (hw.count != null && hw.count! > 0) ? hw.count.toString() : '-';
      subs.add(_SubWorkEntry(title: t, page: pg.isEmpty ? '-' : pg, count: ct));
    }
    classWorkEntries.add(
      _ClassWorkEntry(
        title: groupTitle,
        bookAndCourse: firstBookAndCourse ?? '',
        page: groupPages.isEmpty ? '-' : groupPages.join(', '),
        count: groupTotalCount > 0 ? groupTotalCount.toString() : '-',
        assignedAt: earliestAssigned,
        studyMs: groupStudyMs,
        todayCheckCount: groupCheckCount,
        subEntries: subs,
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
    final weeklyClasses = DataManager.instance.studentTimeBlocks
        .where((b) => b.studentId == studentId)
        .map((b) => b.dayIndex)
        .toSet()
        .length;
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
      final totalMs = items.fold<int>(0, (s, e) => s + e.accumulatedMs);
      final totalChecks = items.fold<int>(0, (s, e) => s + e.checkCount);
      double progressPct = 0;
      String? etaText;
      if (bookId.isNotEmpty && gradeLabel.isNotEmpty) {
        try {
          final meta = await ResourceService.instance
              .loadTextbookMetadataPayload(
                  bookId: bookId, gradeLabel: gradeLabel);
          if (meta != null) {
            final payload = meta['payload'];
            final totalPages = _countTotalPagesFromPayload(payload);
            if (totalPages > 0) {
              final allItems = HomeworkStore.instance.items(studentId);
              final donePages = <int>{};
              for (final it in allItems) {
                if (it.completedAt == null) continue;
                if ((it.bookId ?? '').trim() != bookId) continue;
                if ((it.gradeLabel ?? '').trim() != gradeLabel) continue;
                _addPagesFromItem(donePages, it);
              }
              progressPct = (donePages.length / totalPages * 100).clamp(0, 100);
              final remainingPages = math.max(0, totalPages - donePages.length);
              if (remainingPages <= 0) {
                etaText = '완료';
              } else if (weeklyClasses > 0 && donePages.isNotEmpty) {
                int attendedCount = DataManager.instance.attendanceRecords
                    .where((r) => r.studentId == studentId)
                    .length;
                if (attendedCount <= 0) attendedCount = 1;
                final pagesPerSession = donePages.length / attendedCount;
                if (pagesPerSession > 0) {
                  final sessionsNeeded =
                      (remainingPages / pagesPerSession).ceil();
                  final weeksNeeded = (sessionsNeeded / weeklyClasses).ceil();
                  final eta =
                      classDateTime.add(Duration(days: weeksNeeded * 7));
                  etaText = '~${eta.month}월';
                }
              }
            }
          }
        } catch (_) {}
      }
      completedSummaries.add(_CompletedSummaryEntry(
        groupTitle: gTitle,
        bookAndCourse: bookCourse,
        totalMs: totalMs,
        checkCount: totalChecks,
        progressPct: progressPct,
        etaText: etaText,
      ));
    }
  }

  final todoEntries = <_TodoListEntry>[];
  for (final id in selectedHomeworkIds) {
    final hw = HomeworkStore.instance.getById(studentId, id);
    if (hw == null) continue;
    final title = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
    final pageRaw = (hw.page ?? '').trim();
    final bookAndCourse = _formatBookAndCourseFromHomework(hw);
    final countText =
        (hw.count != null && hw.count! > 0) ? hw.count.toString() : '-';
    final assignedAt = latestAssignmentByItem[id]?.assignedAt ?? classDateTime;
    final assignedDateText = _formatMonthDay(assignedAt);
    final details = [
      _formatPageText(pageRaw),
      _formatCountText(countText),
      if (assignedDateText.isNotEmpty) assignedDateText,
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
    learningMs: learningMs,
    checkRates: checkRates,
    completedSummaries: completedSummaries,
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
  final infoY3 = top + 74;
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
  final classTimeX = left + metricW * 2 + metricGap * 2;
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

  final contentTop = headerBottom + 8;
  final contentBottom = bottom;
  final foldY = size.height / 2;

  // ── Page 1: 수업 요약 (Class Summary) with donut chart ──
  graphics.drawString(
    '수업 요약',
    sectionFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(left, contentTop, contentWidth, 18),
  );
  graphics.drawLine(weakLinePen, Offset(left, contentTop + 20),
      Offset(right, contentTop + 20));

  final donutEntries = payload.classWorkEntries;
  final totalLearningMs = payload.learningMs;
  final arrMs = payload.arrivalTime?.millisecondsSinceEpoch ?? 0;
  final depMs = payload.departureTime.millisecondsSinceEpoch;
  final stayMs = (arrMs > 0 && depMs > arrMs) ? depMs - arrMs : 0;
  final breakMs = math.max(0, stayMs - totalLearningMs);

  double legendBottomY = contentTop + 50;
  if (donutEntries.isEmpty && totalLearningMs <= 0) {
    graphics.drawString(
      '• 오늘 수행 기록 없음',
      bodyFont,
      brush: subBrush,
      bounds: Rect.fromLTWH(left + 4, contentTop + 30, contentWidth - 8, 14),
    );
  } else {
    final donutCx = left + 80;
    final donutCy = contentTop + 120;
    final donutR = 60.0;
    final donutInnerR = 34.0;
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
    final slices = <({String label, int ms, int checks, sf.PdfColor color})>[];
    for (int i = 0; i < donutEntries.length; i++) {
      final e = donutEntries[i];
      if (e.studyMs <= 0) continue;
      slices.add((
        label: e.title,
        ms: e.studyMs,
        checks: e.todayCheckCount,
        color: palette[i % palette.length]
      ));
    }
    if (breakMs > 0) {
      slices.add((
        label: '휴식',
        ms: breakMs,
        checks: 0,
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
      final centerFont = await _loadTodoPdfFont(13, bold: true);
      final centerW = centerFont.measureString(centerText).width;
      graphics.drawString(
        centerText,
        centerFont,
        brush: textBrush,
        bounds:
            Rect.fromLTWH(donutCx - centerW / 2, donutCy - 8, centerW + 4, 18),
      );
    }

    final legendX = left + 180;
    final legendTopY = contentTop + 40;
    final legendFont = await _loadTodoPdfFont(9.4);
    final legendBoldFont = await _loadTodoPdfFont(9.4, bold: true);
    double ly = legendTopY;
    for (final slice in slices) {
      if (ly > foldY - 20) break;
      graphics.drawRectangle(
        brush: sf.PdfSolidBrush(slice.color),
        bounds: Rect.fromLTWH(legendX, ly + 2, 8, 8),
      );
      final mins = (slice.ms / 60000).round();
      final labelText = slice.label;
      final timeText = '$mins분';
      graphics.drawString(labelText, legendBoldFont,
          brush: textBrush, bounds: Rect.fromLTWH(legendX + 14, ly, 120, 14));
      graphics.drawString(timeText, legendFont,
          brush: subBrush, bounds: Rect.fromLTWH(legendX + 140, ly, 50, 14));
      if (slice.checks > 0) {
        graphics.drawString('검사 ${slice.checks}회', legendFont,
            brush: subBrush, bounds: Rect.fromLTWH(legendX + 190, ly, 60, 14));
      }
      ly += 18;
    }
    legendBottomY = ly;
  }

  if (payload.completedSummaries.isNotEmpty) {
    final csFont = await _loadTodoPdfFont(9.0);
    final csBoldFont = await _loadTodoPdfFont(9.0, bold: true);
    double csY = math.max(legendBottomY + 6, contentTop + 200);
    graphics.drawString('완료 과제', csBoldFont,
        brush: textBrush,
        bounds: Rect.fromLTWH(left + 4, csY, contentWidth - 8, 14));
    csY += 16;
    for (final cs in payload.completedSummaries) {
      if (csY > foldY - 14) break;
      final bookText = cs.bookAndCourse;
      graphics.drawString(bookText, csBoldFont,
          brush: textBrush,
          bounds: Rect.fromLTWH(left + 6, csY, contentWidth - 12, 12));
      final bookW = math.min(
          csBoldFont.measureString(bookText).width, contentWidth * 0.4);
      final totalMin = (cs.totalMs / 60000).round();
      final infoText = [
        '총 $totalMin분',
        '검사 ${cs.checkCount}회',
        '진도 ${cs.progressPct.toStringAsFixed(0)}%',
        if (cs.etaText != null) '예상 완료 ${cs.etaText}',
      ].join(' · ');
      final infoX = left + 6 + bookW + 8;
      graphics.drawString(infoText, csFont,
          brush: subBrush,
          bounds: Rect.fromLTWH(infoX, csY, right - infoX - 4, 12));
      csY += 15;
    }
  }

  // ── Page 1 bottom half: 숙제 리스트 + 행동 리스트 ──
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

  final ulPen = sf.PdfPen(sf.PdfColor(60, 60, 60), width: 1.0);
  String extractBookOnly(String raw) {
    var text = raw.trim();
    if (text.startsWith('□')) {
      text = text.substring(1).trimLeft();
    }
    final sep = text.indexOf(' · ');
    if (sep > 0) {
      text = text.substring(0, sep).trim();
    }
    final paren = text.indexOf('(');
    if (paren > 0) {
      text = text.substring(0, paren).trim();
    }
    return text;
  }

  double leftY = todoTop + 24;
  for (final entry in payload.todoEntries) {
    final prim = entry.primary;
    final bx = leftColX + 2;
    final bw = colWidth - 4;
    graphics.drawString(prim, bodyFont,
        brush: textBrush, bounds: Rect.fromLTWH(bx, leftY, bw, 14));
    final bookPart = extractBookOnly(prim);
    if (bookPart.isNotEmpty) {
      double underlineStartX = bx;
      if (prim.startsWith('□')) {
        final prefix = prim.startsWith('□ ') ? '□ ' : '□';
        underlineStartX += bodyFont.measureString(prefix).width;
      }
      final maxW = math.max(0, bw - (underlineStartX - bx));
      final bookW = math.min(bodyFont.measureString(bookPart).width, maxW);
      graphics.drawLine(ulPen, Offset(underlineStartX, leftY + 12.5),
          Offset(underlineStartX + bookW, leftY + 12.5));
    }
    leftY += 14;
    if (entry.secondary != null && entry.secondary!.trim().isNotEmpty) {
      graphics.drawString(entry.secondary!, subFont,
          brush: subBrush,
          bounds: Rect.fromLTWH(leftColX + 2, leftY, colWidth - 4, 13));
      leftY += 13;
    }
    leftY += 8;
    if (leftY > contentBottom - 8) break;
  }

  double rightY = todoTop + 24;
  final behaviorEntries = payload.behaviorEntries;
  if (behaviorEntries.isEmpty) {
    graphics.drawString('• 행동 없음', bodyFont,
        brush: subBrush,
        bounds: Rect.fromLTWH(rightColX + 2, rightY, colWidth - 4, 14));
  } else {
    for (final entry in behaviorEntries) {
      graphics.drawString(entry.primary, bodyFont,
          brush: textBrush,
          bounds: Rect.fromLTWH(rightColX + 2, rightY, colWidth - 4, 14));
      rightY += 14;
      if (entry.secondary != null && entry.secondary!.trim().isNotEmpty) {
        graphics.drawString(entry.secondary!, subFont,
            brush: subBrush,
            bounds: Rect.fromLTWH(rightColX + 2, rightY, colWidth - 4, 13));
        rightY += 13;
      }
      rightY += 8;
      if (rightY > contentBottom - 8) break;
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
      brush: subBrush, bounds: Rect.fromLTWH(left, top + 6, contentWidth2, 18));
  g2.drawLine(linePen, Offset(left, top + 26), Offset(right2, top + 26));

  final p2Top = top + 36;
  const p2ColGap = 12.0;
  final p2ColWidth = (contentWidth2 - p2ColGap) / 2;
  final p2LeftX = left;
  final p2RightX = left + p2ColWidth + p2ColGap;
  const p2TitleH = 16.0;
  const p2RowH = 31.0;
  const p2RowGap = 5.0;
  final p2RowsLimit = bottom2 - 10;

  final p2UlPen = sf.PdfPen(sf.PdfColor(60, 60, 60), width: 1.0);
  void drawP2Row({
    required sf.PdfGraphics g,
    required double x,
    required double y,
    required double cw,
    required String lt,
    required String rt,
    required String lb,
    required String rb,
  }) {
    final rCellW = cw * 0.40;
    final lCellW = cw - rCellW - 8;
    g.drawString(lt, bodyFont,
        brush: textBrush, bounds: Rect.fromLTWH(x + 2, y, lCellW, 14));
    if (lt.isNotEmpty && lt != '-') {
      final pureLt = lt.split('(').first.trim();
      final targetText = pureLt.isEmpty ? lt : pureLt;
      final ltW = math.min(bodyFont.measureString(targetText).width, lCellW);
      g.drawLine(
          p2UlPen, Offset(x + 2, y + 12.5), Offset(x + 2 + ltW, y + 12.5));
    }
    g.drawString(rt, bodyFont,
        brush: textBrush,
        bounds: Rect.fromLTWH(x + lCellW + 10, y, rCellW - 2, 14),
        format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right));
    g.drawString(lb, subFont,
        brush: subBrush, bounds: Rect.fromLTWH(x + 2, y + 14, lCellW, 13));
    g.drawString(rb, subFont,
        brush: subBrush,
        bounds: Rect.fromLTWH(x + lCellW + 10, y + 14, rCellW - 2, 13),
        format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right));
    g.drawLine(weakLinePen, Offset(x, y + p2RowH), Offset(x + cw, y + p2RowH));
  }

  g2.drawString('숙제', valueFont,
      brush: textBrush,
      bounds: Rect.fromLTWH(p2LeftX, p2Top, p2ColWidth, p2TitleH));
  g2.drawString('수업', valueFont,
      brush: textBrush,
      bounds: Rect.fromLTWH(p2RightX, p2Top, p2ColWidth, p2TitleH));
  g2.drawLine(weakLinePen, Offset(p2LeftX, p2Top + p2TitleH),
      Offset(p2LeftX + p2ColWidth, p2Top + p2TitleH));
  g2.drawLine(weakLinePen, Offset(p2RightX, p2Top + p2TitleH),
      Offset(p2RightX + p2ColWidth, p2Top + p2TitleH));
  g2.drawLine(weakLinePen, Offset(p2RightX - (p2ColGap / 2), p2Top),
      Offset(p2RightX - (p2ColGap / 2), p2RowsLimit));

  double p2LeftY = p2Top + p2TitleH + 4;
  for (final line in payload.checkRates) {
    if (p2LeftY + p2RowH > p2RowsLimit) break;
    final pv = _formatPageText(line.page);
    final cv = _formatCountText(line.count);
    final dv = line.assignedAt != null ? _formatMonthDay(line.assignedAt!) : '';
    drawP2Row(
        g: g2,
        x: p2LeftX,
        y: p2LeftY,
        cw: p2ColWidth,
        lt: line.bookAndCourse.trim().isEmpty ? '-' : line.bookAndCourse.trim(),
        rt: line.title.trim().isEmpty ? '-' : line.title.trim(),
        lb: [pv, cv, if (dv.isNotEmpty) dv].join(' · '),
        rb: line.progress == null ? '-' : '${line.progress}%');
    p2LeftY += p2RowH + p2RowGap;
  }

  double p2RightY = p2Top + p2TitleH + 4;
  if (payload.classWorkEntries.isEmpty) {
    g2.drawString('• 오늘 수행 기록 없음', bodyFont,
        brush: subBrush,
        bounds: Rect.fromLTWH(p2RightX + 2, p2RightY + 4, p2ColWidth - 4, 14));
  } else {
    for (final line in payload.classWorkEntries) {
      if (p2RightY + 16 > p2RowsLimit) break;
      final bookText =
          line.bookAndCourse.trim().isEmpty ? '' : line.bookAndCourse.trim();
      final groupTitle = line.title.trim().isEmpty ? '' : line.title.trim();
      final timeText =
          line.studyMs > 0 ? _formatDurationKorean(line.studyMs) : '';
      if (bookText.isNotEmpty) {
        g2.drawString(bookText, bodyFont,
            brush: textBrush,
            bounds:
                Rect.fromLTWH(p2RightX + 2, p2RightY, p2ColWidth * 0.55, 14));
        final pureBook = bookText.split('(').first.trim();
        final bkTarget = pureBook.isEmpty ? bookText : pureBook;
        final bkW =
            math.min(bodyFont.measureString(bkTarget).width, p2ColWidth * 0.55);
        g2.drawLine(p2UlPen, Offset(p2RightX + 2, p2RightY + 12.5),
            Offset(p2RightX + 2 + bkW, p2RightY + 12.5));
      }
      if (groupTitle.isNotEmpty) {
        g2.drawString(groupTitle, bodyFont,
            brush: textBrush,
            bounds: Rect.fromLTWH(
                p2RightX + p2ColWidth * 0.57, p2RightY, p2ColWidth * 0.28, 14));
      }
      if (timeText.isNotEmpty) {
        g2.drawString(timeText, bodyFont,
            brush: subBrush,
            bounds: Rect.fromLTWH(p2RightX + 2, p2RightY, p2ColWidth - 4, 14),
            format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right));
      }
      p2RightY += 16;
      for (final sub in line.subEntries) {
        if (p2RightY + 13 > p2RowsLimit) break;
        final subText = '  ${sub.title} · p.${sub.page} · ${sub.count}문항';
        g2.drawString(subText, subFont,
            brush: subBrush,
            bounds: Rect.fromLTWH(p2RightX + 8, p2RightY, p2ColWidth - 14, 13));
        p2RightY += 13;
      }
      g2.drawLine(weakLinePen, Offset(p2RightX, p2RightY + 2),
          Offset(p2RightX + p2ColWidth, p2RightY + 2));
      p2RightY += 6;
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
