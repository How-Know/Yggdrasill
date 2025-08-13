import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:uuid/uuid.dart';
import '../../../services/schedule_store.dart';
import '../../../services/summary_service.dart';
import '../../../services/holiday_service.dart';
import '../../../services/data_manager.dart';
import '../../../models/memo.dart';
import '../../../services/ai_summary.dart';
import '../../../main.dart'; // rootNavigatorKey

class ScheduleView extends StatefulWidget {
  final DateTime selectedDate;
  final ValueChanged<DateTime>? onDateSelected;
  const ScheduleView({super.key, required this.selectedDate, this.onDateSelected});

  @override
  State<ScheduleView> createState() => _ScheduleViewState();
}

class _ScheduleViewState extends State<ScheduleView> {
  bool _isAddMode = false;
  String? _pendingIconKey;
  int? _pendingColor;
  List<String> _pendingTags = [];
  DateTime? _rangeStart;
  DateTime? _previewStart;
  DateTime? _previewEnd;
  String _todoFilter = 'all'; // all | incomplete | complete
  final Set<int> _loadedHolidayYears = <int>{};

  @override
  void initState() {
    super.initState();
    _ensureHolidaysForYear(DateTime.now().year);
  }

  Future<void> _ensureHolidaysForYear(int year) async {
    if (_loadedHolidayYears.contains(year)) return;
    try {
      final holidays = await HolidayService.fetchKoreanPublicHolidays(year);
      for (final h in holidays) {
        final date = DateTime(h.year, h.month, h.day);
        final exists = ScheduleStore.instance
            .eventsOn(date)
            .any((e) => (e.tags.contains('KR_HOLIDAY') && (e.note ?? '').contains(h.name)));
        if (exists) continue;
        final id = const Uuid().v4();
        final event = ScheduleEvent(
          id: id,
          groupId: 'kr_holidays_$year',
          date: date,
          title: '휴일',
          note: h.name,
          color: 0xFF546E7A,
          tags: const ['KR_HOLIDAY'],
          iconKey: 'holiday',
        );
        await ScheduleStore.instance.addEvent(event);
      }
      _loadedHolidayYears.add(year);
    } catch (_) {
      // 네트워크 실패 시 조용히 무시
    }
  }

  void _handleDatePick(DateTime date) async {
    if (!_isAddMode) {
      widget.onDateSelected?.call(date);
      return;
    }
    if (_rangeStart == null) {
      setState(() {
        _rangeStart = date;
        _previewStart = date;
        _previewEnd = date;
      });
      return;
    }
    // finalize range
    final start = _rangeStart!.isBefore(date) ? _rangeStart! : date;
    final end = _rangeStart!.isBefore(date) ? date : _rangeStart!;
    DateTime cur = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    // 메모 입력 다이얼로그
    final note = await _showNoteDialog(context);
    final title = await SummaryService.summarize(iconKey: _pendingIconKey, tags: _pendingTags, note: note);
    final groupId = ScheduleStore.instance.newGroupId();
    while (!cur.isAfter(last)) {
      final id = const Uuid().v4();
      final event = ScheduleEvent(
        id: id,
        groupId: groupId,
        date: cur,
        title: title,
        note: note,
        color: _pendingColor,
        tags: List<String>.from(_pendingTags),
        iconKey: _pendingIconKey,
      );
      await ScheduleStore.instance.addEvent(event);
      cur = cur.add(const Duration(days: 1));
    }
    setState(() {
      _isAddMode = false;
      _rangeStart = null;
      _pendingIconKey = null;
      _pendingColor = null;
      _pendingTags = [];
      _previewStart = null;
      _previewEnd = null;
    });
  }

  void _updatePreview(DateTime date) {
    if (!_isAddMode || _rangeStart == null) return;
    setState(() {
      _previewStart = _rangeStart;
      _previewEnd = date;
    });
  }

  // title generation moved to SummaryService

