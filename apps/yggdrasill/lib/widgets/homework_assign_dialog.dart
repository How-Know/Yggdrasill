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
import '../services/tag_store.dart';
import '../widgets/dialog_tokens.dart';

class HomeworkAssignSelection {
  final List<String> itemIds;
  final DateTime? dueDate;
  final bool printTodoOnConfirm;
  const HomeworkAssignSelection({
    required this.itemIds,
    required this.dueDate,
    this.printTodoOnConfirm = false,
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
  const _CheckRateEntry({
    required this.title,
    required this.progress,
  });
}

class _TodoSheetPayload {
  final String academyName;
  final Uint8List? academyLogo;
  final String studentName;
  final DateTime classDateTime;
  final DateTime? arrivalTime;
  final DateTime departureTime;
  final String className;
  final String classTimeText;
  final String learningTimeText;
  final List<_CheckRateEntry> checkRates;
  final List<_TodoListEntry> completedEntries;
  final List<_TodoListEntry> todoEntries;
  final String behaviorFeedback;

  const _TodoSheetPayload({
    required this.academyName,
    required this.academyLogo,
    required this.studentName,
    required this.classDateTime,
    required this.arrivalTime,
    required this.departureTime,
    required this.className,
    required this.classTimeText,
    required this.learningTimeText,
    required this.checkRates,
    required this.completedEntries,
    required this.todoEntries,
    required this.behaviorFeedback,
  });
}

Future<HomeworkAssignSelection?> showHomeworkAssignDialog(
  BuildContext context,
  String studentId, {
  DateTime? anchorTime,
}) async {
  final items = HomeworkStore.instance
      .items(studentId)
      .where((e) => e.status != HomeworkStatus.completed)
      .toList();
  if (items.isEmpty) return null;
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
      .toList()
    ..sort((a, b) {
      if (a.startHour != b.startHour) return a.startHour - b.startHour;
      return a.startMinute - b.startMinute;
    });
  for (int i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    final dt = DateTime(
      day.year,
      day.month,
      day.day,
      b.startHour,
      b.startMinute,
    );
    final order = b.number ?? b.weeklyOrder ?? (i + 1);
    addOption(dt, order: order);
  }

  options.sort((a, b) => a.dateTime.compareTo(b.dateTime));
  final nextSessions = options.length > 12 ? options.sublist(0, 12) : options;
  DateTime? selectedDueDate =
      nextSessions.isNotEmpty ? nextSessions.first.dateTime : null;
  final Map<String, bool> selected = {
    for (final e in items) e.id: true,
  };
  bool printTodoOnConfirm = false;
  bool previewing = false;
  return showDialog<HomeworkAssignSelection>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          return AlertDialog(
            backgroundColor: kDlgBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text('숙제 선택',
                style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
            content: SizedBox(
              width: 520,
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
                  const SizedBox(height: 12),
                  const YggDialogSectionHeader(
                      icon: Icons.assignment_turned_in, title: '등록된 과제'),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 6),
                      itemBuilder: (ctx, idx) {
                        final hw = items[idx];
                        final String type = (hw.type ?? '').trim();
                        final String page = (hw.page ?? '').trim();
                        final String count =
                            hw.count != null ? hw.count.toString() : '';
                        final String title = hw.title.trim();
                        final String meta = [
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
                              style: const TextStyle(
                                color: kDlgText,
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
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
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
                            '확인 시 학습 리포트 + 숙제 리스트를 바로 인쇄합니다.',
                            style: TextStyle(
                              color: kDlgTextSub,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
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
                  Navigator.of(ctx).pop(HomeworkAssignSelection(
                    itemIds: ids,
                    dueDate: selectedDueDate,
                    printTodoOnConfirm: printTodoOnConfirm,
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
    return '태도 피드백: 집중하여 공부했습니다.';
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
      return '태도 피드백: ${noteTexts.first}';
    }
    return '태도 피드백: 집중하여 공부했습니다.';
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
    return '태도 피드백: 집중하여 공부했습니다.';
  }
  return '태도 피드백: ${parts.join(' ')}';
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

Future<_TodoSheetPayload> _prepareTodoSheetPayload({
  required String studentId,
  required String studentName,
  required DateTime classDateTime,
  DateTime? arrivalTime,
  required DateTime departureTime,
  required List<String> selectedHomeworkIds,
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
  final checkRates = <_CheckRateEntry>[];
  for (final entry in checksByItem.entries) {
    final todays = entry.value
        .where((c) => _isSameDay(c.checkedAt, classDateTime))
        .toList()
      ..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
    if (todays.isEmpty) continue;
    final latest = todays.last;
    final hw = HomeworkStore.instance.getById(studentId, entry.key);
    final title =
        (hw?.title.trim().isNotEmpty ?? false) ? hw!.title.trim() : '과제';
    checkRates.add(_CheckRateEntry(title: title, progress: latest.progress));
  }
  if (checkRates.isEmpty) {
    checkRates.add(const _CheckRateEntry(title: '숙제 없음', progress: null));
  }

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
    final pageText =
        (hw.page ?? '').trim().isEmpty ? 'p.-' : 'p.${hw.page!.trim()}';
    todoEntries.add(
      _TodoListEntry(
        primary: '□ $title',
        secondary:
            '  교재: ${_extractBookNameFromHomework(hw)}    페이지: $pageText',
      ),
    );
  }
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
    arrivalTime: resolvedArrival,
    departureTime: departureTime,
    className: resolvedClassName,
    classTimeText: _formatClassTimeRange(classDateTime, resolvedClassEnd),
    learningTimeText: _formatDurationKorean(learningMs),
    checkRates: checkRates,
    completedEntries: completedEntries,
    todoEntries: todoEntries,
    behaviorFeedback: _buildBehaviorFeedback(
      studentId: studentId,
      classDateTime: classDateTime,
      setId: resolvedSetId,
    ),
  );
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
  final leftInfoW = contentWidth * 0.44;
  final rightInfoX = left + leftInfoW + 10;
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

  final metricGap = contentWidth * 0.01;
  final metricW = (contentWidth - metricGap * 2) / 3;

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

  double topY = contentTop + 22;
  graphics.drawString(
    '1. 숙제 완료율',
    bodyFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(left + 2, topY, contentWidth - 4, 14),
  );
  topY += 14;
  final rateValueW = 52.0;
  double maxRateLabelW = 0;
  for (final line in payload.checkRates) {
    final w = bodyFont.measureString('• ${line.title}').width;
    if (w > maxRateLabelW) maxRateLabelW = w;
  }
  final rateValueX = math.min(
    left + 6 + maxRateLabelW + 14,
    right - rateValueW - 8,
  );
  final rateLabelW = math.max(120.0, rateValueX - (left + 6) - 8);
  for (final line in payload.checkRates) {
    final labelText = '• ${line.title}';
    final valueText = line.progress != null ? '${line.progress}%' : '';
    graphics.drawString(
      labelText,
      bodyFont,
      brush: subBrush,
      bounds: Rect.fromLTWH(left + 6, topY, rateLabelW, 14),
    );
    if (valueText.isNotEmpty) {
      graphics.drawString(
        valueText,
        bodyFont,
        brush: subBrush,
        bounds: Rect.fromLTWH(rateValueX, topY, rateValueW, 14),
        format: sf.PdfStringFormat(alignment: sf.PdfTextAlignment.right),
      );
    }
    topY += 16;
    if (topY > topBottomLimit - 76) break;
  }

  topY += 5;
  graphics.drawString(
    '2. 완료한 과제',
    bodyFont,
    brush: textBrush,
    bounds: Rect.fromLTWH(left + 2, topY, contentWidth - 4, 14),
  );
  topY += 14;
  for (final entry in payload.completedEntries) {
    graphics.drawString(
      entry.primary,
      bodyFont,
      brush: subBrush,
      bounds: Rect.fromLTWH(left + 6, topY, contentWidth - 12, 14),
    );
    topY += 14;
    if (entry.secondary != null && entry.secondary!.trim().isNotEmpty) {
      graphics.drawString(
        entry.secondary!,
        subFont,
        brush: subBrush,
        bounds: Rect.fromLTWH(left + 6, topY, contentWidth - 12, 13),
      );
      topY += 13;
    }
    topY += 8;
    if (topY > topBottomLimit - 26) break;
  }

  topY += 2;
  graphics.drawString(
    payload.behaviorFeedback,
    subFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(left + 6, topY, contentWidth - 12, 24),
  );

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

  graphics.drawString(
    '• 추후 구현 예정',
    bodyFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(rightColX + 2, todoTop + 24, colWidth - 4, 14),
  );
  graphics.drawString(
    '• 행동 피드백, 생활 체크 등을 넣을 영역',
    subFont,
    brush: subBrush,
    bounds: Rect.fromLTWH(rightColX + 2, todoTop + 40, colWidth - 4, 13),
  );

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
  );
}
