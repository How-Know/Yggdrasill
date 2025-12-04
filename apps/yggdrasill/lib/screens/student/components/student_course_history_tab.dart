import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../models/attendance_record.dart';
import '../../../models/student.dart';
import '../../../services/data_manager.dart';
import '../../../services/homework_store.dart';
import '../../../services/tag_store.dart';
import '../../learning/tag_preset_dialog.dart';

class StudentCourseHistoryTab extends StatefulWidget {
  final StudentWithInfo studentWithInfo;

  const StudentCourseHistoryTab({super.key, required this.studentWithInfo});

  @override
  State<StudentCourseHistoryTab> createState() => _StudentCourseHistoryTabState();
}

class _StudentCourseHistoryTabState extends State<StudentCourseHistoryTab> {
  final ScrollController _timelineScrollController = ScrollController();

  DateTime _anchorDate = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  int _daysLoaded = 31;
  bool _showAttendance = true;
  bool _showTags = true;
  Timer? _homeworkTicker;

  @override
  void initState() {
    super.initState();
    _timelineScrollController.addListener(_handleScroll);
    unawaited(HomeworkStore.instance.loadAll());
    unawaited(TagStore.instance.loadAllFromDb());
  }

  @override
  void dispose() {
    _timelineScrollController.removeListener(_handleScroll);
    _timelineScrollController.dispose();
    _homeworkTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const double panelHeight = 720;
    final student = widget.studentWithInfo;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('수업 기록', style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 6,
              child: ValueListenableBuilder<List<AttendanceRecord>>(
                valueListenable: DataManager.instance.attendanceRecordsNotifier,
                builder: (_, __, ___) {
                  return ValueListenableBuilder<int>(
                    valueListenable: TagStore.instance.revision,
                    builder: (_, ____, _____) => _buildTimelineCard(student, panelHeight),
                  );
                },
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              flex: 4,
              child: SizedBox(
                height: panelHeight,
                child: Column(
                  children: [
                    _buildHomeworkCard(student, 360),
                    const SizedBox(height: 16),
                    Expanded(child: _buildSummaryCard(student)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTimelineCard(StudentWithInfo student, double height) {
    final entries = _collectTimelineEntries(student, _anchorDate, _daysLoaded);
    final items = _buildRenderableTimeline(entries);
    return SizedBox(
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF151C21),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF223131)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _filterChip(label: '등/하원', selected: _showAttendance, onSelected: (v) => setState(() => _showAttendance = v)),
                const SizedBox(width: 8),
                _filterChip(label: '태그', selected: _showTags, onSelected: (v) => setState(() => _showTags = v)),
                const Spacer(),
                Text(DateFormat('yyyy.MM.dd').format(_anchorDate), style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
                IconButton(
                  tooltip: '날짜 선택',
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _anchorDate,
                      firstDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                      builder: (context, child) {
                        return Theme(
                          data: Theme.of(context).copyWith(
                            colorScheme: const ColorScheme.dark(primary: Color(0xFF1B6B63)),
                            dialogBackgroundColor: const Color(0xFF0B1112),
                          ),
                          child: child!,
                        );
                      },
                    );
                    if (picked != null) {
                      setState(() {
                        _anchorDate = DateTime(picked.year, picked.month, picked.day);
                        _daysLoaded = 31;
                      });
                      if (_timelineScrollController.hasClients) {
                        _timelineScrollController.jumpTo(0);
                      }
                    }
                  },
                  icon: const Icon(Icons.event, color: Colors.white70, size: 20),
                ),
                IconButton(
                  tooltip: '태그 관리',
                  onPressed: () async {
                    await showDialog(context: context, builder: (_) => const TagPresetDialog());
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.style, color: Colors.white70, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(color: Color(0xFF223131), height: 1),
            const SizedBox(height: 12),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('기록이 없습니다.', style: TextStyle(color: Colors.white54)))
                  : ListView.separated(
                      controller: _timelineScrollController,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        if (item is _HistoryTimelineHeader) {
                          return Row(
                            children: [
                              const Expanded(child: Divider(color: Colors.white12)),
                              const SizedBox(width: 8),
                              Text(DateFormat('yyyy.MM.dd').format(item.date),
                                  style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w700)),
                              const SizedBox(width: 8),
                              const Expanded(child: Divider(color: Colors.white12)),
                            ],
                          );
                        } else if (item is _HistoryTimelineEntry) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: item.color.withOpacity(0.15),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: item.color.withOpacity(0.8)),
                                ),
                                child: Icon(item.icon, color: item.color, size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${item.label} · ${DateFormat('HH:mm').format(item.time)}',
                                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                                    ),
                                    if (item.note != null && item.note!.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(item.note!, style: const TextStyle(color: Colors.white60, fontSize: 14)),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeworkCard(StudentWithInfo student, double height) {
    final sid = student.student.id;
    return SizedBox(
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF151C21),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF223131)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('과제 · 수업 기록', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    final draft = await _showHomeworkDialog();
                    if (draft != null) {
                      HomeworkStore.instance.add(sid, title: draft.title, body: draft.body, color: draft.color);
                      setState(() {});
                    }
                  },
                  icon: const Icon(Icons.add, size: 16, color: Colors.white70),
                  label: const Text('추가', style: TextStyle(color: Colors.white70)),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white70,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ValueListenableBuilder<int>(
                valueListenable: HomeworkStore.instance.revision,
                builder: (context, _, __) {
                  final list = HomeworkStore.instance.items(sid);
                  _ensureHomeworkTicker(sid, list);
                  if (list.isEmpty) {
                    return const Center(child: Text('등록된 과제가 없습니다.', style: TextStyle(color: Colors.white54)));
                  }
                  return ListView.separated(
                    padding: EdgeInsets.zero,
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final hw = list[index];
                      final running = hw.runStart != null;
                      final bool isHomework = hw.status == HomeworkStatus.homework;
                      final bool isCompleted = hw.status == HomeworkStatus.completed;
                      final durationText = _formatHomeworkDuration(hw);
                      final infoOpacity = isCompleted ? 0.55 : 1.0;
                      return Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1C2328),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF223131)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Opacity(
                              opacity: infoOpacity,
                              child: Row(
                                children: [
                                  Container(width: 12, height: 12, decoration: BoxDecoration(color: hw.color, shape: BoxShape.circle)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      hw.title,
                                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(durationText, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                  PopupMenuButton<String>(
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(value: 'edit', child: Text('편집')),
                                      PopupMenuItem(value: 'delete', child: Text('삭제')),
                                    ],
                                    onSelected: (value) async {
                                      if (value == 'delete') {
                                        await HomeworkStore.instance.pause(sid, hw.id);
                                        HomeworkStore.instance.remove(sid, hw.id);
                                        setState(() {});
                                      } else if (value == 'edit') {
                                        final draft = await _showHomeworkDialog(
                                          initialTitle: hw.title,
                                          initialBody: hw.body,
                                          initialColor: hw.color,
                                        );
                                        if (draft != null) {
                                          hw.title = draft.title;
                                          hw.body = draft.body;
                                          hw.color = draft.color;
                                          HomeworkStore.instance.edit(sid, hw);
                                          setState(() {});
                                        }
                                      }
                                    },
                                    color: const Color(0xFF232B32),
                                    icon: const Icon(Icons.more_horiz, color: Colors.white54, size: 20),
                                  ),
                                ],
                              ),
                            ),
                            if (hw.body.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Opacity(opacity: infoOpacity, child: Text(hw.body, style: const TextStyle(color: Colors.white70, fontSize: 14))),
                            ],
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                IconButton(
                                  tooltip: running ? '일시정지' : '진행',
                                  onPressed: isCompleted
                                      ? null
                                      : () async {
                                          if (running) {
                                            await HomeworkStore.instance.pause(sid, hw.id);
                                          } else {
                                            await HomeworkStore.instance.start(sid, hw.id);
                                          }
                                          setState(() {});
                                        },
                                  icon: Icon(running ? Icons.pause : Icons.play_arrow, color: isCompleted ? Colors.white30 : Colors.white70, size: 20),
                                ),
                                IconButton(
                                  tooltip: '완료',
                                  onPressed: isCompleted
                                      ? null
                                      : () async {
                                          await HomeworkStore.instance.complete(sid, hw.id);
                                          setState(() {});
                                        },
                                  icon: Icon(Icons.check_circle, color: isCompleted ? Colors.white30 : Colors.white70, size: 20),
                                ),
                                IconButton(
                                  tooltip: '내용 추가',
                                  onPressed: () async {
                                    final draft = await _showHomeworkDialog(
                                      initialTitle: hw.title,
                                      initialColor: hw.color,
                                      bodyOnly: true,
                                    );
                                    if (draft != null) {
                                      HomeworkStore.instance.continueAdd(sid, hw.id, body: draft.body);
                                      setState(() {});
                                    }
                                  },
                                  icon: const Icon(Icons.add, color: Colors.white70, size: 20),
                                ),
                                const Spacer(),
                                if (hw.firstStartedAt != null)
                                  Text('시작 ${DateFormat('MM.dd HH:mm').format(hw.firstStartedAt!)}',
                                      style: const TextStyle(color: Colors.white38, fontSize: 12)),
                                if (isHomework) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(color: const Color(0xFFFFC107).withOpacity(0.15), borderRadius: BorderRadius.circular(999)),
                                    child: const Text('숙제', style: TextStyle(color: Color(0xFFFFC107), fontSize: 11, fontWeight: FontWeight.w700)),
                                  ),
                                ],
                                if (isCompleted) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(color: const Color(0xFF2E7D32).withOpacity(0.25), borderRadius: BorderRadius.circular(999)),
                                    child: const Text('완료', style: TextStyle(color: Color(0xFFA5D6A7), fontSize: 11, fontWeight: FontWeight.w700)),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(StudentWithInfo student) {
    final records = _uniqueAttendanceRecords(student.student.id);
    final total = records.length;
    final present = records.where((r) => !_isAbsent(r)).length;
    final late = records.where(_isLate).length;
    final absent = records.where(_isAbsent).length;

    double rate(int count) => total == 0 ? 0 : (count / total * 100);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF151C21),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF223131)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('출결 요약', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Row(
            children: [
              _summaryTile('출석률', total == 0 ? '0%' : '${rate(present).toStringAsFixed(1)}%', '$present / $total'),
              const SizedBox(width: 12),
              _summaryTile('지각', total == 0 ? '0%' : '${rate(late).toStringAsFixed(1)}%', '$late 회'),
              const SizedBox(width: 12),
              _summaryTile('결석', total == 0 ? '0%' : '${rate(absent).toStringAsFixed(1)}%', '$absent 회'),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF1C2328),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF223131)),
            ),
            child: Text(
              '최근 업데이트 · ${DateFormat('yyyy.MM.dd HH:mm').format(DateTime.now())}',
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryTile(String title, String value, String caption) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1C2328),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF223131)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(color: Colors.white60, fontSize: 13)),
            const SizedBox(height: 6),
            Text(value, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(caption, style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return FilterChip(
      label: Text(label, style: const TextStyle(color: Colors.white70)),
      selected: selected,
      onSelected: onSelected,
      showCheckmark: false,
      selectedColor: const Color(0xFF1C2328),
      backgroundColor: const Color(0xFF151C21),
      shape: StadiumBorder(side: BorderSide(color: selected ? const Color(0xFF1B6B63) : Colors.white24, width: 1.2)),
    );
  }

  List<_HistoryTimelineEntry> _collectTimelineEntries(StudentWithInfo student, DateTime anchor, int days) {
    final List<_HistoryTimelineEntry> all = [];
    final DateTime normalizedAnchor = DateTime(anchor.year, anchor.month, anchor.day);
    final records = DataManager.instance.getAttendanceRecordsForStudent(student.student.id);
    for (int i = 0; i < days; i++) {
      final dayStart = normalizedAnchor.subtract(Duration(days: i));
      final dayEnd = dayStart.add(const Duration(days: 1));
      all.addAll(_collectEntriesForRange(student, dayStart, dayEnd, records));
    }
    all.sort((a, b) => b.time.compareTo(a.time));
    return all;
  }

  List<_HistoryTimelineEntry> _collectEntriesForRange(
    StudentWithInfo student,
    DateTime start,
    DateTime end,
    List<AttendanceRecord> records,
  ) {
    final entries = <_HistoryTimelineEntry>[];
    final seen = <String>{};
    final studentId = student.student.id;

    if (_showAttendance) {
      for (final record in records) {
        if (record.arrivalTime != null && !record.arrivalTime!.isBefore(start) && record.arrivalTime!.isBefore(end)) {
          final key = 'arr_${record.arrivalTime!.millisecondsSinceEpoch}';
          if (seen.add(key)) {
            entries.add(_HistoryTimelineEntry(
              time: record.arrivalTime!,
              icon: Icons.login,
              color: const Color(0xFF33A373),
              label: '등원',
            ));
          }
        }
        if (record.departureTime != null && !record.departureTime!.isBefore(start) && record.departureTime!.isBefore(end)) {
          final key = 'dep_${record.departureTime!.millisecondsSinceEpoch}';
          if (seen.add(key)) {
            entries.add(_HistoryTimelineEntry(
              time: record.departureTime!,
              icon: Icons.logout,
              color: const Color(0xFFF07C56),
              label: '하원',
            ));
          }
        }
      }
    }

    if (_showTags) {
      final dayIndex = start.weekday - 1;
      final blocks = DataManager.instance.studentTimeBlocks.where(
        (block) => block.studentId == studentId && block.setId != null && block.dayIndex == dayIndex,
      );
      for (final block in blocks) {
        final events = TagStore.instance.getEventsForSet(block.setId!);
        for (final event in events) {
          if (event.timestamp.isAfter(start) && event.timestamp.isBefore(end)) {
            final key = 'tag_${block.setId}_${event.tagName}_${event.timestamp.millisecondsSinceEpoch}_${event.note ?? ''}';
            if (seen.add(key)) {
              entries.add(_HistoryTimelineEntry(
                time: event.timestamp,
                icon: IconData(event.iconCodePoint, fontFamily: 'MaterialIcons'),
                color: Color(event.colorValue),
                label: event.tagName,
                note: event.note,
              ));
            }
          }
        }
      }
    }

    return entries;
  }

  List<dynamic> _buildRenderableTimeline(List<_HistoryTimelineEntry> entries) {
    final List<dynamic> list = [];
    DateTime? currentDate;
    for (final entry in entries) {
      final date = DateTime(entry.time.year, entry.time.month, entry.time.day);
      if (currentDate == null || currentDate.millisecondsSinceEpoch != date.millisecondsSinceEpoch) {
        currentDate = date;
        list.add(_HistoryTimelineHeader(date: date));
      }
      list.add(entry);
    }
    return list;
  }

  void _handleScroll() {
    if (!_timelineScrollController.hasClients) return;
    if (_timelineScrollController.position.pixels >= _timelineScrollController.position.maxScrollExtent - 80) {
      setState(() {
        _daysLoaded += 31;
      });
    }
  }

  void _ensureHomeworkTicker(String studentId, List<HomeworkItem> list) {
    final hasRunning = list.any((item) => item.runStart != null);
    if (hasRunning && _homeworkTicker == null) {
      _homeworkTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) {
          _homeworkTicker?.cancel();
          _homeworkTicker = null;
          return;
        }
        setState(() {});
      });
    } else if (!hasRunning && _homeworkTicker != null) {
      _homeworkTicker?.cancel();
      _homeworkTicker = null;
    }
  }

