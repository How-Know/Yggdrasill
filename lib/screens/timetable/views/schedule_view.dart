import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../services/schedule_store.dart';
import '../../../services/summary_service.dart';

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
                flex: 4,
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
                flex: 1,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF18181A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('다가올 일정 타임라인(가로)', style: TextStyle(color: Colors.white70)),
                  ),
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
                              separatorBuilder: (_, __) => const Divider(color: Colors.white12),
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
                      const Text('Todo 리스트', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.separated(
                          itemCount: 8,
                          separatorBuilder: (_, __) => const Divider(color: Colors.white12, height: 12),
                          itemBuilder: (context, index) {
                            return Row(
                              children: [
                                Checkbox(
                                  value: index.isEven,
                                  onChanged: (_) {},
                                  checkColor: Colors.white,
                                  activeColor: const Color(0xFF1976D2),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '할 일 ${index + 1}',
                                    style: const TextStyle(color: Colors.white70),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.edit, color: Colors.white54, size: 18),
                                  onPressed: () {},
                                ),
                              ],
                            );
                          },
                        ),
                      ),
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
  const _EventTile({required this.event});

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
                if (event.note != null && event.note!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(event.note!, style: const TextStyle(color: Colors.white60, fontSize: 13)),
                  ),
                if (event.tags.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
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

    const textStyleDim = TextStyle(color: Colors.white30, fontSize: 19, fontWeight: FontWeight.w600);
    const textStyleNorm = TextStyle(color: Colors.white70, fontSize: 19, fontWeight: FontWeight.w700);
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
            Expanded(child: Center(child: Text('토', style: dowStyle))),
            Expanded(child: Center(child: Text('일', style: dowStyle))),
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
                   padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
                  child: Stack(
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: Text('${date.day}', style: textStyle),
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

class _DayEventsOverlay extends StatelessWidget {
  final DateTime date;
  const _DayEventsOverlay({required this.date});

  @override
  Widget build(BuildContext context) {
    final events = ScheduleStore.instance.eventsOn(date);
    if (events.isEmpty) return const SizedBox.shrink();
    // 최대 2개만 표시 + 더보기 점3
    final toShow = events.take(2).toList();
    return Padding(
      padding: const EdgeInsets.only(left: 2, right: 2, top: 20, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...toShow.map((e) => _EventStripe(title: e.title, color: e.color)),
          if (events.length > 2)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: const [
                  Icon(Icons.more_horiz, color: Colors.white38, size: 16),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _EventStripe extends StatelessWidget {
  final String title;
  final int? color;
  const _EventStripe({required this.title, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 14,
            decoration: BoxDecoration(
              color: color != null ? Color(color!) : const Color(0xFF1976D2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
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