  Future<void> _startAddFlow() async {
    final meta = await _showMetaDialog(context);
    if (meta == null) return;
    setState(() {
      _isAddMode = true;
      _pendingIconKey = meta.iconKey;
      _pendingColor = meta.color;
      _pendingTags = meta.tags;
      _rangeStart = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
      children: [
        // Left 3 (split vertically 3:1)
        Expanded(
          flex: 3,
          child: Column(
            children: [
              Expanded(
                flex: 11,
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  child: _MonthlyCalendar(
                    month: DateTime(widget.selectedDate.year, widget.selectedDate.month, 1),
                    selectedDate: widget.selectedDate,
                    onSelect: _handleDatePick,
                    addMode: _isAddMode,
                    previewStart: _previewStart,
                    previewEnd: _previewEnd,
                    onHoverDate: _updatePreview,
                  ),
                ),
              ),
              if (_isAddMode)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, color: Colors.white60, size: 16),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text('셀을 클릭하여 날짜를 선택하세요. 범위를 선택하려면 시작 날짜 클릭 후 종료 날짜를 클릭하세요.', style: TextStyle(color: Colors.white60, fontSize: 12)),
                      ),
                      TextButton(
                        onPressed: () => setState(() { _isAddMode = false; _rangeStart = null; }),
                        child: const Text('취소', style: TextStyle(color: Colors.white70)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Expanded(
                flex: 2,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const _ScheduleTimeline(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 32),
        // Right 1 (split vertically 1:1)
        Expanded(
          flex: 1,
          child: Column(
            children: [
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181A),
                    borderRadius: BorderRadius.circular(16),
                  ),
              child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
              Text(
                _formatDateYMD(widget.selectedDate),
                style: const TextStyle(color: Colors.white70, fontSize: 19, fontWeight: FontWeight.w500),
              ),
                          const Spacer(),
                       SizedBox(
                            height: 40,
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(22),
                                onTap: () async {
                                  await _startAddFlow();
                                },
                                child: Ink(
                                  decoration: ShapeDecoration(
                                    color: const Color(0xFF1976D2),
                                    shape: StadiumBorder(side: BorderSide(color: Colors.transparent, width: 0)),
                                  ),
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.add, color: Colors.white, size: 20),
                                      SizedBox(width: 8),
                                      Text('일정 추가', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                       Expanded(
                        child: ValueListenableBuilder<List<ScheduleEvent>>(
                          valueListenable: ScheduleStore.instance.events,
                           builder: (context, events, _) {
                            final items = ScheduleStore.instance.eventsOn(widget.selectedDate);
                            if (items.isEmpty) {
                              return const Center(
                                child: Text('해당 날짜의 일정이 없습니다.', style: TextStyle(color: Colors.white38)),
                              );
                            }
                              return ListView.separated(
                              itemCount: items.length,
                                separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 12),
                              itemBuilder: (context, i) {
                                final e = items[i];
                                  return _EventTile(event: e);
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(bottom: 0),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Todo 리스트', style: TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _TodoFilterButton(
                            label: '전체',
                            selected: _todoFilter == 'all',
                            onTap: () { if (_todoFilter != 'all') setState(() => _todoFilter = 'all'); },
                          ),
                          const SizedBox(width: 8),
                          _TodoFilterButton(
                            label: '미완료',
                            selected: _todoFilter == 'incomplete',
                            onTap: () { if (_todoFilter != 'incomplete') setState(() => _todoFilter = 'incomplete'); },
                          ),
                          const SizedBox(width: 8),
                          _TodoFilterButton(
                            label: '완료',
                            selected: _todoFilter == 'complete',
                            onTap: () { if (_todoFilter != 'complete') setState(() => _todoFilter = 'complete'); },
                          ),
                          const Spacer(),
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              backgroundColor: Colors.white12,
                              foregroundColor: Colors.white70,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              shape: const StadiumBorder(),
                            ),
                            onPressed: () => _openMemoAddDialog(context),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('추가', style: TextStyle(fontSize: 13)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ValueListenableBuilder(
                          valueListenable: DataManager.instance.memosNotifier,
                            builder: (context, memos, _) {
                              var list = _expandMemosNextMonths(memos as List<Memo>, months: 3).toList();
                              if (_todoFilter == 'incomplete') {
                                list = list.where((m) => !m.dismissed).toList();
                              } else if (_todoFilter == 'complete') {
                                list = list.where((m) => m.dismissed).toList();
                              }
                            if (list.isEmpty) {
                              return const Center(child: Text('할 일이 없습니다.', style: TextStyle(color: Colors.white38)));
                            }
                            return ListView.separated(
                              itemCount: list.length,
                              separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 12),
                              itemBuilder: (context, index) {
                                final m = list[index];
                                final title = m.summary.isNotEmpty ? m.summary : (m.original.length > 20 ? m.original.substring(0, 20) + '…' : m.original);
                                return Row(
                                  children: [
                                      StatefulBuilder(builder: (context, setRowState) {
                                        bool checked = m.dismissed;
                                        return Checkbox(
                                          value: checked,
                                          onChanged: (v) async {
                                            final newVal = v ?? false;
                                            final updated = m.copyWith(dismissed: newVal, updatedAt: DateTime.now());
                                            await DataManager.instance.updateMemo(updated);
                                            setRowState(() {});
                                          },
                                          checkColor: Colors.white,
                                          activeColor: const Color(0xFF1976D2),
                                        );
                                      }),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(title, style: const TextStyle(color: Colors.white70, fontSize: 15)),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.edit, color: Colors.white54, size: 18),
                                      onPressed: () async {
                                        await _openMemoAddDialog(context, initial: m.original);
                                      },
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
      ),
    );
  }
}

List<Memo> _expandMemosNextMonths(List<Memo> memos, {int months = 3}) {
  final now = DateTime.now();
  final startDate = DateTime(now.year, now.month, now.day);
  final endDate = DateTime(startDate.year, startDate.month + months, startDate.day);

  List<Memo> expanded = [];

  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  for (final m in memos) {
    final recur = m.recurrenceType;
    // 단일 메모: 기간 내에 스케줄이 없거나 기간 내 스케줄이면 그대로 반영
    if (recur == null || recur.isEmpty || recur == 'none') {
      if (m.scheduledAt == null) {
        expanded.add(m);
      } else {
        final d = _dateOnly(m.scheduledAt!);
        if (!d.isBefore(startDate) && !d.isAfter(endDate)) {
          expanded.add(m);
        }
      }
      continue;
    }

    // 반복 메모 전개(원형만 DB에 있고 전개는 UI)
    final limitEnd = m.recurrenceEnd != null && _dateOnly(m.recurrenceEnd!).isBefore(endDate)
        ? _dateOnly(m.recurrenceEnd!)
        : endDate;
    final maxCount = m.recurrenceCount; // null이면 무한
    int emitted = 0;
    final anchor = _dateOnly(m.scheduledAt ?? startDate);

    void emit(DateTime day) {
      if (day.isBefore(startDate) || day.isAfter(limitEnd)) return;
      if (maxCount != null && emitted >= maxCount) return;
      expanded.add(m.copyWith(
        id: '${m.id}#${day.toIso8601String()}',
        scheduledAt: day,
      ));
      emitted += 1;
    }

    if (recur == 'daily') {
      DateTime cur = _dateOnly(anchor.isAfter(startDate) ? anchor : startDate);
      while (!cur.isAfter(limitEnd)) {
        emit(cur);
        if (maxCount != null && emitted >= maxCount) break;
        cur = cur.add(const Duration(days: 1));
      }
    } else if (recur == 'weekly') {
      // 기준 요일은 anchor 요일
      final targetWeekday = anchor.weekday; // 1=Mon..7=Sun
      // 첫 발생일 계산
      int delta = (targetWeekday - startDate.weekday);
      if (delta < 0) delta += 7;
      DateTime cur = _dateOnly(startDate.add(Duration(days: delta)));
      // anchor가 더 미래이면 anchor 이후로 맞춤
      if (cur.isBefore(anchor)) {
        final diffDays = anchor.difference(cur).inDays;
        final addWeeks = (diffDays / 7).ceil();
        cur = cur.add(Duration(days: addWeeks * 7));
      }
      while (!cur.isAfter(limitEnd)) {
        emit(cur);
        if (maxCount != null && emitted >= maxCount) break;
        cur = cur.add(const Duration(days: 7));
      }
    } else if (recur == 'monthly') {
      // 같은 일자 기준, 말일 넘어가면 해당 월의 말일로 클램프
      int day = anchor.day;
      DateTime cur = DateTime(startDate.year, startDate.month, 1);
      // 첫 달은 startDate의 월부터
      while (!cur.isAfter(limitEnd)) {
        final lastDay = DateTime(cur.year, cur.month + 1, 0).day;
        final dd = day > lastDay ? lastDay : day;
        final candidate = DateTime(cur.year, cur.month, dd);
        if (!candidate.isBefore(startDate) && !candidate.isAfter(limitEnd)) emit(candidate);
        if (maxCount != null && emitted >= maxCount) break;
        cur = DateTime(cur.year, cur.month + 1, 1);
      }
    } else if (recur == 'selected_weekdays') {
      final days = (m.weekdays ?? []).toSet(); // 1..7
      if (days.isEmpty) continue;
      DateTime cur = _dateOnly(startDate);
      while (!cur.isAfter(limitEnd)) {
        if (days.contains(cur.weekday)) emit(cur);
        if (maxCount != null && emitted >= maxCount) break;
        cur = cur.add(const Duration(days: 1));
      }
    }
  }

  // 정렬(가까운 순)
  expanded.sort((a, b) {
    final ad = a.scheduledAt ?? DateTime(0);
    final bd = b.scheduledAt ?? DateTime(0);
    return ad.compareTo(bd);
  });
  return expanded;
}

Future<void> _openMemoAddDialog(BuildContext context, {String? initial}) async {
  final textCtrl = TextEditingController(text: initial ?? '');
  String recurrenceType = 'none'; // none/daily/weekly/monthly/selected_weekdays
  final Set<int> selectedWeekdays = {};
  DateTime? endDate;
  final countCtrl = TextEditingController();

  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (context) {
      return StatefulBuilder(builder: (context, setState) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('메모 추가', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: textCtrl,
                    style: const TextStyle(color: Colors.white),
                    minLines: 3,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      hintText: '할 일을 입력하세요',
                      hintStyle: TextStyle(color: Colors.white38),
                      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('반복', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      border: Border.all(color: Colors.white24),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: DropdownButton<String>(
                      value: recurrenceType,
                      isExpanded: true,
                      underline: const SizedBox(),
                      dropdownColor: const Color(0xFF2A2A2A),
                      style: const TextStyle(color: Colors.white),
                      items: const [
                        DropdownMenuItem(value: 'none', child: Text('없음')),
                        DropdownMenuItem(value: 'daily', child: Text('매일')),
                        DropdownMenuItem(value: 'weekly', child: Text('매주')),
                        DropdownMenuItem(value: 'monthly', child: Text('매월')),
                        DropdownMenuItem(value: 'selected_weekdays', child: Text('선택 요일')),
                      ],
                      onChanged: (v) => setState(() => recurrenceType = v ?? 'none'),
                    ),
                  ),
                  if (recurrenceType == 'selected_weekdays') ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: List.generate(7, (i) => i + 1).map((d) {
                        const names = ['월','화','수','목','금','토','일'];
                        final sel = selectedWeekdays.contains(d);
                        return ChoiceChip(
                          label: Text(names[d-1]),
                          selected: sel,
                          labelStyle: TextStyle(color: sel ? Colors.white : Colors.white70, fontSize: 13),
                          selectedColor: const Color(0xFF1976D2),
                          backgroundColor: const Color(0xFF2A2A2A),
                          side: BorderSide(color: sel ? Colors.transparent : Colors.white24),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          onSelected: (v) => setState(() { if (v) selectedWeekdays.add(d); else selectedWeekdays.remove(d); }),
                        );
                      }).toList(),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text('종료', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(const Duration(days: 365 * 3)),
                            initialDate: endDate ?? DateTime.now().add(const Duration(days: 30)),
                          );
                          if (picked != null) setState(() => endDate = picked);
                        },
                        icon: const Icon(Icons.event, color: Colors.white70, size: 18),
                        label: Text(endDate == null ? '종료일(선택)' : '${endDate!.year}.${endDate!.month}.${endDate!.day}', style: const TextStyle(color: Colors.white70)),
                        style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white24)),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 110,
                        child: TextField(
                          controller: countCtrl,
                          style: const TextStyle(color: Colors.white),
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: '횟수(선택)',
                            labelStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: const Color(0xFF2A2A2A),
                            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24), borderRadius: BorderRadius.circular(8)),
                            focusedBorder: OutlineInputBorder(borderSide: const BorderSide(color: Color(0xFF1976D2)), borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: Colors.white70))),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'text': textCtrl.text.trim(),
                'recurrenceType': recurrenceType,
                'weekdays': selectedWeekdays.toList(),
                'endDate': endDate,
                'count': int.tryParse(countCtrl.text.trim()),
              }),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              child: const Text('추가'),
            ),
          ],
        );
      });
    },
  );

  if (result == null) return;
  final text = result['text'] as String? ?? '';
  if (text.isEmpty) return;
  final summary = await AiSummaryService.summarize(text, maxChars: 40);
  final scheduled = await AiSummaryService.extractDateTime(text);
  final memo = Memo(
    id: const Uuid().v4(),
    original: text,
    summary: summary,
    scheduledAt: scheduled,
    dismissed: false,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    recurrenceType: (result['recurrenceType'] as String?) == 'none' ? null : result['recurrenceType'] as String?,
    weekdays: (result['weekdays'] as List<dynamic>?)?.map((e) => e as int).toList(),
    recurrenceEnd: result['endDate'] as DateTime?,
    recurrenceCount: result['count'] as int?,
  );
  await DataManager.instance.addMemo(memo);
}

Future<String?> _showNoteDialog(BuildContext context) async {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('메모 입력', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: controller,
            style: const TextStyle(color: Colors.white),
            minLines: 3,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: '메모를 입력하세요 (선택)',
              hintStyle: TextStyle(color: Colors.white38),
              enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('건너뛰기', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('확인'),
          ),
        ],
      );
    },
  );
}