  Future<_HomeworkDraft?> _showHomeworkDialog({
    String? initialTitle,
    String? initialBody,
    Color? initialColor,
    bool bodyOnly = false,
  }) async {
    final titleController = TextEditingController(text: initialTitle ?? '');
    final bodyController = TextEditingController(text: bodyOnly ? '' : (initialBody ?? ''));
    Color selectedColor = initialColor ?? const Color(0xFF1976D2);
    const palette = [
      Color(0xFF1976D2),
      Color(0xFF26A69A),
      Color(0xFFF57C00),
      Color(0xFFAB47BC),
      Color(0xFFEF5350),
      Color(0xFF90A4AE),
    ];

    final draft = await showDialog<_HomeworkDraft?>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocal) {
            return AlertDialog(
              backgroundColor: const Color(0xFF0B1112),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              title: Text(bodyOnly ? '내용 추가' : (initialTitle == null ? '과제 추가' : '과제 편집'), style: const TextStyle(color: Colors.white)),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!bodyOnly) ...[
                      TextField(
                        controller: titleController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: '제목',
                          labelStyle: TextStyle(color: Colors.white60),
                          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1B6B63))),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      controller: bodyController,
                      minLines: 2,
                      maxLines: 4,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: '내용',
                        labelStyle: TextStyle(color: Colors.white60),
                        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1B6B63))),
                      ),
                    ),
                    if (!bodyOnly) ...[
                      const SizedBox(height: 12),
                      const Text('색상', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in palette)
                            _ColorDot(
                              color: c,
                              selected: selectedColor == c,
                              onTap: () => setLocal(() => selectedColor = c),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: const Text('취소', style: TextStyle(color: Colors.white70)),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B6B63)),
                  onPressed: () {
                    final title = titleController.text.trim();
                    final body = bodyController.text.trim();
                    if (!bodyOnly && title.isEmpty) return;
                    Navigator.pop(context, _HomeworkDraft(title: title.isEmpty ? '과제' : title, body: body, color: selectedColor));
                  },
                  child: const Text('확인'),
                ),
              ],
            );
          },
        );
      },
    );

    titleController.dispose();
    bodyController.dispose();
    return draft;
  }

  List<AttendanceRecord> _uniqueAttendanceRecords(String studentId) {
    final records = DataManager.instance.getAttendanceRecordsForStudent(studentId)
      ..sort((a, b) => b.classDateTime.compareTo(a.classDateTime));
    final Map<DateTime, AttendanceRecord> uniqueMap = {};
    for (final record in records) {
      final dayKey = DateTime(record.classDateTime.year, record.classDateTime.month, record.classDateTime.day);
      final existing = uniqueMap[dayKey];
      if (existing == null || _compareAttendancePriority(record, existing) < 0) {
        uniqueMap[dayKey] = record;
      }
    }
    final result = uniqueMap.values.toList()
      ..sort((a, b) => b.classDateTime.compareTo(a.classDateTime));
    return result;
  }

  String _formatHomeworkDuration(HomeworkItem hw) {
    final runningMs = hw.runStart != null ? DateTime.now().difference(hw.runStart!).inMilliseconds : 0;
    final totalMs = hw.accumulatedMs + runningMs;
    final duration = Duration(milliseconds: totalMs);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes.toString().padLeft(2, '0')}m';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

