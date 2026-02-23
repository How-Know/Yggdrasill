import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import '../models/student_time_block.dart';
import '../services/data_manager.dart';
import '../services/homework_assignment_store.dart';
import '../services/homework_store.dart';
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
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: kDlgPanelBg,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: kDlgBorder),
                    ),
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
                        '확인 시 학습 내역 + 숙제 TODO를 바로 인쇄합니다.',
                        style: TextStyle(
                          color: kDlgTextSub,
                          fontSize: 12,
                        ),
                      ),
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
}) async {
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  String two(int v) => v.toString().padLeft(2, '0');
  String formatTime(DateTime? dt) =>
      dt == null ? '--:--' : '${two(dt.hour)}:${two(dt.minute)}';
  String formatDate(DateTime dt) =>
      '${dt.year}.${two(dt.month)}.${two(dt.day)}';

  final checksByItem =
      await HomeworkAssignmentStore.instance.loadChecksForStudent(studentId);
  final checkLines = <String>[];
  for (final entry in checksByItem.entries) {
    final todays = entry.value
        .where((c) => sameDay(c.checkedAt, classDateTime))
        .toList()
      ..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
    if (todays.isEmpty) continue;
    final latest = todays.last;
    final hw = HomeworkStore.instance.getById(studentId, entry.key);
    final title = (hw?.title.trim().isNotEmpty ?? false)
        ? hw!.title.trim()
        : '과제(${entry.key.substring(0, entry.key.length.clamp(0, 6))})';
    checkLines.add('- $title: ${latest.progress}%');
  }
  checkLines.sort();

  final completedLines = HomeworkStore.instance
      .items(studentId)
      .where((e) =>
          e.completedAt != null && sameDay(e.completedAt!, classDateTime))
      .map((e) {
    final t = e.title.trim();
    return '- ${t.isEmpty ? '(제목 없음)' : t}';
  }).toList()
    ..sort();

  final todoLines = <String>[];
  for (final id in selectedHomeworkIds) {
    final hw = HomeworkStore.instance.getById(studentId, id);
    if (hw == null) continue;
    final title = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
    final page = (hw.page ?? '').trim();
    final count = hw.count == null ? '' : '${hw.count}문항';
    final meta = [
      if (page.isNotEmpty) 'p.$page',
      if (count.isNotEmpty) count,
    ].join(' · ');
    todoLines.add(meta.isEmpty ? '[ ] $title' : '[ ] $title ($meta)');
  }
  if (todoLines.isEmpty) {
    todoLines.add('[ ] (등록된 숙제 없음)');
  }

  final linesTop = <String>[
    '학생: $studentName',
    '일자: ${formatDate(classDateTime)}',
    '등원: ${formatTime(arrivalTime)}   하원: ${formatTime(departureTime)}',
    '',
    '[오늘 검사 완료율]',
    ...(checkLines.isEmpty ? const ['- 기록 없음'] : checkLines),
    '',
    '[오늘 완료 과제]',
    ...(completedLines.isEmpty ? const ['- 완료 과제 없음'] : completedLines),
  ];
  final linesBottom = <String>[
    '[ ] 우선순위 확인',
    ...todoLines,
  ];

  final outPath = await _buildHomeworkTodoPdf(
    topLines: linesTop,
    bottomLines: linesBottom,
  );
  await _openPrintDialogForPath(outPath);
  _scheduleTempDelete(outPath);
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
  required List<String> topLines,
  required List<String> bottomLines,
}) async {
  final doc = sf.PdfDocument();
  doc.pageSettings.orientation = sf.PdfPageOrientation.landscape;
  doc.pageSettings.margins.all = 18;
  final page = doc.pages.add();
  final size = page.getClientSize();
  final graphics = page.graphics;
  final midY = size.height / 2;

  final titleFont = await _loadTodoPdfFont(15, bold: true);
  final bodyFont = await _loadTodoPdfFont(10.5);
  final subTitleFont = await _loadTodoPdfFont(12, bold: true);
  final titleBrush = sf.PdfSolidBrush(sf.PdfColor(24, 31, 36));
  final linePen = sf.PdfPen(sf.PdfColor(115, 130, 138), width: 0.9);

  graphics.drawRectangle(
    pen: linePen,
    bounds: Rect.fromLTWH(0, 0, size.width, size.height),
  );
  graphics.drawLine(linePen, Offset(0, midY), Offset(size.width, midY));

  graphics.drawString(
    '학습 내역',
    titleFont,
    brush: titleBrush,
    bounds: Rect.fromLTWH(10, 8, size.width - 20, 24),
  );
  graphics.drawString(
    '숙제 TODO 리스트',
    titleFont,
    brush: titleBrush,
    bounds: Rect.fromLTWH(10, midY + 8, size.width - 20, 24),
  );

  double topY = 38;
  for (final line in topLines) {
    final text = line.trim().isEmpty ? ' ' : line;
    graphics.drawString(
      text,
      line.startsWith('[') ? subTitleFont : bodyFont,
      brush: titleBrush,
      bounds: Rect.fromLTWH(16, topY, size.width - 32, 18),
    );
    topY += line.trim().isEmpty ? 11 : 16;
    if (topY > midY - 8) break;
  }

  double bottomY = midY + 38;
  for (final line in bottomLines) {
    graphics.drawString(
      line,
      line.startsWith('[') && !line.startsWith('[ ]') ? subTitleFont : bodyFont,
      brush: titleBrush,
      bounds: Rect.fromLTWH(16, bottomY, size.width - 32, 18),
    );
    bottomY += 16;
    if (bottomY > size.height - 8) break;
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
  final target = path.trim();
  if (target.isEmpty) return;
  try {
    if (Platform.isWindows) {
      final q = "'${target.replaceAll("'", "''")}'";
      await Process.start(
        'powershell',
        ['-NoProfile', '-Command', 'Start-Process -FilePath $q -Verb Print'],
        runInShell: true,
      );
      return;
    }
  } catch (_) {
    // fallthrough
  }
  await OpenFilex.open(target);
}
