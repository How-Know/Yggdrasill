import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/data_manager.dart';
import '../../models/student.dart';
import '../../models/education_level.dart';
import '../../models/student_flow.dart';
import '../../widgets/pill_tab_selector.dart';
import '../../models/attendance_record.dart';
import '../../services/homework_store.dart';
import '../../services/homework_assignment_store.dart';
import '../../services/tag_store.dart';
import '../../services/student_flow_store.dart';
import '../../screens/learning/tag_preset_dialog.dart';
import '../../widgets/swipe_action_reveal.dart';
import '../../widgets/dialog_tokens.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

class StudentProfilePage extends StatefulWidget {
  final StudentWithInfo studentWithInfo;
  final List<StudentFlow>? flows;

  const StudentProfilePage({
    super.key,
    required this.studentWithInfo,
    this.flows = const [],
  });

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
                            flows: widget.flows,
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
            tabs: const ['요약', '수업 일지', '스탯'],
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
  final List<StudentFlow>? flows;
  const _StudentProfileContent({
    required this.tabIndex,
    required this.studentWithInfo,
    required this.flows,
  });

  @override
  Widget build(BuildContext context) {
    if (tabIndex == 1) {
      final safeFlows = flows ?? const <StudentFlow>[];
      return _StudentTimelineView(
        studentWithInfo: studentWithInfo,
        flows: safeFlows,
      );
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
  final List<StudentFlow>? flows;
  const _StudentTimelineView({
    required this.studentWithInfo,
    required this.flows,
  });

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
    unawaited(HomeworkStore.instance.loadAll());
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
            final enabledFlows =
                (widget.flows ?? const <StudentFlow>[])
                    .where((f) => f.enabled)
                    .toList();
            // 요청 반영:
            // - 태그 타임라인 너비 20% 축소
            // - 플로우 카드 너비 10% 확대
            const double timelineMaxWidth = 860 * 0.56;
            const double flowCardWidth = 260 * 1.43;
            const double flowCardSpacing = 12;
            final int flowCount = enabledFlows.length;
            final double flowSidebarWidth = flowCount == 0
                ? 0
                : (flowCardWidth * flowCount) +
                    (flowCardSpacing * (flowCount - 1));
            final timelineCard = ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: timelineMaxWidth),
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
            );
            return Align(
              alignment: Alignment.topCenter,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: timelineMaxWidth, child: timelineCard),
                  if (enabledFlows.isNotEmpty) ...[
                    const SizedBox(width: flowCardSpacing),
                    SizedBox(
                      width: flowSidebarWidth,
                      child: _FlowHomeworkSidebar(
                        studentId: widget.studentWithInfo.student.id,
                        flows: enabledFlows,
                        cardWidth: flowCardWidth,
                      ),
                    ),
                  ],
                ],
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

class _HomeworkStats {
  final int inProgress;
  final int homework;
  final int completed;
  const _HomeworkStats({
    required this.inProgress,
    required this.homework,
    required this.completed,
  });

  factory _HomeworkStats.fromItems(List<HomeworkItem> items) {
    int inProgress = 0;
    int homework = 0;
    int completed = 0;
    for (final item in items) {
      switch (item.status) {
        case HomeworkStatus.inProgress:
          inProgress += 1;
          break;
        case HomeworkStatus.homework:
          homework += 1;
          break;
        case HomeworkStatus.completed:
          completed += 1;
          break;
      }
    }
    return _HomeworkStats(
      inProgress: inProgress,
      homework: homework,
      completed: completed,
    );
  }
}

class _FlowHomeworkSidebar extends StatefulWidget {
  final String studentId;
  final List<StudentFlow> flows;
  final double cardWidth;
  const _FlowHomeworkSidebar({
    required this.studentId,
    required this.flows,
    required this.cardWidth,
  });

  @override
  State<_FlowHomeworkSidebar> createState() => _FlowHomeworkSidebarState();
}

