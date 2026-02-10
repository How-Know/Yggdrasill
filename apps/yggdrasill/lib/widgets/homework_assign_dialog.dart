import 'package:flutter/material.dart';
import '../models/student_time_block.dart';
import '../services/data_manager.dart';
import '../services/homework_store.dart';
import '../widgets/dialog_tokens.dart';

class HomeworkAssignSelection {
  final List<String> itemIds;
  final DateTime? dueDate;
  const HomeworkAssignSelection({
    required this.itemIds,
    required this.dueDate,
  });
}

class _SessionOption {
  final DateTime dateTime;
  final String label;
  const _SessionOption(this.dateTime, this.label);
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
                  OutlinedButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('숙제 추가'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kDlgTextSub,
                      side: const BorderSide(color: kDlgBorder),
                    ),
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