class _MetaResult {
  final String? iconKey;
  final int? color;
  final List<String> tags;
  _MetaResult({this.iconKey, this.color, required this.tags});
}

Future<_MetaResult?> _showMetaDialog(BuildContext context) async {
  String? iconKey;
  int? color;
  final tagCtrl = TextEditingController();
  List<String> tags = [];
  return showDialog<_MetaResult>(
    context: context,
    builder: (context) {
      return StatefulBuilder(builder: (context, setState) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('아이콘/색상/태그 선택', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('아이콘', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                LayoutBuilder(builder: (context, constraints) {
                  final items = const [
                    ['holiday', Icons.no_cell, '휴강'],
                    ['exam', Icons.fact_check, '시험'],
                    ['vacation_start', Icons.beach_access, '방학식'],
                    ['school_open', Icons.school, '개학식'],
                    ['special_lecture', Icons.campaign, '특강'],
                    ['counseling', Icons.forum, '상담'],
                    ['notice', Icons.announcement, '공지'],
                    ['payment', Icons.payments, '납부'],
                  ];
                  final cellWidth = (constraints.maxWidth - 3 * 12) / 4; // 4 columns, 12 spacing
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: items.map((it) {
                      final key = it[0] as String;
                      final icon = it[1] as IconData;
                      final label = it[2] as String;
                      final selected = iconKey == key;
                      return GestureDetector(
                        onTap: () => setState(() => iconKey = key),
                        child: Container(
                          width: cellWidth,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: selected ? Colors.white10 : Colors.transparent,
                            border: Border.all(color: selected ? Colors.white : Colors.white24),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, color: Colors.white70, size: 24),
                              const SizedBox(height: 6),
                              Text(label, style: const TextStyle(color: Colors.white60, fontSize: 12)),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  );
                }),
                const SizedBox(height: 12),
                const Text('색상', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    0xFF1976D2, 0xFFE53935, 0xFF43A047, 0xFFFB8C00, 0xFF8E24AA, 0xFF00897B,
                    0xFF546E7A, 0xFFFF7043, 0xFF26C6DA, 0xFF7E57C2, 0xFF66BB6A, 0xFFEC407A,
                  ]
                      .map((c) => GestureDetector(
                            onTap: () => setState(() => color = c),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: Color(c),
                                shape: BoxShape.circle,
                                border: Border.all(color: (color == c) ? Colors.white : Colors.transparent, width: 2),
                              ),
                            ),
                          ))
                      .toList(),
                ),
                const SizedBox(height: 12),
                const Text('태그', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: tagCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: '태그 입력 후 추가',
                          hintStyle: TextStyle(color: Colors.white38),
                          enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                          focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                        ),
                        onSubmitted: (_) {
                          final t = tagCtrl.text.trim();
                          if (t.isNotEmpty) {
                            setState(() {
                              tags.add(t);
                              tagCtrl.clear();
                            });
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                      onPressed: () {
                        final t = tagCtrl.text.trim();
                        if (t.isNotEmpty) {
                          setState(() {
                            tags.add(t);
                            tagCtrl.clear();
                          });
                        }
                      },
                      child: const Text('추가'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: tags
                      .map((t) => Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2A2A2A),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: Colors.white24),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('#$t', style: const TextStyle(color: Colors.white, fontSize: 12)),
                                const SizedBox(width: 6),
                                GestureDetector(
                                  onTap: () => setState(() => tags.remove(t)),
                                  child: const Icon(Icons.close, size: 14, color: Colors.white60),
                                ),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              onPressed: () => Navigator.pop(context, _MetaResult(iconKey: iconKey, color: color, tags: tags)),
              child: const Text('다음'),
            ),
          ],
        );
      });
    },
  );
}

