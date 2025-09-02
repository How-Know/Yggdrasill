import 'package:flutter/material.dart';
import '../../widgets/app_bar_title.dart';
import '../../widgets/custom_tab_bar.dart';
import '../../widgets/student_grouped_list_panel.dart';
import '../../services/data_manager.dart';
import '../../models/student.dart';
import '../../services/tag_store.dart';
import 'tag_preset_screen.dart';

class LearningScreen extends StatefulWidget {
  const LearningScreen({super.key});

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  int _selectedTab = 0; // 0: 기록, 1: 커리큘럼

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1F1F1F),
      appBar: const AppBarTitle(title: '학습'),
      body: Column(
        children: [
          const SizedBox(height: 5),
          CustomTabBar(
            selectedIndex: _selectedTab,
            tabs: const ['기록', '커리큘럼'],
            onTabSelected: (i) {
              setState(() {
                _selectedTab = i;
              });
            },
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _selectedTab == 0
                ? const _LearningRecordsView()
                : const _LearningCurriculumView(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _LearningRecordsView extends StatefulWidget {
  const _LearningRecordsView();

  @override
  State<_LearningRecordsView> createState() => _LearningRecordsViewState();
}

class _LearningRecordsViewState extends State<_LearningRecordsView> {
  StudentWithInfo? _selected;
  DateTime _anchorDate = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  bool _showAttendance = true;
  bool _showTags = true;
  bool _isLoadingMore = false;
  int _daysLoaded = 7; // 초기 1주일 로드
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalW = MediaQuery.of(context).size.width;
    const double leftW = 240; // 고정 폭
    return Row(
      children: [
        SizedBox(
          width: leftW,
          child: StudentGroupedListPanel(
            selected: _selected,
            onStudentSelected: (s) => setState(() => _selected = s),
            width: leftW,
          ),
        ),
        Expanded(
          flex: 1, // 남은 영역의 1/3
          child: Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: _buildRightTimeline(),
          ),
        ),
        Expanded(flex: 2, child: Container()), // 남은 2/3 비움
      ],
    );
  }

  Widget _buildRightTimeline() {
    if (_selected == null) {
      return const Center(
        child: Text('왼쪽에서 학생을 선택하세요', style: TextStyle(color: Colors.white70, fontSize: 18)),
      );
    }

    // 현재 앵커일을 기준으로 최근 n일 범위 수집
    final DateTime start = _anchorDate;
    final List<_TimelineEntry> entries = _collectEntriesForSpan(_selected!, start, _daysLoaded);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Text('${_selected!.student.name}', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
              const Spacer(),
              _buildFilterChip(
                label: '등/하원',
                selected: _showAttendance,
                onSelected: (v) => setState(() => _showAttendance = v),
                accent: const Color(0xFF0F467D),
              ),
              const SizedBox(width: 8),
              _buildFilterChip(
                label: '태그',
                selected: _showTags,
                onSelected: (v) => setState(() => _showTags = v),
                accent: const Color(0xFF166ABD),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: '날짜 선택',
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _anchorDate,
                    firstDate: DateTime.now().subtract(const Duration(days: 365 * 2)),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    locale: const Locale('ko', 'KR'),
                    builder: (context, child) {
                      return Theme(
                        data: Theme.of(context).copyWith(
                          colorScheme: const ColorScheme.dark(primary: Color(0xFF1976D2)),
                          dialogBackgroundColor: const Color(0xFF18181A),
                        ),
                        child: child!,
                      );
                    },
                  );
                  if (picked != null) {
                    setState(() {
                      _anchorDate = DateTime(picked.year, picked.month, picked.day);
                      _daysLoaded = 7;
                    });
                  }
                },
                icon: const Icon(Icons.event, color: Colors.white70, size: 22),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '태그 관리',
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TagPresetScreen()),
                  );
                },
                icon: const Icon(Icons.style, color: Colors.white70, size: 22),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              ),
            ],
          ),
        ),
        const Divider(color: Colors.white24, height: 1),
        // 필터칩은 상단 헤더에 배치됨
        Expanded(
          child: entries.isEmpty
              ? const Center(child: Text('기록이 없습니다.', style: TextStyle(color: Colors.white54)))
              : ListView.separated(
                  controller: _scrollController,
                  reverse: true, // 최신이 아래, 위로 스크롤하면 과거로 이동
                  padding: const EdgeInsets.all(16.0),
                  itemCount: _buildRenderableList(entries).length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final item = _buildRenderableList(entries)[i];
                    if (item is _TimelineHeader) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4.0),
                        child: Row(
                          children: [
                            const Expanded(child: Divider(color: Colors.white12)),
                            const SizedBox(width: 8),
                            Text('${item.date.year}.${item.date.month.toString().padLeft(2,'0')}.${item.date.day.toString().padLeft(2,'0')}', style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w700)),
                            const SizedBox(width: 8),
                            const Expanded(child: Divider(color: Colors.white12)),
                          ],
                        ),
                      );
                    } else if (item is _TimelineEntry) {
                      final e = item;
                      final bool isAttendance = (e.label == '등원' || e.label == '하원');
                      final Color iconColor = isAttendance ? Colors.grey.shade300 : e.color;
                      final BoxDecoration deco = isAttendance
                          ? BoxDecoration(color: Colors.transparent, shape: BoxShape.circle, border: Border.all(color: Colors.grey.shade600, width: 1.2))
                          : BoxDecoration(color: e.color.withOpacity(0.20), shape: BoxShape.circle, border: Border.all(color: e.color.withOpacity(0.85), width: 1.2));
                      return Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: deco,
                            child: Icon(e.icon, color: iconColor, size: 18),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${e.label}  ${_formatTime(e.time)}', style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
                                if (e.note != null && e.note!.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(e.note!, style: const TextStyle(color: Colors.white54, fontSize: 13)),
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
    );
  }

  List<_TimelineEntry> _collectEntriesForRange(StudentWithInfo student, DateTime start, DateTime end) {
    final List<_TimelineEntry> entries = [];
    final Set<String> seen = <String>{};
    // 요일 기반 블록 (주간 시간표)
    final weekdayIndex = start.weekday - 1;
    final blocks = DataManager.instance.studentTimeBlocks
        .where((b) => b.studentId == student.student.id && b.dayIndex == weekdayIndex)
        .toList();

    for (final block in blocks) {
      final classStart = DateTime(start.year, start.month, start.day, block.startHour, block.startMinute);
      final rec = DataManager.instance.getAttendanceRecord(student.student.id, classStart);
      if (_showAttendance && rec?.arrivalTime != null && rec!.arrivalTime!.isAfter(start) && rec.arrivalTime!.isBefore(end)) {
        final key = 'A_${rec.arrivalTime!.millisecondsSinceEpoch}';
        if (seen.add(key)) {
          entries.add(_TimelineEntry(time: rec.arrivalTime!, icon: Icons.login, color: const Color(0xFF4CAF50), label: '등원'));
        }
      }
      if (_showAttendance && rec?.departureTime != null && rec!.departureTime!.isAfter(start) && rec.departureTime!.isBefore(end)) {
        final key = 'D_${rec.departureTime!.millisecondsSinceEpoch}';
        if (seen.add(key)) {
          entries.add(_TimelineEntry(time: rec.departureTime!, icon: Icons.logout, color: const Color(0xFFFF7043), label: '하원'));
        }
      }
      if (_showTags && block.setId != null) {
        final tagEvents = TagStore.instance.getEventsForSet(block.setId!);
        for (final te in tagEvents) {
          if (te.timestamp.isAfter(start) && te.timestamp.isBefore(end)) {
            final key = 'T_${block.setId}_${te.tagName}_${te.timestamp.millisecondsSinceEpoch}_${te.note ?? ''}';
            if (seen.add(key)) {
              entries.add(_TimelineEntry(time: te.timestamp, icon: IconData(te.iconCodePoint, fontFamily: 'MaterialIcons'), color: Color(te.colorValue), label: te.tagName, note: te.note));
            }
          }
        }
      }
    }
    entries.sort((a, b) => b.time.compareTo(a.time)); // 최신 우선
    return entries;
  }

  List<_TimelineEntry> _collectEntriesForSpan(StudentWithInfo student, DateTime anchor, int days) {
    final List<_TimelineEntry> all = [];
    for (int i = 0; i < days; i++) {
      final dayStart = anchor.subtract(Duration(days: i));
      final dayEnd = dayStart.add(const Duration(days: 1));
      all.addAll(_collectEntriesForRange(student, dayStart, dayEnd));
    }
    all.sort((a, b) => b.time.compareTo(a.time)); // 최신 우선
    return all;
  }

  void _onScroll() {
    if (_isLoadingMore) return;
    // reverse:true 이므로 위로 스크롤하여 과거로 갈 때 maxScrollExtent 근접
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 80) {
      setState(() {
        _isLoadingMore = true;
        _daysLoaded += 7; // 1주일 추가 로드
        _isLoadingMore = false;
      });
    }
  }

  Widget _buildFilterChip({required String label, required bool selected, required ValueChanged<bool> onSelected, required Color accent}) {
    final Color bg = const Color(0xFF2A2A2A);
    final Color selBg = const Color(0xFF212A31);
    final Color side = Colors.white24; // 요청: 테두리는 회색 고정
    return FilterChip(
      label: Text(label, style: const TextStyle(color: Colors.white70)),
      selected: selected,
      onSelected: onSelected,
      selectedColor: selBg,
      backgroundColor: bg,
      showCheckmark: false,
      shape: StadiumBorder(side: BorderSide(color: side, width: 1.2)),
    );
  }

  List<dynamic> _buildRenderableList(List<_TimelineEntry> entries) {
    final List<dynamic> items = [];
    DateTime? currentDate;
    for (final e in entries) {
      final d = DateTime(e.time.year, e.time.month, e.time.day);
      if (currentDate == null || d.millisecondsSinceEpoch != currentDate.millisecondsSinceEpoch) {
        currentDate = d;
        items.add(_TimelineHeader(date: d));
      }
      items.add(e);
    }
    return items;
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _TimelineEntry {
  final DateTime time;
  final IconData icon;
  final Color color;
  final String label;
  final String? note;
  _TimelineEntry({required this.time, required this.icon, required this.color, required this.label, this.note});
}

class _TimelineHeader {
  final DateTime date;
  _TimelineHeader({required this.date});
}

class _LearningCurriculumView extends StatelessWidget {
  const _LearningCurriculumView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '커리큘럼 화면 (준비 중)',
        style: const TextStyle(color: Colors.white70, fontSize: 18),
      ),
    );
  }
}


