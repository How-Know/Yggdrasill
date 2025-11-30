import 'package:flutter/material.dart';
import 'dart:async';
import '../../widgets/app_bar_title.dart';
import '../../widgets/custom_tab_bar.dart';
import '../../widgets/student_grouped_list_panel.dart';
import '../../services/data_manager.dart';
import '../../models/student.dart';
import '../../services/tag_store.dart';
import 'tag_preset_dialog.dart';
import '../../services/homework_store.dart';
import 'problem_bank_view.dart';
import 'package:mneme_flutter/utils/ime_aware_text_editing_controller.dart';

class LearningScreen extends StatefulWidget {
  const LearningScreen({super.key});

  @override
  State<LearningScreen> createState() => _LearningScreenState();
}

class _LearningScreenState extends State<LearningScreen> {
  int _selectedTab = 0; // 0: 기록, 1: 커리큘럼, 2: 문제은행

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
            tabs: const ['기록', '커리큘럼', '문제은행'],
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
                : (_selectedTab == 1
                    ? const _LearningCurriculumView()
                    : const ProblemBankView()),
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
  int _daysLoaded = 31; // 초기 1개월 로드
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
        // 타임라인 1/3
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: _buildRightTimeline(),
          ),
        ),
        // 수업기록(과제) 1/3
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: _buildHomeworkPanel(),
          ),
        ),
        // 전체요약(자리만 구성) 1/3
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: _buildSummaryPlaceholder(),
          ),
        ),
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
                      _daysLoaded = 31; // 선택 변경 시에도 1개월 로드
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
                onPressed: () async {
                  await showDialog(context: context, builder: (_) => const TagPresetDialog());
                  if (mounted) setState(() {});
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
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        e.note != null && e.note!.isNotEmpty
                                            ? '${e.label}  ${_formatTime(e.time)}  ·  ${e.note}'
                                            : '${e.label}  ${_formatTime(e.time)}',
                                        style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
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
        _daysLoaded += 31; // 1개월 추가 로드
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
  String _formatDateTime(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$y.$m.$d $hh:$mm';
  }

  // ---- 수업기록(과제) ----
  _HomeworkItem? _runningItem; // 로컬 타이머 렌더링용 표시(스토어 병행)
  Timer? _runningTimer;

  Widget _buildHomeworkPanel() {
    if (_selected == null) {
      return const Center(child: Text('학생을 선택하면 과제를 등록할 수 있습니다.', style: TextStyle(color: Colors.white54)));
    }
    final sid = _selected!.student.id;
    // 슬라이드 시트와 연동: 전역 스토어에서 항목을 가져와 표시
    final store = HomeworkStore.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text('수업기록', style: TextStyle(color: Colors.white70, fontSize: 19, fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  final created = await showDialog<_HomeworkItem>(
                    context: context,
                    builder: (_) => const _HomeworkCreateDialog(),
                  );
                  if (created != null) {
                    store.add(sid, title: created.title, body: created.body, color: created.color);
                    setState(() {});
                  }
                },
                icon: const Icon(Icons.add, size: 16, color: Colors.white70),
                label: const Text('과제 추가', style: TextStyle(color: Colors.white70)),
                style: TextButton.styleFrom(foregroundColor: Colors.white70, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
              )
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: HomeworkStore.instance.revision,
            builder: (context, _rev, _) {
              final list = store.items(sid);
              return ListView.separated(
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final hw = list[i];
                  final isRunning = hw.runStart != null;
                  final isCompleted = hw.status == HomeworkStatus.completed;
                  final bool isHomework = !isCompleted && hw.firstStartedAt != null && (DateTime.now().difference(hw.firstStartedAt!).inDays >= 1);
                  final now = DateTime.now();
                  final totalMs = hw.accumulatedMs + (hw.runStart != null ? now.difference(hw.runStart!).inMilliseconds : 0);
                  final infoOpacity = isCompleted ? 0.55 : 1.0;
                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFF262626), borderRadius: BorderRadius.circular(10)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Opacity(
                          opacity: infoOpacity,
                          child: Row(
                            children: [
                              Container(width: 12, height: 12, decoration: BoxDecoration(color: hw.color, shape: BoxShape.circle)),
                              const SizedBox(width: 8),
                              Expanded(child: Row(children: [
                                Flexible(child: Text(hw.title, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis)),
                                if (isHomework) ...[
                                  const SizedBox(width: 8),
                                  Container(height: 20, padding: const EdgeInsets.symmetric(horizontal: 8), decoration: BoxDecoration(color: const Color(0xFF1976D2).withOpacity(0.20), borderRadius: BorderRadius.circular(6)), alignment: Alignment.center, child: const Text('숙제', style: TextStyle(color: Color(0xFF64B5F6), fontSize: 11, fontWeight: FontWeight.w700)) ),
                                ],
                                if (isCompleted) ...[
                                  const SizedBox(width: 8),
                                  Container(height: 20, padding: const EdgeInsets.symmetric(horizontal: 8), decoration: BoxDecoration(color: const Color(0xFF2E7D32).withOpacity(0.25), borderRadius: BorderRadius.circular(6)), alignment: Alignment.center, child: const Text('완료됨', style: TextStyle(color: Color(0xFFA5D6A7), fontSize: 11, fontWeight: FontWeight.w700))),
                                ],
                              ])),
                              Text(_formatDurationMs(totalMs), style: const TextStyle(color: Colors.white60, fontSize: 12)),
                              const SizedBox(width: 6),
                              PopupMenuButton<String>(
                                itemBuilder: (_) => [
                                  const PopupMenuItem(value: 'edit', child: Text('편집', style: TextStyle(color: Colors.white))),
                                  const PopupMenuItem(value: 'delete', child: Text('삭제', style: TextStyle(color: Colors.white))),
                                ],
                                onSelected: (v) async {
                                  if (v == 'delete') {
                                    setState(() {
                                      store.pause(sid, hw.id);
                                      store.remove(sid, hw.id);
                                    });
                                  } else if (v == 'edit') {
                                    final edited = await showDialog<_HomeworkItem>(context: context, builder: (_) => _HomeworkCreateDialog(initial: _HomeworkItem(title: hw.title, body: hw.body, color: hw.color)));
                                    if (edited != null) {
                                      store.edit(sid, HomeworkItem(id: hw.id, title: edited.title, body: edited.body, color: edited.color, status: HomeworkStatus.inProgress, accumulatedMs: hw.accumulatedMs, runStart: hw.runStart, completedAt: hw.completedAt));
                                      setState(() {});
                                    }
                                  }
                                },
                                icon: const Icon(Icons.more_horiz, color: Colors.white54, size: 18),
                                color: const Color(0xFF2A2A2A),
                                position: PopupMenuPosition.under,
                                offset: const Offset(8, -6),
                                surfaceTintColor: Colors.transparent,
                              ),
                            ],
                          ),
                        ),
                        if (hw.body.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Opacity(opacity: infoOpacity, child: Text(hw.body, style: const TextStyle(color: Colors.white70, fontSize: 15))),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            // 진행/일시정지 (아이콘) - 배경/윤곽선 없음
                            IconButton(
                              onPressed: isCompleted
                                  ? null
                                  : () {
                                      if (hw.runStart != null) {
                                        store.pause(sid, hw.id);
                                      } else {
                                        store.start(sid, hw.id);
                                      }
                                      _ensureTickTimer();
                                      setState(() {});
                                    },
                              icon: Icon(isRunning ? Icons.pause_rounded : Icons.play_arrow_rounded, color: isCompleted ? Colors.white30 : Colors.white70, size: 20),
                              tooltip: isRunning ? '일시정지' : '진행',
                            ),
                            const SizedBox(width: 4),
                            // 완료 (아이콘)
                            IconButton(
                              onPressed: isCompleted
                                  ? null
                                  : () {
                                      store.complete(sid, hw.id);
                                      setState(() {});
                                    },
                              icon: const Icon(Icons.check_rounded, color: Colors.white70, size: 20),
                              tooltip: '완료',
                            ),
                            const SizedBox(width: 4),
                            // 이어가기 + (아이콘) - 항상 활성화
                            IconButton(
                              onPressed: () async {
                                final continued = await showDialog<_HomeworkItem>(
                                  context: context,
                                  builder: (_) => _HomeworkCreateDialog(initial: _HomeworkItem(title: hw.title, body: '', color: hw.color), bodyOnly: true),
                                );
                                if (continued != null) {
                                  store.continueAdd(sid, hw.id, body: continued.body);
                                  setState(() {});
                                }
                              },
                              icon: const Icon(Icons.add_rounded, color: Colors.white70, size: 20),
                              tooltip: '이어가기',
                            ),
                            const Spacer(),
                            if (hw.firstStartedAt != null)
                              Text('시작: ' + _formatDateTime(hw.firstStartedAt!), style: const TextStyle(color: Colors.white38, fontSize: 13)),
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
    );
  }

  void _ensureTickTimer() {
    _runningTimer?.cancel();
    _runningTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final sid = _selected?.student.id;
      if (sid == null) return;
      final running = HomeworkStore.instance.runningOf(sid);
      if (running == null) {
        _runningTimer?.cancel();
        _runningTimer = null;
      }
      setState(() {}); // 실시간 카운트 반영
    });
  }

  String _formatDurationMs(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  Widget _buildSummaryPlaceholder() {
    return Container(
      decoration: BoxDecoration(color: const Color(0xFF242424), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white24)),
      child: const Center(
        child: Text('전체 요약 (준비 중)', style: TextStyle(color: Colors.white54)),
      ),
    );
  }

  // 과제 아이템 모델(메모리 저장; 추후 DB 연동 가능)
  // 완료 항목은 completedAt에 타임스탬프를 남겨 타임라인과 합칠 수 있음
}