class _IconOption extends StatelessWidget {
  final IconData icon;
  final String label;
  const _IconOption({required this.icon, required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.white70, size: 18),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }
}


class _EventTile extends StatelessWidget {
  final ScheduleEvent event;
  final bool showGroupActions;
  const _EventTile({required this.event, this.showGroupActions = false});

  @override
  Widget build(BuildContext context) {
    final color = event.color != null ? Color(event.color!) : const Color(0xFF1976D2);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Icon(_iconFromKey(event.iconKey), color: Colors.white70, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                if (event.note != null && event.note!.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      _oneSentence(event.note!.trim()),
                      style: const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                  ),
                if (event.note != null && event.note!.trim().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    event.note!.trim(),
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
                if (event.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: event.tags
                          .map((t) => Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white10,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text('#$t', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              ))
                          .toList(),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.edit, color: Colors.white60, size: 18),
            onPressed: () async {
              final updated = await _showEditDialog(context, event);
              if (updated != null) {
                await ScheduleStore.instance.updateEvent(updated);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white60, size: 18),
            onPressed: () async => ScheduleStore.instance.deleteEvent(event.id),
          ),
          if (showGroupActions && event.groupId != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.white60, size: 18),
              color: const Color(0xFF2A2A2A),
              onSelected: (value) async {
                if (value == 'edit_group') {
                  final res = await _showEditGroupDialog(context, event);
                  if (res != null && event.groupId != null) {
                    final groupId = event.groupId!;
                    final events = List<ScheduleEvent>.from(ScheduleStore.instance.events.value)
                        .where((e) => e.groupId == groupId)
                        .toList();
                    for (final ev in events) {
                      final updated = ScheduleEvent(
                        id: ev.id,
                        groupId: ev.groupId,
                        date: ev.date,
                        title: res.title,
                        note: res.note?.trim().isEmpty == true ? null : res.note?.trim(),
                        startHour: ev.startHour,
                        startMinute: ev.startMinute,
                        endHour: ev.endHour,
                        endMinute: ev.endMinute,
                        color: res.color ?? ev.color,
                        tags: res.tags.isEmpty ? ev.tags : res.tags,
                        iconKey: res.iconKey ?? ev.iconKey,
                      );
                      await ScheduleStore.instance.updateEvent(updated);
                    }
                  }
                } else if (value == 'delete_group') {
                  if (event.groupId != null) {
                    await ScheduleStore.instance.deleteGroup(event.groupId!);
                  }
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'edit_group', child: Text('반복 묶음 편집', style: TextStyle(color: Colors.white70))),
                const PopupMenuItem(value: 'delete_group', child: Text('반복 묶음 삭제', style: TextStyle(color: Colors.white70))),
              ],
            ),
        ],
      ),
    );
  }
}

IconData _iconFromKey(String? key) {
  switch (key) {
    case 'holiday':
      return Icons.no_cell;
    case 'exam':
      return Icons.fact_check;
    case 'vacation_start':
      return Icons.beach_access;
    case 'school_open':
      return Icons.school;
    case 'special_lecture':
      return Icons.campaign;
    case 'counseling':
      return Icons.forum;
    case 'notice':
      return Icons.announcement;
    case 'payment':
      return Icons.payments;
    default:
      return Icons.event_note;
  }
}