class _HistoryTimelineEntry {
  final DateTime time;
  final IconData icon;
  final Color color;
  final String label;
  final String? note;

  _HistoryTimelineEntry({
    required this.time,
    required this.icon,
    required this.color,
    required this.label,
    this.note,
  });
}

class _HistoryTimelineHeader {
  final DateTime date;

  _HistoryTimelineHeader({required this.date});
}

class _HomeworkDraft {
  final String title;
  final String body;
  final Color color;

  _HomeworkDraft({required this.title, required this.body, required this.color});
}

class _ColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _ColorDot({required this.color, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? Colors.white : Colors.white24, width: selected ? 2 : 1),
        ),
      ),
    );
  }
}

int _compareAttendancePriority(AttendanceRecord a, AttendanceRecord b) {
  return _attendanceRank(a).compareTo(_attendanceRank(b));
}

int _attendanceRank(AttendanceRecord record) {
  if (_isPresent(record) && !_isLate(record)) return 0;
  if (_isPresent(record) && _isLate(record)) return 1;
  return 2;
}

bool _isPresent(AttendanceRecord record) => record.isPresent;

bool _isLate(AttendanceRecord record) {
  if (!record.isPresent || record.arrivalTime == null) return false;
  final lateThreshold = record.classDateTime.add(const Duration(minutes: 10));
  return record.arrivalTime!.isAfter(lateThreshold);
}

bool _isAbsent(AttendanceRecord record) => !record.isPresent;


