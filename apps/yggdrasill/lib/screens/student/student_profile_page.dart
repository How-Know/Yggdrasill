import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/data_manager.dart';
import '../../models/student.dart';
import '../../models/education_level.dart';
import '../../widgets/pill_tab_selector.dart';
import '../../models/attendance_record.dart';
import '../../services/tag_store.dart';
import '../../screens/learning/tag_preset_dialog.dart';
import '../../widgets/swipe_action_reveal.dart';
import '../../widgets/dialog_tokens.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

class StudentProfilePage extends StatefulWidget {
  final StudentWithInfo studentWithInfo;

  const StudentProfilePage({super.key, required this.studentWithInfo});

  @override
  State<StudentProfilePage> createState() => _StudentProfilePageState();
}

class _StudentProfilePageState extends State<StudentProfilePage> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    // ClassStatusScreen과 동일한 구조 적용
    return Scaffold(
      backgroundColor: const Color(0xFF0B1112),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(width: 0), // 왼쪽 여백 (AllStudentsView와 일치)
          Expanded(
            flex: 2,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return Container(
                  constraints: const BoxConstraints(
                    minWidth: 624,
                  ),
                  padding: const EdgeInsets.only(left: 34, right: 24, top: 24, bottom: 24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B1112),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 1),
                      // 헤더 영역
                      _StudentProfileHeader(
                        studentWithInfo: widget.studentWithInfo,
                        tabIndex: _tabIndex,
                        onTabChanged: (next) => setState(() => _tabIndex = next),
                      ),
                      const SizedBox(height: 24),
                      // 메인 콘텐츠 영역
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0B1112),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: _StudentProfileContent(
                            tabIndex: _tabIndex,
                            studentWithInfo: widget.studentWithInfo,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StudentProfileHeader extends StatelessWidget {
  final StudentWithInfo studentWithInfo;
  final int tabIndex;
  final ValueChanged<int> onTabChanged;

  const _StudentProfileHeader({
    required this.studentWithInfo,
    required this.tabIndex,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    final student = studentWithInfo.student;
    final basicInfo = studentWithInfo.basicInfo;
    final String levelName = getEducationLevelName(student.educationLevel);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    // 뒤로가기 버튼
                    Container(
                      width: 40,
                      height: 40,
                      margin: const EdgeInsets.only(right: 16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
                        onPressed: () => Navigator.of(context).pop(),
                        tooltip: '뒤로',
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: student.groupInfo?.color ?? const Color(0xFF2C3A3A),
                      child: Text(
                        student.name.characters.take(1).toString(),
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      student.name,
                      style: const TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 32,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 15),
                    Flexible(
                      child: Text(
                        '$levelName · ${student.grade}학년 · ${student.school}',
                        style: const TextStyle(
                          color: Color(0xFFCBD8D8),
                          fontSize: 18,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              PillTabSelector(
                width: 300,
                height: 40,
                fontSize: 15,
                selectedIndex: tabIndex,
                tabs: const ['요약', '수업일지', '스탯'],
                onTabSelected: onTabChanged,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '등록일 ${DateFormat('yyyy.MM.dd').format(basicInfo.registrationDate ?? DateTime.now())}',
                    style: const TextStyle(
                      color: Color(0xFFCBD8D8),
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Color(0xFF223131), height: 1, thickness: 1),
        ],
      ),
    );
  }
}

class _StudentProfileContent extends StatelessWidget {
  final int tabIndex;
  final StudentWithInfo studentWithInfo;
  const _StudentProfileContent({
    required this.tabIndex,
    required this.studentWithInfo,
  });

  @override
  Widget build(BuildContext context) {
    if (tabIndex == 1) {
      return _StudentTimelineView(studentWithInfo: studentWithInfo);
    }
    final String label = tabIndex == 0 ? '요약 준비 중입니다.' : '스탯 준비 중입니다.';
    return Center(
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white.withOpacity(0.3),
          fontSize: 18,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _StudentTimelineView extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  const _StudentTimelineView({required this.studentWithInfo});

  @override
  State<_StudentTimelineView> createState() => _StudentTimelineViewState();
}

class _StudentTimelineViewState extends State<_StudentTimelineView> {
  final ScrollController _timelineScrollController = ScrollController();
  static const Color _attendanceColor = Color(0xFF33A373);
  static const Color _recordColor = Color(0xFF9AA0A6);
  DateTime _anchorDate = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  int _daysLoaded = 31;
  bool _showAttendance = true;
  bool _showTags = true;

  @override
  void initState() {
    super.initState();
    _timelineScrollController.addListener(_handleScroll);
    unawaited(TagStore.instance.loadAllFromDb());
  }

  @override
  void dispose() {
    _timelineScrollController.removeListener(_handleScroll);
    _timelineScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<AttendanceRecord>>(
      valueListenable: DataManager.instance.attendanceRecordsNotifier,
      builder: (_, __, ___) {
        return ValueListenableBuilder<int>(
          valueListenable: TagStore.instance.revision,
          builder: (_, ____, _____) {
            final entries = _collectTimelineEntries(
              widget.studentWithInfo,
              _anchorDate,
              _daysLoaded,
            );
            final items = _buildRenderableTimeline(entries);
            return Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF10171A),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF223131)),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _filterChip(label: '등/하원', selected: _showAttendance, onSelected: (v) => setState(() => _showAttendance = v)),
                          const SizedBox(width: 8),
                          _filterChip(label: '태그', selected: _showTags, onSelected: (v) => setState(() => _showTags = v)),
                          const Spacer(),
                          Text(
                            DateFormat('yyyy.MM.dd').format(_anchorDate),
                            style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
                          ),
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
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                itemCount: items.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final item = items[index];
                                  if (item is _TimelineHeader) {
                                    return _buildDateHeader(item.date);
                                  } else if (item is _TimelineEntry) {
                                    return _buildTimelineEntry(item);
                                  }
                                  return const SizedBox.shrink();
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
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

  Widget _buildDateHeader(DateTime date) {
    return Row(
      children: [
        const Expanded(child: Divider(color: Color(0xFF223131))),
        const SizedBox(width: 8),
        Text(
          DateFormat('yyyy.MM.dd').format(date),
          style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        const Expanded(child: Divider(color: Color(0xFF223131))),
      ],
    );
  }

  Widget _buildTimelineEntry(_TimelineEntry entry) {
    final timeText = DateFormat('HH:mm').format(entry.time);
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF151C21),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF223131)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(entry.icon, color: entry.color, size: 18),
              const SizedBox(width: 8),
              Text(
                entry.label,
                style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700),
              ),
              if (entry.isTag) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F1518),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: const Color(0xFF223131)),
                  ),
                  child: const Text('태그', style: TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ],
            ],
          ),
          if (entry.note != null && entry.note!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(entry.note!, style: const TextStyle(color: Colors.white60, fontSize: 13)),
            ),
        ],
      ),
    );

    final wrappedCard = entry.isTag && entry.setId != null && entry.studentId != null
        ? _wrapSwipeActions(
            child: card,
            onEdit: () => _editTimelineEntry(entry),
            onDelete: () => _deleteTimelineEntry(entry),
          )
        : card;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 54,
            child: Text(
              timeText,
              style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 6),
          Column(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: entry.color.withOpacity(0.18),
                  border: Border.all(color: entry.color, width: 1.5),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Container(width: 2, color: const Color(0xFF223131)),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(child: wrappedCard),
        ],
      ),
    );
  }

  List<_TimelineEntry> _collectTimelineEntries(StudentWithInfo student, DateTime anchor, int days) {
    final List<_TimelineEntry> all = [];
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

  List<_TimelineEntry> _collectEntriesForRange(
    StudentWithInfo student,
    DateTime start,
    DateTime end,
    List<AttendanceRecord> records,
  ) {
    final entries = <_TimelineEntry>[];
    final seen = <String>{};
    final studentId = student.student.id;

    if (_showAttendance) {
      for (final record in records) {
        final arrival = record.arrivalTime?.toLocal();
        final departure = record.departureTime?.toLocal();
        if (arrival != null && !arrival.isBefore(start) && arrival.isBefore(end)) {
          final key = 'arr_${arrival.millisecondsSinceEpoch}';
          if (seen.add(key)) {
            entries.add(_TimelineEntry(
              time: arrival,
              icon: Icons.login,
              color: _attendanceColor,
              label: '등원',
              isTag: false,
            ));
          }
        }
        if (departure != null && !departure.isBefore(start) && departure.isBefore(end)) {
          final key = 'dep_${departure.millisecondsSinceEpoch}';
          if (seen.add(key)) {
            entries.add(_TimelineEntry(
              time: departure,
              icon: Icons.logout,
              color: _attendanceColor,
              label: '하원',
              isTag: false,
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
          final ts = event.timestamp.toLocal();
          if (ts.isAfter(start) && ts.isBefore(end)) {
            final key = 'tag_${block.setId}_${event.tagName}_${ts.millisecondsSinceEpoch}_${event.note ?? ''}';
            if (seen.add(key)) {
              final bool isRecord = event.tagName.trim() == '기록';
              entries.add(_TimelineEntry(
                time: ts,
                icon: IconData(event.iconCodePoint, fontFamily: 'MaterialIcons'),
                color: isRecord ? _recordColor : Color(event.colorValue),
                label: event.tagName,
                note: event.note,
                isTag: true,
                setId: block.setId,
                studentId: studentId,
                rawColorValue: event.colorValue,
                rawIconCodePoint: event.iconCodePoint,
              ));
            }
          }
        }
      }
    }

    return entries;
  }

  List<dynamic> _buildRenderableTimeline(List<_TimelineEntry> entries) {
    final List<dynamic> list = [];
    DateTime? currentDate;
    for (final entry in entries) {
      final date = DateTime(entry.time.year, entry.time.month, entry.time.day);
      if (currentDate == null || currentDate.millisecondsSinceEpoch != date.millisecondsSinceEpoch) {
        currentDate = date;
        list.add(_TimelineHeader(date: date));
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

  Widget _wrapSwipeActions({
    required Widget child,
    required Future<void> Function() onEdit,
    required Future<void> Function() onDelete,
  }) {
    const double paneW = 140;
    final radius = BorderRadius.circular(12);
    final actionPane = Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
      child: Row(
        children: [
          Expanded(
            child: Material(
              color: const Color(0xFF223131),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: () async => onEdit(),
                borderRadius: BorderRadius.circular(10),
                splashFactory: NoSplash.splashFactory,
                highlightColor: Colors.white.withOpacity(0.06),
                hoverColor: Colors.white.withOpacity(0.03),
                child: const SizedBox.expand(
                  child: Center(
                    child: Icon(Icons.edit_outlined, color: Color(0xFFEAF2F2), size: 18),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Material(
              color: const Color(0xFFB74C4C),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: () async => onDelete(),
                borderRadius: BorderRadius.circular(10),
                splashFactory: NoSplash.splashFactory,
                highlightColor: Colors.white.withOpacity(0.08),
                hoverColor: Colors.white.withOpacity(0.04),
                child: const SizedBox.expand(
                  child: Center(
                    child: Icon(Icons.delete_outline_rounded, color: Colors.white, size: 18),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return SwipeActionReveal(
      enabled: true,
      actionPaneWidth: paneW,
      borderRadius: radius,
      actionPane: actionPane,
      child: child,
    );
  }

  Future<void> _editTimelineEntry(_TimelineEntry entry) async {
    if (entry.setId == null || entry.studentId == null) return;
    final title = entry.label.trim() == '기록' ? '기록 수정' : '태그 메모 수정';
    final edited = await _openTimelineNoteDialog(
      title: title,
      initial: entry.note ?? '',
    );
    if (edited == null) return;
    final trimmed = edited.trim();
    final updated = TagEvent(
      tagName: entry.label,
      colorValue: entry.rawColorValue ?? entry.color.value,
      iconCodePoint: entry.rawIconCodePoint ?? entry.icon.codePoint,
      timestamp: entry.time,
      note: trimmed.isEmpty ? null : trimmed,
    );
    TagStore.instance.updateEvent(entry.setId!, entry.studentId!, updated);
  }

  Future<void> _deleteTimelineEntry(_TimelineEntry entry) async {
    if (entry.setId == null || entry.studentId == null) return;
    final ok = await _confirmDeleteTimelineEntry(entry.label);
    if (ok != true) return;
    final target = TagEvent(
      tagName: entry.label,
      colorValue: entry.rawColorValue ?? entry.color.value,
      iconCodePoint: entry.rawIconCodePoint ?? entry.icon.codePoint,
      timestamp: entry.time,
      note: entry.note,
    );
    TagStore.instance.deleteEvent(entry.setId!, entry.studentId!, target);
  }

  Future<bool?> _confirmDeleteTimelineEntry(String label) async {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kDlgBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: kDlgBorder),
        ),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        title: const Text('기록 삭제', style: TextStyle(color: kDlgText, fontSize: 20, fontWeight: FontWeight.w900)),
        content: Text(
          '“$label” 기록을 삭제할까요?',
          style: const TextStyle(color: kDlgTextSub),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB74C4C)),
            child: const Text('삭제', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<String?> _openTimelineNoteDialog({
    required String title,
    required String initial,
  }) async {
    final controller = ImeAwareTextEditingController(text: initial);
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kDlgBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: kDlgBorder),
        ),
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        title: Text(title, style: const TextStyle(color: kDlgText, fontSize: 20, fontWeight: FontWeight.w900)),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: '메모를 입력하세요',
              hintStyle: const TextStyle(color: kDlgTextSub),
              filled: true,
              fillColor: kDlgFieldBg,
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: kDlgBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: kDlgAccent),
              ),
            ),
            style: const TextStyle(color: kDlgText),
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
              FocusScope.of(ctx).unfocus();
              controller.value = controller.value.copyWith(composing: TextRange.empty);
              Navigator.of(ctx).pop(controller.text);
            },
            style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
            child: const Text('저장', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
    return result;
  }
}

class _TimelineEntry {
  final DateTime time;
  final IconData icon;
  final Color color;
  final String label;
  final String? note;
  final bool isTag;
  final String? setId;
  final String? studentId;
  final int? rawColorValue;
  final int? rawIconCodePoint;

  _TimelineEntry({
    required this.time,
    required this.icon,
    required this.color,
    required this.label,
    this.note,
    required this.isTag,
    this.setId,
    this.studentId,
    this.rawColorValue,
    this.rawIconCodePoint,
  });
}

class _TimelineHeader {
  final DateTime date;
  _TimelineHeader({required this.date});
}