Future<ScheduleEvent?> _showEditDialog(BuildContext context, ScheduleEvent event) async {
  final titleCtrl = TextEditingController(text: event.title);
  final noteCtrl = TextEditingController(text: event.note ?? '');
  TimeOfDay? start = (event.startHour != null && event.startMinute != null)
      ? TimeOfDay(hour: event.startHour!, minute: event.startMinute!)
      : null;
  TimeOfDay? end = (event.endHour != null && event.endMinute != null)
      ? TimeOfDay(hour: event.endHour!, minute: event.endMinute!)
      : null;
  int? color = event.color;
  final tagCtrl = TextEditingController();
  List<String> tags = List<String>.from(event.tags);
  String? iconKey = event.iconKey;

  IconData previewIcon() => _iconFromKey(iconKey);

  return showDialog<ScheduleEvent>(
    context: context,
    builder: (context) {
      return StatefulBuilder(builder: (context, setState) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('일정 편집', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: titleCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: '제목',
                      labelStyle: TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '메모',
                      labelStyle: TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _TimeField(
                          label: '시작 시간',
                          time: start,
                          onPick: (v) => setState(() => start = v),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _TimeField(
                          label: '종료 시간',
                          time: end,
                          onPick: (v) => setState(() => end = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('아이콘', style: TextStyle(color: Colors.white70)),
                      const SizedBox(width: 12),
                      DropdownButton<String?>(
                        value: iconKey,
                        dropdownColor: const Color(0xFF2A2A2A),
                        style: const TextStyle(color: Colors.white),
                        items: const [
                          DropdownMenuItem(value: 'holiday', child: Text('휴강')),
                          DropdownMenuItem(value: 'exam', child: Text('시험')),
                          DropdownMenuItem(value: 'vacation_start', child: Text('방학식')),
                          DropdownMenuItem(value: 'school_open', child: Text('개학식')),
                          DropdownMenuItem(value: 'special_lecture', child: Text('특강')),
                          DropdownMenuItem(value: 'counseling', child: Text('상담')),
                          DropdownMenuItem(value: 'notice', child: Text('공지')),  
                          DropdownMenuItem(value: 'payment', child: Text('납부')), 
                        ],
                        onChanged: (v) => setState(() => iconKey = v),
                      ),
                      const SizedBox(width: 16),
                      Icon(previewIcon(), color: Colors.white70),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text('색상', style: TextStyle(color: Colors.white70)),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () async {
                          // 간단 색상 팔레트(고정)
                          final choices = [
                            0xFF1976D2,
                            0xFFE53935,
                            0xFF43A047,
                            0xFFFB8C00,
                            0xFF8E24AA,
                            0xFF00897B,
                          ];
                          final picked = await showDialog<int>(
                            context: context,
                            builder: (context) {
                              return AlertDialog(
                                backgroundColor: const Color(0xFF1F1F1F),
                                title: const Text('색상 선택', style: TextStyle(color: Colors.white)),
                                content: Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: choices
                                      .map((c) => GestureDetector(
                                            onTap: () => Navigator.pop(context, c),
                                            child: Container(
                                              width: 28,
                                              height: 28,
                                              decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle),
                                            ),
                                          ))
                                      .toList(),
                                ),
                              );
                            },
                          );
                          if (picked != null) setState(() => color = picked);
                        },
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: color != null ? Color(color!) : Colors.white12,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('태그', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: tagCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: '태그 입력 후 추가',
                            hintStyle: TextStyle(color: Colors.white38),
                            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                          ),
                          onSubmitted: (_) {
                            final t = tagCtrl.text.trim();
                            if (t.isNotEmpty) {
                              setState(() {
                                tags.add(t);
                                tagCtrl.clear();
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                        onPressed: () {
                          final t = tagCtrl.text.trim();
                          if (t.isNotEmpty) {
                            setState(() {
                              tags.add(t);
                              tagCtrl.clear();
                            });
                          }
                        },
                        child: const Text('추가'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: tags
                        .map((t) => Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: const Color(0xFF2A2A2A),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('#$t', style: const TextStyle(color: Colors.white, fontSize: 12)),
                                  const SizedBox(width: 6),
                                  GestureDetector(
                                    onTap: () => setState(() => tags.remove(t)),
                                    child: const Icon(Icons.close, size: 14, color: Colors.white60),
                                  ),
                                ],
                              ),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              onPressed: () {
                Navigator.pop(
                  context,
                  ScheduleEvent(
                    id: event.id,
                    date: event.date,
                    title: titleCtrl.text.trim(),
                    note: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                    startHour: start?.hour,
                    startMinute: start?.minute,
                    endHour: end?.hour,
                    endMinute: end?.minute,
                    color: color,
                    tags: tags,
                    iconKey: iconKey,
                  ),
                );
              },
              child: const Text('저장'),
            ),
          ],
        );
      });
    },
  );
}

class _GroupEditResult {
  final String title;
  final String? note;
  final int? color;
  final List<String> tags;
  final String? iconKey;
  _GroupEditResult({required this.title, this.note, this.color, required this.tags, this.iconKey});
}

Future<_GroupEditResult?> _showEditGroupDialog(BuildContext context, ScheduleEvent event) async {
  final titleCtrl = TextEditingController(text: event.title);
  final noteCtrl = TextEditingController(text: event.note ?? '');
  int? color = event.color;
  String? iconKey = event.iconKey;
  List<String> tags = List<String>.from(event.tags);
  final tagCtrl = TextEditingController();

  return showDialog<_GroupEditResult>(
    context: context,
    builder: (context) {
      return StatefulBuilder(builder: (context, setState) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1F1F1F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('반복 묶음 편집', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: titleCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      labelText: '제목',
                      labelStyle: TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '요약/본문',
                      labelStyle: TextStyle(color: Colors.white70),
                      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('아이콘', style: TextStyle(color: Colors.white70)),
                      const SizedBox(width: 12),
                      DropdownButton<String?>(
                        value: iconKey,
                        dropdownColor: const Color(0xFF2A2A2A),
                        style: const TextStyle(color: Colors.white),
                        items: const [
                          DropdownMenuItem(value: 'holiday', child: Text('휴강')),
                          DropdownMenuItem(value: 'exam', child: Text('시험')),
                          DropdownMenuItem(value: 'vacation_start', child: Text('방학식')),
                          DropdownMenuItem(value: 'school_open', child: Text('개학식')),
                          DropdownMenuItem(value: 'special_lecture', child: Text('특강')),
                          DropdownMenuItem(value: 'counseling', child: Text('상담')),
                          DropdownMenuItem(value: 'notice', child: Text('공지')),
                          DropdownMenuItem(value: 'payment', child: Text('납부')),
                        ],
                        onChanged: (v) => setState(() => iconKey = v),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('색상', style: TextStyle(color: Colors.white70)),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () async {
                          final choices = [0xFF1976D2, 0xFFE53935, 0xFF43A047, 0xFFFB8C00, 0xFF8E24AA, 0xFF00897B];
                          final picked = await showDialog<int>(
                            context: context,
                            builder: (context) {
                              return AlertDialog(
                                backgroundColor: const Color(0xFF1F1F1F),
                                title: const Text('색상 선택', style: TextStyle(color: Colors.white)),
                                content: Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: choices.map((c) => GestureDetector(
                                    onTap: () => Navigator.pop(context, c),
                                    child: Container(width: 28, height: 28, decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle)),
                                  )).toList(),
                                ),
                              );
                            },
                          );
                          if (picked != null) setState(() => color = picked);
                        },
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: color != null ? Color(color!) : Colors.white12,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white24),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('태그', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: tagCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: '태그 입력 후 추가',
                            hintStyle: TextStyle(color: Colors.white38),
                            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: Color(0xFF1976D2))),
                          ),
                          onSubmitted: (_) {
                            final t = tagCtrl.text.trim();
                            if (t.isNotEmpty) {
                              setState(() {
                                tags.add(t);
                                tagCtrl.clear();
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
                        onPressed: () {
                          final t = tagCtrl.text.trim();
                          if (t.isNotEmpty) {
                            setState(() {
                              tags.add(t);
                              tagCtrl.clear();
                            });
                          }
                        },
                        child: const Text('추가'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: tags
                        .map((t) => Chip(
                              label: Text(t, style: const TextStyle(color: Colors.white70)),
                              backgroundColor: Colors.white12,
                              deleteIcon: const Icon(Icons.close, size: 16, color: Colors.white54),
                              onDeleted: () => setState(() => tags.remove(t)),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소', style: TextStyle(color: Colors.white70)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
              onPressed: () {
                Navigator.pop(
                  context,
                  _GroupEditResult(
                    title: titleCtrl.text.trim(),
                    note: noteCtrl.text.trim(),
                    color: color,
                    tags: tags,
                    iconKey: iconKey,
                  ),
                );
              },
              child: const Text('묶음 적용'),
            ),
          ],
        );
      });
    },
  );
}

class _TimeField extends StatelessWidget {
  final String label;
  final TimeOfDay? time;
  final ValueChanged<TimeOfDay?> onPick;
  const _TimeField({required this.label, required this.time, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final initial = time ?? const TimeOfDay(hour: 9, minute: 0);
        final picked = await showTimePicker(context: context, initialTime: initial);
        onPick(picked);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white24),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70)),
            Text(
              time == null ? '-' : '${time!.hour.toString().padLeft(2, '0')}:${time!.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthlyCalendar extends StatelessWidget {
  final DateTime month; // first day of month
  final DateTime selectedDate;
  final ValueChanged<DateTime>? onSelect;
  final bool addMode;
  final DateTime? previewStart;
  final DateTime? previewEnd;
  final ValueChanged<DateTime>? onHoverDate;

  const _MonthlyCalendar({
    required this.month,
    required this.selectedDate,
    this.onSelect,
    this.addMode = false,
    this.previewStart,
    this.previewEnd,
    this.onHoverDate,
  });

  @override
  Widget build(BuildContext context) {
    final firstDayOfMonth = DateTime(month.year, month.month, 1);
    final firstWeekday = firstDayOfMonth.weekday; // Mon=1..Sun=7
    final leadingEmpty = (firstWeekday - 1) % 7; // 0..6 (Mon start)
    const totalCells = 42; // 6 weeks grid

    // Build 42 cells covering the 6-week grid
    List<DateTime> cells = List.generate(totalCells, (index) {
      final dayOffset = index - leadingEmpty;
      return DateTime(month.year, month.month, 1 + dayOffset);
    });

    const textStyleDim = TextStyle(color: Colors.white30, fontSize: 21, fontWeight: FontWeight.w600);
    const textStyleNorm = TextStyle(color: Colors.white70, fontSize: 21, fontWeight: FontWeight.w700);
    const dowStyle = TextStyle(color: Colors.white60, fontSize: 15, fontWeight: FontWeight.w600);
    const monthTitleStyle = TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '이전 달',
              onPressed: () => onSelect?.call(DateTime(month.year, month.month - 1, selectedDate.day.clamp(1, 28))),
              icon: const Icon(Icons.chevron_left, color: Colors.white70),
            ),
            Expanded(
              child: GestureDetector(
                onTap: () async {
                  final picked = await showDialog<DateTime>(
                    context: context,
                    builder: (context) => _MonthYearPickerDialog(initial: month),
                  );
                  if (picked != null) onSelect?.call(picked);
                },
                child: Center(child: Text('${month.year}년 ${month.month}월', style: monthTitleStyle)),
              ),
            ),
            IconButton(
              tooltip: '다음 달',
              onPressed: () => onSelect?.call(DateTime(month.year, month.month + 1, selectedDate.day.clamp(1, 28))),
              icon: const Icon(Icons.chevron_right, color: Colors.white70),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: const [
            Expanded(child: Center(child: Text('월', style: dowStyle))),
            Expanded(child: Center(child: Text('화', style: dowStyle))),
            Expanded(child: Center(child: Text('수', style: dowStyle))),
            Expanded(child: Center(child: Text('목', style: dowStyle))),
            Expanded(child: Center(child: Text('금', style: dowStyle))),
            Expanded(child: Center(child: Text('토', style: TextStyle(color: Color(0xFF64A6DD), fontSize: 15, fontWeight: FontWeight.w600)))),
            Expanded(child: Center(child: Text('일', style: TextStyle(color: Color(0xFFEF6E6E), fontSize: 15, fontWeight: FontWeight.w600)))),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: GridView.builder(
            physics: const ClampingScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemCount: totalCells,
            itemBuilder: (context, index) {
              final date = cells[index];
              final isCurrentMonth = date.month == month.month;
              final isSelected = date.year == selectedDate.year && date.month == selectedDate.month && date.day == selectedDate.day;
                final textStyle = isCurrentMonth ? textStyleNorm : textStyleDim;
              final count = ScheduleStore.instance.eventsCountOn(date);
              return MouseRegion(
                onHover: (_) { if (addMode && onHoverDate != null) onHoverDate!(date); },
                child: GestureDetector(
                  onTap: () => onSelect?.call(date),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF1976D2).withOpacity(0.22) : Colors.transparent,
                    border: Border.all(color: isSelected ? const Color(0xFF1976D2) : Colors.white12, width: isSelected ? 1.6 : 1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                   padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  child: Stack(
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: _buildDayNumber(date, textStyle),
                        ),
                      ),
                      const SizedBox.shrink(),
                      Positioned(
                        left: 6,
                        right: 6,
                        top: 44,
                        child: const SizedBox(height: 2),
                      ),
                      if (addMode && _inRange(date, previewStart, previewEnd))
                        Positioned.fill(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF1976D2).withOpacity(0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: const Color(0xFF1976D2).withOpacity(0.4), width: 1),
                            ),
                          ),
                        ),
                      if (count > 0)
                        Positioned.fill(
                          child: _DayEventsOverlay(date: date),
                        ),
                    ],
                  ),
                ),
                ),
              );
            },
            ),
        ),
      ],
    );
  }
}