enum _HomeworkStatus { inProgress, completed, homework }

class _HomeworkItem {
  final String title;
  final String body;
  _HomeworkStatus status;
  DateTime? completedAt;
  Color color;
  int accumulatedMs; // 누적 시간(ms)
  final List<_Session> sessions;
  DateTime? _runStart;
  _HomeworkItem({required this.title, required this.body, this.status = _HomeworkStatus.inProgress, this.completedAt, this.color = const Color(0xFF1976D2), this.accumulatedMs = 0, List<_Session>? sessions}) : sessions = sessions ?? <_Session>[];
  void _start() {
    if (_runStart != null) return;
    _runStart = DateTime.now();
    sessions.add(_Session(start: _runStart!));
  }
  void _stop() {
    if (_runStart == null) return;
    final now = DateTime.now();
    final last = sessions.isNotEmpty ? sessions.last : null;
    if (last != null && last.end == null) {
      last.end = now;
      accumulatedMs += now.difference(_runStart!).inMilliseconds;
    }
    _runStart = null;
  }
  int _currentSessionMs() {
    if (_runStart == null) return 0;
    return DateTime.now().difference(_runStart!).inMilliseconds;
  }
  _HomeworkItem copyWith({String? title, String? body, _HomeworkStatus? status, Color? color, int? accumulatedMs, List<_Session>? sessions}) {
    return _HomeworkItem(
      title: title ?? this.title,
      body: body ?? this.body,
      status: status ?? this.status,
      color: color ?? this.color,
      accumulatedMs: accumulatedMs ?? this.accumulatedMs,
      sessions: sessions ?? List<_Session>.from(this.sessions),
      completedAt: completedAt,
    );
  }
}

