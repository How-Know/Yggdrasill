import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/tenant_service.dart';
import '../services/data_manager.dart';

class ClassContentEventsDialog extends StatefulWidget {
  const ClassContentEventsDialog({super.key});

  @override
  State<ClassContentEventsDialog> createState() => _ClassContentEventsDialogState();
}

class _ClassContentEventsDialogState extends State<ClassContentEventsDialog> {
  bool _loading = true;
  String? _error;
  List<_TimelineEvent> _events = const [];
  List<_TimelineEvent> _allEvents = const [];
  List<_StudentBrief> _attending = const [];
  String? _filterStudentId;
  late DateTime _selectedDayStart;
  _EventType? _filterType;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDayStart = DateTime(now.year, now.month, now.day);
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final String academyId = (await TenantService.instance.getActiveAcademyId()) ?? await TenantService.instance.ensureActiveAcademy();
      final supa = Supabase.instance.client;

      final hwRows = await supa
          .from('homework_item_phase_events')
          .select('item_id, phase, at, note')
          .eq('academy_id', academyId)
          .order('at', ascending: false)
          .limit(200);

    final List<_TimelineEvent> evs = [];
      final List<String> itemIds = [];
      for (final r in (hwRows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final String itemId = (r['item_id'] as String?) ?? '';
        final int phase = ((r['phase'] as num?) ?? 0).toInt();
        final DateTime at = DateTime.tryParse((r['at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
        final String? note = r['note'] as String?;
        if (itemId.isNotEmpty) itemIds.add(itemId);
        evs.add(_TimelineEvent(
          type: _EventType.homework,
          timestamp: at,
          title: _phaseLabel(phase),
          subtitle: note ?? '',
          color: _phaseColor(phase),
          icon: _phaseIcon(phase),
          relatedId: itemId,
          studentId: null,
        ));
      }

      Map<String, _HomeworkItemBrief> briefByItem = {};
      if (itemIds.isNotEmpty) {
        final items = await supa
            .from('homework_items')
            .select('id, student_id, title')
            .inFilter('id', itemIds.toSet().toList());
        for (final r in (items as List<dynamic>).cast<Map<String, dynamic>>()) {
          final id = (r['id'] as String?) ?? '';
          if (id.isEmpty) continue;
          briefByItem[id] = _HomeworkItemBrief(
            id: id,
            studentId: (r['student_id'] as String?) ?? '',
            title: (r['title'] as String?) ?? '',
          );
        }
      }

      final tagRows = await supa
          .from('tag_events')
          .select('set_id, student_id, tag_name, color_value, icon_code, occurred_at, note')
          .eq('academy_id', academyId)
          .order('occurred_at', ascending: false)
          .limit(200);

      for (final r in (tagRows as List<dynamic>).cast<Map<String, dynamic>>()) {
        final DateTime at = DateTime.tryParse((r['occurred_at'] as String?) ?? '')?.toLocal() ?? DateTime.now();
        final String tagName = (r['tag_name'] as String?) ?? '';
        final int colorValue = ((r['color_value'] as num?) ?? 0xFF1976D2).toInt();
        final int iconCode = ((r['icon_code'] as num?) ?? 0).toInt();
        final String studentId = (r['student_id'] as String?) ?? '';
        final String? note = r['note'] as String?;
        evs.add(_TimelineEvent(
          type: _EventType.tag,
          timestamp: at,
          title: tagName,
          subtitle: note ?? '',
          color: Color(colorValue),
          icon: IconData(iconCode, fontFamily: 'MaterialIcons'),
          relatedId: studentId,
          studentId: studentId,
        ));
      }

      // Attendance (등원/하원) 추가
      for (final rec in DataManager.instance.attendanceRecords) {
        final studentId = rec.studentId;
        if (rec.arrivalTime != null) {
          evs.add(_TimelineEvent(
            type: _EventType.attendance,
            timestamp: rec.arrivalTime!.toLocal(),
            title: '등원',
            subtitle: '',
            color: const Color(0xFF4CAF50),
            icon: Icons.login,
            relatedId: studentId,
            studentId: studentId,
          ));
        }
        if (rec.departureTime != null) {
          evs.add(_TimelineEvent(
            type: _EventType.attendance,
            timestamp: rec.departureTime!.toLocal(),
            title: '하원',
            subtitle: '',
            color: const Color(0xFFE57373),
            icon: Icons.logout,
            relatedId: studentId,
            studentId: studentId,
          ));
        }
      }

      evs.sort((a,b) => b.timestamp.compareTo(a.timestamp));

      // Hydrate subtitles with student name where possible
      final students = DataManager.instance.students.map((s) => s.student).toList();
      String nameOf(String id) {
        if (students.isEmpty) return '';
        final idx = students.indexWhere((x) => x.id == id);
        return (idx == -1 ? students.first : students[idx]).name;
      }
      for (int i = 0; i < evs.length; i++) {
        final e = evs[i];
        if (e.type == _EventType.homework) {
          final brief = briefByItem[e.relatedId];
          if (brief != null) {
            final studentName = nameOf(brief.studentId);
            evs[i] = e.copyWith(subtitle: (brief.title.isEmpty ? studentName : '$studentName · ${brief.title}'));
            evs[i] = evs[i].withStudent(brief.studentId);
          }
        } else if (e.type == _EventType.tag) {
          final studentName = nameOf(e.relatedId);
          evs[i] = e.copyWith(subtitle: studentName + (e.subtitle.isNotEmpty ? ' · ' + e.subtitle : ''));
        }
      }

      // Compute current attending students (arrival today and no departure)
      final DateTime now = DateTime.now();
      bool sameDay(DateTime a, DateTime b) => a.year==b.year && a.month==b.month && a.day==b.day;
      final Set<String> attendingIds = {};
      for (final rec in DataManager.instance.attendanceRecords) {
        if (!rec.isPresent) continue;
        if (rec.arrivalTime == null) continue;
        if (rec.departureTime != null) continue;
        if (!sameDay(rec.classDateTime, now)) continue;
        attendingIds.add(rec.studentId);
      }
      final List<_StudentBrief> attending = attendingIds.map((sid) {
        final idx = students.indexWhere((x) => x.id == sid);
        final name = (idx == -1 ? sid : students[idx].name);
        return _StudentBrief(id: sid, name: name);
      }).toList()
        ..sort((a,b)=>a.name.compareTo(b.name));

      setState(() { _allEvents = evs; _attending = attending; _loading = false; });
      _applyFilter();
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  void _applyFilter() {
    final start = _selectedDayStart;
    final end = start.add(const Duration(days: 1));
    final List<_TimelineEvent> filtered = _allEvents.where((e) {
      if (e.timestamp.isBefore(start) || !e.timestamp.isBefore(end)) return false;
      if (_filterType != null && e.type != _filterType) return false;
      if (_filterStudentId != null && _filterStudentId!.isNotEmpty && e.studentId != _filterStudentId) return false;
      return true;
    }).toList();
    setState(() {
      _events = filtered;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0B1112),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.all(24),
      child: Container(
        padding: const EdgeInsets.fromLTRB(26, 26, 26, 18),
        width: 770,
        height: 640,
        color: const Color(0xFF0B1112),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _TimelineDayToolbar(
                dayStart: _selectedDayStart,
                onPrev: () => setState(() {
                  _selectedDayStart = _selectedDayStart.subtract(const Duration(days: 1));
                  _applyFilter();
                }),
                onNext: () => setState(() {
                  _selectedDayStart = _selectedDayStart.add(const Duration(days: 1));
                  _applyFilter();
                }),
                onPickDay: (picked) {
                  setState(() {
                    _selectedDayStart = DateTime(picked.year, picked.month, picked.day);
                  });
                  _applyFilter();
                },
              ),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _buildFilterChips(),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : (_error != null
                        ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
                        : _buildList()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: SizedBox(
        height: 48,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.max,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
                    onPressed: () => Navigator.of(context).maybePop(),
                    tooltip: '닫기',
                    padding: EdgeInsets.zero,
                  ),
                ),
                const Text(
                  '수업 타임라인',
                  style: TextStyle(
                    color: Color(0xFFEAF2F2),
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            Positioned(
              right: 0,
              child: IconButton(
                tooltip: '새로 고침',
                onPressed: _load,
                icon: const Icon(Icons.refresh, color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList() {
    String nameOf(String? id) {
      if (id == null || id.isEmpty) return '';
      final students = DataManager.instance.students.map((s) => s.student).toList();
      if (students.isEmpty) return '';
      final idx = students.indexWhere((x) => x.id == id);
      return (idx == -1 ? students.first.name : students[idx].name);
    }

    return ListView.separated(
      itemCount: _events.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0x22FFFFFF)),
      itemBuilder: (ctx, i) {
        final e = _events[i];
        final studentName = nameOf(e.studentId);
        final displayTitle = studentName.isNotEmpty ? '$studentName · ${e.title}' : e.title;
        final subtitle = '${_format(e.timestamp)}${e.subtitle.isNotEmpty ? ' · ${e.subtitle}' : ''}';
        return ListTile(
          dense: true,
          leading: CircleAvatar(radius: 14, backgroundColor: e.color.withOpacity(0.2), child: Icon(e.icon, color: e.color, size: 16)),
          title: Text(displayTitle, style: const TextStyle(color: Colors.white)),
          subtitle: Text(subtitle, style: const TextStyle(color: Colors.white60)),
        );
      },
    );
  }

  Widget _buildFilterChips() {
    Widget chip({
      required String label,
      required bool selected,
      required VoidCallback onTap,
      Widget? leading,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              height: 36,
              decoration: BoxDecoration(
                color: selected ? const Color(0xFF1B6B63) : const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leading != null) ...[leading, const SizedBox(width: 6)],
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? Colors.white : const Color(0xFFCDD5D5),
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final List<Widget> chips = [];
    final bool allSel = _filterType == null && _filterStudentId == null;
    chips.add(chip(
      label: '전체',
      selected: allSel,
      leading: const Icon(Icons.all_inclusive, size: 14, color: Colors.white70),
      onTap: () {
        setState(() {
          _filterStudentId = null;
          _filterType = null;
        });
        _applyFilter();
      },
    ));

    final bool attSel = _filterType == _EventType.attendance && (_filterStudentId == null || _filterStudentId!.isEmpty);
    chips.add(chip(
      label: '등하원',
      selected: attSel,
      onTap: () {
        setState(() {
          _filterType = _EventType.attendance;
          _filterStudentId = null;
        });
        _applyFilter();
      },
    ));

    final bool tagSel = _filterType == _EventType.tag && (_filterStudentId == null || _filterStudentId!.isEmpty);
    chips.add(chip(
      label: '활동(태그)',
      selected: tagSel,
      onTap: () {
        setState(() {
          _filterType = _EventType.tag;
          _filterStudentId = null;
        });
        _applyFilter();
      },
    ));
    for (final s in _attending) {
      final bool sel = _filterStudentId == s.id;
      chips.add(chip(
        label: s.name,
        selected: sel,
        leading: const Icon(Icons.person, size: 14, color: Colors.white70),
        onTap: () {
          setState(() {
            _filterStudentId = s.id;
            _filterType = null; // 학생 선택 시 유형 필터 해제
          });
          _applyFilter();
        },
      ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: chips),
    );
  }

  String _format(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}.${two(dt.month)}.${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _TimelineDayToolbar extends StatelessWidget {
  final DateTime dayStart;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final ValueChanged<DateTime>? onPickDay;
  final bool compact;

  const _TimelineDayToolbar({
    required this.dayStart,
    required this.onPrev,
    required this.onNext,
    this.onPickDay,
    this.compact = true,
  });

  @override
  Widget build(BuildContext context) {
    final label = '${dayStart.year}.${dayStart.month.toString().padLeft(2, '0')}.${dayStart.day.toString().padLeft(2, '0')}';
    final baseTextStyle = TextStyle(
      color: const Color(0xFFEAF2F2),
      fontSize: compact ? 18 : 24,
      fontWeight: FontWeight.bold,
    );

    return Row(
      mainAxisSize: MainAxisSize.max,
      children: [
        IconButton(
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left, color: Colors.white70),
          tooltip: '이전 날',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: () {
            final now = DateTime.now();
            onPickDay?.call(DateTime(now.year, now.month, now.day));
          },
          child: SizedBox(
            width: 120,
            child: Center(child: Text(label, style: baseTextStyle)),
          ),
        ),
        const SizedBox(width: 10),
        IconButton(
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right, color: Colors.white70),
          tooltip: '다음 날',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: () async {
            final picked = await showDatePicker(
              context: context,
              initialDate: dayStart,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
              builder: (context, child) => Theme(
                data: Theme.of(context).copyWith(
                  colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
                  dialogBackgroundColor: const Color(0xFF1F1F1F),
                ),
                child: child!,
              ),
            );
            if (picked != null) onPickDay?.call(picked);
          },
          icon: const Icon(Icons.date_range, size: 20, color: Colors.white54),
          padding: EdgeInsets.zero,
          tooltip: '달력',
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
      ],
    );
  }
}

enum _EventType { homework, tag, attendance }

class _TimelineEvent {
  final _EventType type;
  final DateTime timestamp;
  final String title;
  final String subtitle;
  final Color color;
  final IconData icon;
  final String relatedId; // homework: item_id, tag: student_id
  final String? studentId; // normalized student id for filtering
  const _TimelineEvent({required this.type, required this.timestamp, required this.title, required this.subtitle, required this.color, required this.icon, required this.relatedId, required this.studentId});
  _TimelineEvent copyWith({String? subtitle}) => _TimelineEvent(type: type, timestamp: timestamp, title: title, subtitle: subtitle ?? this.subtitle, color: color, icon: icon, relatedId: relatedId, studentId: studentId);
  _TimelineEvent withStudent(String sid) => _TimelineEvent(type: type, timestamp: timestamp, title: title, subtitle: subtitle, color: color, icon: icon, relatedId: relatedId, studentId: sid);
}

class _HomeworkItemBrief {
  final String id;
  final String studentId;
  final String title;
  const _HomeworkItemBrief({required this.id, required this.studentId, required this.title});
}

class _StudentBrief {
  final String id;
  final String name;
  const _StudentBrief({required this.id, required this.name});
}

String _phaseLabel(int phase) {
  switch (phase) {
    case 0: return '종료';
    case 1: return '대기';
    case 2: return '수행';
    case 3: return '제출';
    case 4: return '확인';
  }
  return '알수없음';
}

Color _phaseColor(int phase) {
  switch (phase) {
    case 2: return const Color(0xFF4CAF50);
    case 3: return const Color(0xFFFFB300);
    case 4: return const Color(0xFF42A5F5);
    case 0:
    case 1:
    default: return Colors.white54;
  }
}

IconData _phaseIcon(int phase) {
  switch (phase) {
    case 2: return Icons.play_arrow_rounded;
    case 3: return Icons.hourglass_bottom_rounded;
    case 4: return Icons.pending_actions_rounded;
    case 0:
    case 1:
    default: return Icons.pause_circle_outline;
  }
}