bool _inRange(DateTime date, DateTime? start, DateTime? end) {
  if (start == null || end == null) return false;
  final s = DateTime(start.year, start.month, start.day);
  final e = DateTime(end.year, end.month, end.day);
  if (s.isAfter(e)) {
    return !date.isBefore(e) && !date.isAfter(s);
  }
  return !date.isBefore(s) && !date.isAfter(e);
}

class _EventBadge extends StatelessWidget {
  final int count;
  const _EventBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF1976D2),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _TodoFilterButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TodoFilterButton({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final borderColor = selected ? const Color(0xFF1976D2) : Colors.white24;
    final bgColor = const Color(0xFF2A2A2A); // 컨테이너 배경색
    final fgColor = selected ? Colors.white : Colors.white70;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: ShapeDecoration(
          color: bgColor,
          shape: StadiumBorder(side: BorderSide(color: borderColor, width: 2)),
        ),
        child: Text(label, style: TextStyle(color: fgColor, fontSize: 12)),
      ),
    );
  }
}

class _ScheduleTimeline extends StatefulWidget {
  const _ScheduleTimeline();

  @override
  State<_ScheduleTimeline> createState() => _ScheduleTimelineState();
}

class _ScheduleTimelineState extends State<_ScheduleTimeline> {
  final ScrollController _controller = ScrollController();