class _FlowHomeworkSidebarState extends State<_FlowHomeworkSidebar> {
  late Future<Map<String, List<HomeworkAssignmentBrief>>> _assignmentsFuture;
  late Future<Map<String, List<HomeworkAssignmentCheck>>> _checksFuture;
  int _lastAssignmentRevision = -1;

  @override
  void initState() {
    super.initState();
    _reloadAssignmentData();
  }

  @override
  void didUpdateWidget(covariant _FlowHomeworkSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.studentId != widget.studentId) {
      _reloadAssignmentData();
    }
  }

  void _reloadAssignmentData() {
    _assignmentsFuture =
        HomeworkAssignmentStore.instance.loadAssignmentsForStudent(widget.studentId);
    _checksFuture =
        HomeworkAssignmentStore.instance.loadChecksForStudent(widget.studentId);
  }

  int _flowPriority(StudentFlow flow) {
    final name = flow.name.trim();
    if (name == '현행') return 0;
    if (name == '선행') return 1;
    return 2;
  }

  List<StudentFlow> _sortedFlows(List<StudentFlow> input) {
    final list = List<StudentFlow>.from(input);
    list.sort((a, b) {
      final pa = _flowPriority(a);
      final pb = _flowPriority(b);
      if (pa != pb) return pa - pb;
      if (pa == 2) {
        final oi = a.orderIndex.compareTo(b.orderIndex);
        if (oi != 0) return oi;
      }
      return a.name.compareTo(b.name);
    });
    return list;
  }

  Future<void> _renameFlow(BuildContext context, StudentFlow flow) async {
    final controller = ImeAwareTextEditingController(text: flow.name);
    final nextName = await showDialog<String?>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: kDlgBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('플로우 이름 변경', style: TextStyle(color: kDlgText, fontWeight: FontWeight.w900)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: kDlgText, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            labelText: '플로우 이름',
            labelStyle: const TextStyle(color: kDlgTextSub),
            filled: true,
            fillColor: kDlgFieldBg,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: kDlgBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: kDlgAccent, width: 1.4),
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            style: TextButton.styleFrom(foregroundColor: kDlgTextSub),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: kDlgAccent),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = nextName?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == flow.name) return;
    try {
      final allFlows =
          await StudentFlowStore.instance.loadForStudent(widget.studentId, force: true);
      final base = allFlows.isNotEmpty ? allFlows : widget.flows;
      final updated = base
          .map((f) => f.id == flow.id ? f.copyWith(name: trimmed) : f)
          .toList();
      await StudentFlowStore.instance.saveFlows(widget.studentId, updated);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('플로우 이름 변경 실패')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: HomeworkAssignmentStore.instance.revision,
      builder: (context, rev, _) {
        if (_lastAssignmentRevision != rev) {
          _lastAssignmentRevision = rev;
          _reloadAssignmentData();
        }
        return FutureBuilder<Map<String, List<HomeworkAssignmentBrief>>>(
          future: _assignmentsFuture,
          builder: (context, assignmentsSnapshot) {
            final assignmentsByItem =
                assignmentsSnapshot.data ??
                    const <String, List<HomeworkAssignmentBrief>>{};
            return FutureBuilder<Map<String, List<HomeworkAssignmentCheck>>>(
              future: _checksFuture,
              builder: (context, checksSnapshot) {
                final checksByItem =
                    checksSnapshot.data ??
                        const <String, List<HomeworkAssignmentCheck>>{};
                return ValueListenableBuilder<int>(
                  valueListenable: StudentFlowStore.instance.revision,
                  builder: (_, __, ___) {
                    final latest =
                        StudentFlowStore.instance.cached(widget.studentId);
                    final displayFlows = latest.isNotEmpty
                        ? latest.where((f) => f.enabled).toList()
                        : widget.flows;
                    final sortedFlows = _sortedFlows(displayFlows);
                    return ValueListenableBuilder<int>(
                      valueListenable: HomeworkStore.instance.revision,
                      builder: (_, __, ___) {
                        final allItems =
                            HomeworkStore.instance.items(widget.studentId);
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (int i = 0; i < sortedFlows.length; i++) ...[
                              SizedBox(
                                width: widget.cardWidth,
                                child: _FlowHomeworkCard(
                                  flow: sortedFlows[i],
                                  items: allItems
                                      .where((e) =>
                                          e.flowId == sortedFlows[i].id)
                                      .toList(),
                                  assignmentsByItem: assignmentsByItem,
                                  checksByItem: checksByItem,
                                  onEditName: _flowPriority(sortedFlows[i]) <= 1
                                      ? null
                                      : () =>
                                          _renameFlow(context, sortedFlows[i]),
                                ),
                              ),
                              if (i != sortedFlows.length - 1)
                                const SizedBox(width: 12),
                            ],
                          ],
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _FlowHomeworkCard extends StatefulWidget {
  final StudentFlow flow;
  final List<HomeworkItem> items;
  final Map<String, List<HomeworkAssignmentBrief>> assignmentsByItem;
  final Map<String, List<HomeworkAssignmentCheck>> checksByItem;
  final VoidCallback? onEditName;
  const _FlowHomeworkCard({
    required this.flow,
    required this.items,
    required this.assignmentsByItem,
    required this.checksByItem,
    required this.onEditName,
  });

  @override
  State<_FlowHomeworkCard> createState() => _FlowHomeworkCardState();
}

class _FlowHomeworkCardState extends State<_FlowHomeworkCard> {
  final Set<String> _expandedIds = <String>{};

  DateTime? _sortKey(HomeworkItem item) {
    return item.completedAt ??
        item.firstStartedAt ??
        item.updatedAt ??
        item.createdAt ??
        item.runStart;
  }

  List<HomeworkItem> _sortedItems() {
    final list = List<HomeworkItem>.from(widget.items);
    list.sort((a, b) {
      final ka = _sortKey(a);
      final kb = _sortKey(b);
      if (ka == null && kb == null) return 0;
      if (ka == null) return 1;
      if (kb == null) return -1;
      return kb.compareTo(ka); // 최신이 위
    });
    return list;
  }

  String _formatTime(DateTime? time) {
    if (time == null) return '-';
    return DateFormat('MM.dd HH:mm').format(time);
  }

  String _formatDuration(HomeworkItem hw) {
    final runningMs = hw.runStart != null
        ? DateTime.now().difference(hw.runStart!).inMilliseconds
        : 0;
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

  List<_HomeworkRoundData> _buildAssignmentRounds(
    List<HomeworkAssignmentBrief> assignments,
    List<HomeworkAssignmentCheck> checks,
  ) {
    if (checks.isEmpty) return const <_HomeworkRoundData>[];
    final sortedAssignments = List<HomeworkAssignmentBrief>.from(assignments)
      ..sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
    final sortedChecks = List<HomeworkAssignmentCheck>.from(checks)
      ..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));

    final Map<String, HomeworkAssignmentBrief> assignmentById = {
      for (final assignment in sortedAssignments) assignment.id: assignment,
    };
    final Set<String> usedAssignmentIds = <String>{};

    HomeworkAssignmentBrief? fallbackFor(HomeworkAssignmentCheck check) {
      HomeworkAssignmentBrief? nearestBefore;
      for (final assignment in sortedAssignments) {
        if (assignment.assignedAt.isAfter(check.checkedAt)) break;
        if (!usedAssignmentIds.contains(assignment.id)) {
          nearestBefore = assignment;
        }
      }
      if (nearestBefore != null) return nearestBefore;
      for (final assignment in sortedAssignments) {
        if (!usedAssignmentIds.contains(assignment.id)) return assignment;
      }
      return sortedAssignments.isNotEmpty ? sortedAssignments.last : null;
    }

    final List<_HomeworkRoundData> rounds = <_HomeworkRoundData>[];
    for (int i = 0; i < sortedChecks.length; i++) {
      final check = sortedChecks[i];
      HomeworkAssignmentBrief? linked;
      final assignmentId = check.assignmentId;
      if (assignmentId != null && assignmentId.isNotEmpty) {
        linked = assignmentById[assignmentId];
      }
      linked ??= fallbackFor(check);
      if (linked != null) {
        usedAssignmentIds.add(linked.id);
      }
      rounds.add(
        _HomeworkRoundData(
          round: i + 1,
          assignedAt: linked?.assignedAt,
          checkedAt: check.checkedAt,
          progress: check.progress,
        ),
      );
    }
    return rounds;
  }

  Widget _metaItem(String label, String value) {
    final safe = value.trim().isEmpty ? '-' : value.trim();
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$label ',
            style: const TextStyle(
              color: Color(0xFF9FB3B3),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: safe,
            style: const TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _detailRow(String label, String value) {
    final safe = value.trim().isEmpty ? '-' : value.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF9FB3B3),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            safe,
            style: const TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
            softWrap: true,
          ),
        ),
      ],
    );
  }

  Widget _buildHomeworkCard(HomeworkItem hw) {
    final bool isCompleted = hw.status == HomeworkStatus.completed;
    final assignments = widget.assignmentsByItem[hw.id] ?? const <HomeworkAssignmentBrief>[];
    final checks = widget.checksByItem[hw.id] ?? const <HomeworkAssignmentCheck>[];
    final int assignmentCount = assignments.length;
    final String homeworkLabel = assignmentCount > 0 ? 'H$assignmentCount' : '';
    final int checkCount =
        checks.isNotEmpty ? checks.length : hw.checkCount;
    final DateTime? startTime =
        hw.firstStartedAt ?? hw.runStart ?? hw.createdAt ?? hw.updatedAt;
    final DateTime? endTime = isCompleted
        ? (hw.completedAt ?? hw.confirmedAt ?? hw.updatedAt)
        : null;
    final String type = (hw.type ?? '').trim();
    final String title = hw.title.trim().isEmpty ? '(제목 없음)' : hw.title.trim();
    final String page = (hw.page ?? '').trim();
    final String count = hw.count != null ? hw.count.toString() : '';
    final String duration = _formatDuration(hw);
    final String content =
        (hw.content ?? '').trim().isNotEmpty ? (hw.content ?? '').trim() : hw.body.trim();

    final List<HomeworkAssignmentBrief> sortedAssignments =
        List<HomeworkAssignmentBrief>.from(assignments)
          ..sort((a, b) => a.assignedAt.compareTo(b.assignedAt));
    final List<HomeworkAssignmentCheck> sortedChecks =
        List<HomeworkAssignmentCheck>.from(checks)
          ..sort((a, b) => a.checkedAt.compareTo(b.checkedAt));
    final List<_HomeworkRoundData> rounds = _buildAssignmentRounds(
      sortedAssignments,
      sortedChecks,
    );

    final bool expanded = _expandedIds.contains(hw.id);
    final Color borderColor = isCompleted
        ? const Color(0xFF223131).withOpacity(0.6)
        : const Color(0xFF223131);
    final Color bgColor = isCompleted
        ? const Color(0xFF0B1112).withOpacity(0.6)
        : const Color(0xFF0B1112);
    return Opacity(
      opacity: isCompleted ? 0.55 : 1.0,
      child: InkWell(
        onTap: () {
          setState(() {
            if (expanded) {
              _expandedIds.remove(hw.id);
            } else {
              _expandedIds.add(hw.id);
            }
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (type.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: hw.color.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: hw.color.withOpacity(0.6)),
                      ),
                      child: Text(
                        type,
                        style: TextStyle(
                          color: hw.color,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  if (type.isNotEmpty) const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFFEAF2F2),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (homeworkLabel.isNotEmpty)
                    Text(
                      homeworkLabel,
                      style: const TextStyle(
                        color: Color(0xFF9FB3B3),
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _metaItem('페이지', page),
                  _metaItem('문항수', count),
                  _metaItem('시작', _formatTime(startTime)),
                  _metaItem('총 걸린시간', duration),
                  _metaItem('검사횟수', checkCount.toString()),
                ],
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 12),
                    const Divider(color: Color(0xFF223131), height: 1),
                    const SizedBox(height: 10),
                    if (isCompleted)
                      _detailRow('종료시간', _formatTime(endTime)),
                    _detailRow('내용', content),
                    const SizedBox(height: 12),
                    const Text(
                      '숙제 회차',
                      style: TextStyle(
                        color: Color(0xFF9FB3B3),
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (rounds.isEmpty)
                      const Text(
                        '검사 기록이 없습니다.',
                        style: TextStyle(
                          color: Color(0xFF9FB3B3),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    else
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (int i = 0; i < rounds.length; i++) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(
                                    width: 72,
                                    child: Text(
                                      '${rounds[i].round}회차',
                                      style: const TextStyle(
                                        color: Color(0xFFEAF2F2),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${_formatTime(rounds[i].assignedAt)}  →  ${_formatTime(rounds[i].checkedAt)}',
                                          style: const TextStyle(
                                            color: Color(0xFFCBD8D8),
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          '완료율 ${rounds[i].progress}%',
                                          style: const TextStyle(
                                            color: Color(0xFF9FB3B3),
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (i != rounds.length - 1)
                              const Divider(
                                color: Color(0xFF223131),
                                height: 12,
                                thickness: 1,
                              ),
                          ],
                        ],
                      ),
                  ],
                ),
                crossFadeState: expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 180),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sortedItems();
    return Container(
      padding: const EdgeInsets.fromLTRB(0, 12, 14, 12),
      decoration: const BoxDecoration(
        border: Border(
          right: BorderSide(color: Color(0xFF223131), width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_tree_outlined,
                  size: 18, color: Color(0xFF9FB3B3)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.flow.name,
                  style: const TextStyle(
                    color: Color(0xFFEAF2F2),
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (widget.onEditName != null)
                IconButton(
                  tooltip: '이름 변경',
                  onPressed: widget.onEditName,
                  icon: const Icon(Icons.edit, size: 18, color: Color(0xFF9FB3B3)),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
            ],
          ),
          const SizedBox(height: 12),
          _FlowTextbookSummary(),
          const SizedBox(height: 12),
          const Text(
            '과제 목록',
            style: TextStyle(
              color: Color(0xFF9FB3B3),
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          if (sorted.isEmpty)
            const Text(
              '등록된 과제가 없습니다.',
              style: TextStyle(color: Color(0xFF9FB3B3), fontSize: 14),
            )
          else
            Column(
              children: [
                for (int i = 0; i < sorted.length; i++) ...[
                  _buildHomeworkCard(sorted[i]),
                  if (i != sorted.length - 1) const SizedBox(height: 10),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _HomeworkRoundData {
  final int round;
  final DateTime? assignedAt;
  final DateTime checkedAt;
  final int progress;

  const _HomeworkRoundData({
    required this.round,
    required this.assignedAt,
    required this.checkedAt,
    required this.progress,
  });
}

class _FlowTextbookSummary extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const bool hasTextbook = false;
    if (!hasTextbook) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF10171A),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF223131)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.menu_book_outlined,
                    size: 18, color: Color(0xFF9FB3B3)),
                const SizedBox(width: 8),
                const Text(
                  '교재',
                  style: TextStyle(
                    color: Color(0xFFEAF2F2),
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('교재 추가는 아직 준비 중입니다.')),
                    );
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('추가'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF9FB3B3),
                    side: const BorderSide(color: Color(0xFF4D5A5A)),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    visualDensity:
                        const VisualDensity(horizontal: -3, vertical: -3),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '등록된 교재가 없습니다.',
              style: TextStyle(
                color: Color(0xFF9FB3B3),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    const String bookName = '교재';
    const double progress = 0.0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF10171A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF223131)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '교재',
            style: TextStyle(
              color: Color(0xFFEAF2F2),
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            bookName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFCBD8D8),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: const Color(0xFF1C2328),
              valueColor:
                  const AlwaysStoppedAnimation<Color>(Color(0xFF33A373)),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${(progress * 100).toStringAsFixed(0)}%',
            style: const TextStyle(
              color: Color(0xFF9FB3B3),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _FlowStatRow extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  const _FlowStatRow({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFFB9C8C8),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          value.toString(),
          style: TextStyle(
            color: color,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
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