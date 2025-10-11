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

  @override
  void initState() {
    super.initState();
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

      setState(() { _allEvents = evs; _attending = attending; _applyFilter(); _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  void _applyFilter() {
    if (_filterStudentId == null || _filterStudentId!.isEmpty) {
      _events = _allEvents;
    } else {
      _events = _allEvents.where((e) => (e.studentId ?? '').isNotEmpty && e.studentId == _filterStudentId).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Row(
        children: [
          const Text('이벤트 타임라인', style: TextStyle(color: Colors.white, fontSize: 20)),
          const Spacer(),
          IconButton(
            tooltip: '새로 고침',
            onPressed: _load,
            icon: const Icon(Icons.refresh, color: Colors.white70),
          )
        ],
      ),
      content: SizedBox(
        width: 648,
        height: 570,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : (_error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFilterChips(),
                      const SizedBox(height: 8),
                      Expanded(child: _buildList()),
                    ],
                  )),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('닫기', style: TextStyle(color: Colors.white70)),
        ),
      ],
    );
  }

  Widget _buildList() {
    return ListView.separated(
      itemCount: _events.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0x22FFFFFF)),
      itemBuilder: (ctx, i) {
        final e = _events[i];
        return ListTile(
          dense: true,
          leading: CircleAvatar(radius: 14, backgroundColor: e.color.withOpacity(0.2), child: Icon(e.icon, color: e.color, size: 16)),
          title: Text(e.title, style: const TextStyle(color: Colors.white)),
          subtitle: Text('${_format(e.timestamp)}${e.subtitle.isNotEmpty ? ' · ' + e.subtitle : ''}', style: const TextStyle(color: Colors.white60)),
        );
      },
    );
  }

  Widget _buildFilterChips() {
    Color bg(bool sel) => sel ? const Color(0xFF2A323C) : const Color(0xFF22262C);
    Color txt(bool sel) => sel ? Colors.white : Colors.white70;
    Color brd(bool sel) => sel ? const Color(0xFF1976D2).withOpacity(0.7) : Colors.white24;
    final List<Widget> chips = [];
    final bool allSel = _filterStudentId == null;
    chips.add(Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.all_inclusive, size: 14, color: Colors.white70),
            const SizedBox(width: 6),
            Text('전체', style: TextStyle(color: txt(allSel))),
          ],
        ),
        selected: allSel,
        backgroundColor: bg(false),
        selectedColor: bg(true),
        shape: StadiumBorder(side: BorderSide(color: brd(allSel), width: 1)),
        labelPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onSelected: (_) => setState(() { _filterStudentId = null; _applyFilter(); }),
      ),
    ));
    for (final s in _attending) {
      final bool sel = _filterStudentId == s.id;
      chips.add(Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person, size: 14, color: Colors.white70),
              const SizedBox(width: 6),
              Text(s.name, style: TextStyle(color: txt(sel))),
            ],
          ),
          selected: sel,
          backgroundColor: bg(false),
          selectedColor: bg(true),
          shape: StadiumBorder(side: BorderSide(color: brd(sel), width: 1)),
          labelPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onSelected: (_) => setState(() { _filterStudentId = s.id; _applyFilter(); }),
        ),
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

enum _EventType { homework, tag }

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