  @override
  Widget build(BuildContext context) {
    final all = ScheduleStore.instance.events.value;
    if (all.isEmpty) {
      return const Center(child: Text('표시할 일정이 없습니다.', style: TextStyle(color: Colors.white38)));
    }
    final now = DateTime.now();
    final items = List<ScheduleEvent>.from(all)
      ..sort((a, b) => a.date.compareTo(b.date));
    final today = DateTime(now.year, now.month, now.day);
    int centerIndex = items.indexWhere((e) {
      final d = DateTime(e.date.year, e.date.month, e.date.day);
      return d == today;
    });
    if (centerIndex == -1) {
      centerIndex = items.indexWhere((e) => !DateTime(e.date.year, e.date.month, e.date.day).isBefore(today));
    }
    if (centerIndex == -1) centerIndex = items.length - 1;

    // Window: ±10
    final start = (centerIndex - 10).clamp(0, items.length - 1);
    final end = (centerIndex + 10).clamp(0, items.length - 1);
    final window = items.sublist(start, end + 1);
    final localCenter = (centerIndex - start).clamp(0, window.length - 1);

    return LayoutBuilder(
      builder: (context, constraints) {
        const double cardWidth = 200.0;
        const double gap = 12.0;
        final double viewport = constraints.maxWidth;
        final double totalWidth = window.length * cardWidth + math.max(0, window.length - 1) * gap;
        double target = localCenter * (cardWidth + gap) - (viewport - cardWidth) / 2;
        target = target.clamp(0.0, math.max(0.0, totalWidth - viewport));

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_controller.hasClients) {
            _controller.jumpTo(target);
          }
        });