class _Session { _Session({required this.start, this.end}); DateTime start; DateTime? end; }

class _HomeworkCreateDialog extends StatefulWidget {
  final _HomeworkItem? initial;
  final bool bodyOnly; // true면 제목/색상은 고정, 내용만 변경
  const _HomeworkCreateDialog({this.initial, this.bodyOnly = false});
  @override
  State<_HomeworkCreateDialog> createState() => _HomeworkCreateDialogState();
}

class _HomeworkCreateDialogState extends State<_HomeworkCreateDialog> {
  late final TextEditingController _name;
  late final TextEditingController _desc;
  Color _color = const Color(0xFF1976D2);
  @override
  void initState() {
    super.initState();
    _name = ImeAwareTextEditingController(text: widget.initial?.title ?? '');
    _desc = ImeAwareTextEditingController(text: widget.initial?.body ?? '');
    _color = widget.initial?.color ?? const Color(0xFF1976D2);
    if (widget.bodyOnly) {
      // 제목/색상은 고정, 내용은 비움
      _desc.text = '';
    }
  }
  @override
  void dispose() { _name.dispose(); _desc.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final readOnly = widget.bodyOnly;
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: Text(widget.initial == null ? '과제 추가' : (widget.bodyOnly ? '과제 이어가기' : '과제 편집'), style: const TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!readOnly)
              TextField(
                controller: _name,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: '과제 이름', labelStyle: TextStyle(color: Colors.white60), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
              )
            else
              Row(
                children: [
                  Container(width: 12, height: 12, decoration: BoxDecoration(color: _color, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_name.text, style: const TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600))),
                ],
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _desc,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(labelText: '내용', labelStyle: TextStyle(color: Colors.white60), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2)))),
            ),
            const SizedBox(height: 12),
            if (!readOnly) ...[
              const Text('색상', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in [Colors.blue, Colors.green, Colors.orange, Colors.purple, Colors.pink, Colors.cyan, Colors.teal, Colors.red, const Color(0xFF90A4AE)])
                    GestureDetector(
                      onTap: () => setState(() => _color = c),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(color: c == _color ? Colors.white : Colors.white24, width: c == _color ? 2 : 1),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('취소', style: TextStyle(color: Colors.white70))),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            final desc = _desc.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(context, _HomeworkItem(title: name, body: desc, color: _color));
          },
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          child: const Text('추가'),
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