        return ListView.builder(
          scrollDirection: Axis.horizontal,
          controller: _controller,
          itemCount: window.length,
          itemBuilder: (context, i) {
            final e = window[i];
            final eventDate = DateTime(e.date.year, e.date.month, e.date.day);
            final isUpcoming = !eventDate.isBefore(today);
            final isCenter = i == localCenter;
            return Container(
              width: cardWidth,
              margin: EdgeInsets.only(right: i == window.length - 1 ? 0 : gap),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF202024),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: e.tags.contains('KR_HOLIDAY')
                      ? const Color(0xFFF06666)
                      : (isCenter ? const Color(0xFF4D95D8) : (isUpcoming ? const Color(0xFF64A6DD) : Colors.white12)),
                  width: isCenter ? 3 : 2,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(width: 6, height: 6, decoration: BoxDecoration(color: e.color != null ? Color(e.color!) : const Color(0xFF64A6DD), shape: BoxShape.circle)),
                      const SizedBox(width: 8),
                      Text('${e.date.month}.${e.date.day}', style: TextStyle(color: isCenter ? Colors.white : (isUpcoming ? Colors.white70 : Colors.white38), fontWeight: FontWeight.w600)),
                      const Spacer(),
                      Icon(_iconFromKey(e.iconKey), color: isCenter ? Colors.white70 : Colors.white38, size: 16),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_singleWord(e.title), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: isCenter ? Colors.white : (isUpcoming ? Colors.white : Colors.white38), fontSize: 14, fontWeight: FontWeight.w700)),
                  if (e.note != null && e.note!.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _clipToChars(_oneSentence(e.note!.trim()), 60),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: isCenter ? Colors.white70 : (isUpcoming ? Colors.white70 : Colors.white38), fontSize: 12),
                      ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _DayEventsOverlay extends StatelessWidget {
  final DateTime date;
  const _DayEventsOverlay({required this.date});

  @override
  Widget build(BuildContext context) {
    final events = ScheduleStore.instance.eventsOn(date);
    if (events.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2, top: 30, bottom: 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 대략적인 한 이벤트 스트라이프의 높이를 계산하여 표시 가능한 개수 산정
          // 제목 1줄(약 18) + 요약 2줄(약 30) + 패딩/간격(약 12) ≈ 60
          const double estimatedEventHeight = 60;
          const double moreIconHeight = 20;
          double available = constraints.maxHeight;
          int maxCount = (available - moreIconHeight) ~/ estimatedEventHeight;
          if (maxCount < 1) maxCount = 1;
          if (maxCount > 3) maxCount = 3;
          final toShow = events.take(maxCount).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ...toShow.map((e) => _EventStripe(
                    title: _singleWord(e.title),
                    subtitle: (e.note != null && e.note!.trim().isNotEmpty)
                        ? e.note!.trim()
                        : null,
                    color: e.color,
                    iconKey: e.iconKey,
                  )),
              if (events.length > toShow.length)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: GestureDetector(
                      onTap: () => _showDayEventsModal(date),
                      child: const Icon(Icons.more_horiz, color: Colors.white38, size: 16),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _EventStripe extends StatelessWidget {
  final String title;      // 한 단어
  final String? subtitle;  // 한 문장 요약
  final int? color;
  final String? iconKey;
  const _EventStripe({required this.title, this.subtitle, required this.color, this.iconKey});

  @override
  Widget build(BuildContext context) {
    final Color indicatorColor = iconKey == 'holiday'
        ? const Color(0xFFF06666)
        : (color != null ? Color(color!) : const Color(0xFF64A6DD));
    final BoxDecoration? holidayDeco = iconKey == 'holiday'
        ? BoxDecoration(color: const Color(0x22F06666), borderRadius: BorderRadius.circular(6))
        : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 5,
              decoration: BoxDecoration(color: indicatorColor, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Container(
                decoration: holidayDeco,
                padding: holidayDeco != null ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4) : EdgeInsets.zero,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
String _iconLabel(String? key) {
  switch (key) {
    case 'holiday':
      return '휴강';
    case 'exam':
      return '시험';
    case 'vacation_start':
      return '방학식';
    case 'school_open':
      return '개학식';
    case 'special_lecture':
      return '특강';
    case 'counseling':
      return '상담';
    case 'notice':
      return '공지';
    case 'payment':
      return '납부';
    default:
      return '일정';
  }
}

String _firstTwoWords(String s) {
  final parts = s.split(RegExp(r"\s+")).where((e) => e.isNotEmpty).toList();
  if (parts.isEmpty) return s;
  return parts.take(2).join(' ');
}

String _singleWord(String s) {
  final parts = s.split(RegExp(r"\s+")).where((e) => e.isNotEmpty).toList();
  return parts.isEmpty ? s : parts.first;
}

String _oneSentence(String s) {
  final cleaned = s.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final idx = cleaned.indexOf(RegExp(r'[.!?]'));
  if (idx != -1) return cleaned.substring(0, idx + 1);
  return cleaned;
}

String _clipToChars(String s, [int maxChars = 40]) {
  if (s.runes.length <= maxChars) return s;
  final it = s.runes.iterator;
  final buf = StringBuffer();
  int count = 0;
  while (it.moveNext()) {
    buf.writeCharCode(it.current);
    count++;
    if (count >= maxChars) break;
  }
  return '${buf.toString()}…';
}

String _formatDateYMD(DateTime d) {
  return '${d.year}.${d.month}.${d.day}';
}

Widget _buildDayNumber(DateTime date, TextStyle base) {
  Color color = base.color ?? Colors.white70;
  // 월=1..일=7
  if (date.weekday == DateTime.saturday) {
    color = const Color(0xFF4D95D8); // 살짝 채도/명도 업
  } else if (date.weekday == DateTime.sunday) {
    color = const Color(0xFFF06666); // 살짝 채도/명도 업
  }
  return Text('${date.day}', style: base.copyWith(color: color));
}

String _cleanSummary(String summary, String? iconLabel) {
  var s = summary;
  if (iconLabel != null && iconLabel.isNotEmpty) {
    // 앞부분에 아이콘명이 반복되는 패턴 제거 (예: "상담 · ...", "상담:")
    s = s.replaceFirst(RegExp('^$iconLabel\s*[·:\-]\s*'), '');
  }
  // 한 문장만 남기기
  return _oneSentence(s);
}

Future<void> _showDayEventsModal(DateTime date) async {
  final context = rootNavigatorKey.currentContext ?? WidgetsBinding.instance.focusManager.primaryFocus?.context;
  if (context == null) return;
  final items = ScheduleStore.instance.eventsOn(date);
  await showDialog(
    context: context,
    builder: (context) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1F1F1F),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('${date.year}.${date.month}.${date.day} 일정', style: const TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 560,
          height: 420,
          child: items.isEmpty
              ? const Center(child: Text('일정이 없습니다.', style: TextStyle(color: Colors.white54)))
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(color: Colors.white12),
                  itemBuilder: (context, idx) => _EventTile(event: items[idx], showGroupActions: true),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기', style: TextStyle(color: Colors.white70)),
          ),
        ],
      );
    },
  );
}

class _MonthYearPickerDialog extends StatefulWidget {
  final DateTime initial;
  const _MonthYearPickerDialog({required this.initial});

  @override
  State<_MonthYearPickerDialog> createState() => _MonthYearPickerDialogState();
}

class _MonthYearPickerDialogState extends State<_MonthYearPickerDialog> {
  late int _year;
  late int _month;

  @override
  void initState() {
    super.initState();
    _year = widget.initial.year;
    _month = widget.initial.month;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1F1F1F),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Text('년/월 선택', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 420,
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('연도', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 6),
                  DropdownButton<int>(
                    value: _year,
                    dropdownColor: const Color(0xFF2A2A2A),
                    style: const TextStyle(color: Colors.white),
                    items: List.generate(25, (i) => _year - 12 + i)
                        .map((y) => DropdownMenuItem(value: y, child: Text('$y년')))
                        .toList(),
                    onChanged: (v) => setState(() => _year = v ?? _year),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('월', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 6),
                  DropdownButton<int>(
                    value: _month,
                    dropdownColor: const Color(0xFF2A2A2A),
                    style: const TextStyle(color: Colors.white),
                    items: List.generate(12, (i) => i + 1)
                        .map((m) => DropdownMenuItem(value: m, child: Text('$m월')))
                        .toList(),
                    onChanged: (v) => setState(() => _month = v ?? _month),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소', style: TextStyle(color: Colors.white70)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1976D2)),
          onPressed: () => Navigator.pop(context, DateTime(_year, _month, 1)),
          child: const Text('이동'),
        ),
      ],
    );
  }
}


